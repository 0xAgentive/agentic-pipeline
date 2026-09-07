#!/usr/bin/env python3
"""Read-only native metadata/identity probe and bounded bridge heartbeat/bootstrap.

Only heartbeat and bootstrap commands write local state. No process starts/stops,
account operations, sends, imports or resume. Native query is metadata only.
"""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time
from urllib.parse import unquote,urlparse
from process_identity import command_matches,health,identity_matches,instance_from_identity,observe_pid,observed_processes,process_details
from recovery_coordinator import Coordinator,Rejected
from runtime_paths import runtime_path


def strict_loads(raw):
    def pairs(items):
        result={}
        for key,value in items:
            if key in result:raise ValueError('DUPLICATE_JSON_FIELD')
            result[key]=value
        return result
    def constant(value):raise ValueError('NONFINITE_JSON_VALUE')
    return json.loads(raw,object_pairs_hook=pairs,parse_constant=constant)


def read_object(path,limit=1024*1024):
    path=Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size>limit:raise ValueError('EXACT_REGULAR_INPUT_REQUIRED')
    raw=path.read_bytes();value=strict_loads(raw.decode('utf-8-sig'))
    if not isinstance(value,dict):raise ValueError('OBJECT_REQUIRED')
    return value


def same_path(a,b):
    def normalize(v):
        v=str(v)
        if v.startswith('file:'):
            uri=urlparse(v)
            if uri.netloc not in ('','localhost'):raise ValueError('NONLOCAL_WORKSPACE_URI')
            v=unquote(uri.path)
            if re.match(r'^/[A-Za-z]:/',v):v=v[1:]
        if re.match(r'^[A-Za-z]:[\\/]',v):return v.replace('\\','/').rstrip('/').casefold()
        return os.path.normcase(str(Path(v).resolve()))
    return normalize(a)==normalize(b)


def validate_metadata(body,comp):
    if not isinstance(body,dict) or 'error' in body:raise ValueError('NATIVE_METADATA_ERROR_ENVELOPE')
    if not isinstance(comp,dict) or not all(isinstance(comp.get(k),str) and comp[k] for k in ('projectId','projectPath','antigravityConversationId')):raise ValueError('EXACT_NATIVE_PROJECT_SELECTION_REQUIRED')
    try:meta=body['response']['conversationMetadata']['metadata']
    except (KeyError,TypeError):raise ValueError('NATIVE_METADATA_SCHEMA_UNVERIFIED')
    if not isinstance(meta,dict) or meta.get('projectId')!=comp['projectId']:raise ValueError('NATIVE_PROJECT_MISMATCH')
    workspaces=meta.get('workspaceUris')
    if not isinstance(workspaces,list) or not workspaces or not any(isinstance(v,str) and same_path(v,comp['projectPath']) for v in workspaces):raise ValueError('NATIVE_WORKSPACE_MISMATCH')
    return {'project_identity_verified':True,'workspace_identity_verified':True,'conversation_identity_verified':None,'send_receipt_verified':None,'response_sha256':hashlib.sha256(json.dumps(body,sort_keys=True,separators=(',',':')).encode()).hexdigest(),'requested_conversation_sha256':hashlib.sha256(comp['antigravityConversationId'].encode()).hexdigest()}


def connection(state_root,executable,*,now=None,observer=observe_pid):
    now=time.time() if now is None else now
    path=Path(state_root)/'ACTIVE_LS_ENV.json';env=read_object(path)
    if not 0<=now-path.stat().st_mtime<=30:raise ValueError('FRESH_LOCAL_NATIVE_ENV_REQUIRED')
    address=env.get('ANTIGRAVITY_LS_ADDRESS','');match=re.fullmatch(r'(?:localhost|127\.0\.0\.1|\[::1\]):([0-9]{1,5})',address)
    if not match or not 1<=int(match[1])<=65535 or not isinstance(env.get('ANTIGRAVITY_CSRF_TOKEN'),str) or not env['ANTIGRAVITY_CSRF_TOKEN']:raise ValueError('LOCAL_NATIVE_ENV_REQUIRED')
    try:pid=int(env['ANTIGRAVITY_LS_PID'])
    except (KeyError,TypeError,ValueError):raise ValueError('NATIVE_PROCESS_IDENTITY_REQUIRED')
    identity=observer(pid)
    if not same_path(identity['executable'],executable):raise ValueError('NATIVE_EXECUTABLE_IDENTITY_MISMATCH')
    return {k:str(env[k]) for k in ('ANTIGRAVITY_LS_ADDRESS','ANTIGRAVITY_CSRF_TOKEN','ANTIGRAVITY_LS_PID')},identity


def probe_native(comp,state_root,executable,*,execute=subprocess.run,observer=observe_pid):
    executable=Path(executable)
    if not executable.is_file() or executable.is_symlink():raise ValueError('NATIVE_EXECUTABLE_MISSING')
    conversation=comp.get('antigravityConversationId')
    if not isinstance(conversation,str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}',conversation):raise ValueError('EXACT_NATIVE_CONVERSATION_REQUIRED')
    native_env,identity=connection(state_root,executable,observer=observer)
    env=os.environ.copy();env.update(native_env);env.pop('ANTIGRAVITY_SOURCE_METADATA',None)
    child=execute([str(executable),'agentapi','get-conversation-metadata',conversation],env=env,capture_output=True,text=True,encoding='utf-8',timeout=5,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    if child.returncode!=0:raise ValueError('NATIVE_METADATA_QUERY_FAILED')
    if not identity_matches(identity,observer(identity['pid'])):raise ValueError('NATIVE_PROCESS_CHANGED_DURING_PROBE')
    body=strict_loads(child.stdout);result=validate_metadata(body,comp)
    result.update(status='VERIFIED',process_identity=identity,epoch=time.time(),scope='local_native_metadata_health_only')
    return result


def owned_loopback_listeners(pid):
    """Read only sockets belonging to this exact process; never guess a max port."""
    try:
        import psutil
        sockets=psutil.Process(pid).net_connections(kind='inet')
    except Exception:raise ValueError('NATIVE_SOCKET_PROVIDER_UNAVAILABLE')
    return [(item.laddr.ip,item.laddr.port) for item in sockets if item.status==psutil.CONN_LISTEN and item.laddr]


def refresh_connection(comp,state_root,executable,*,native_port=None,rows=None,listeners=owned_loopback_listeners,execute=subprocess.run,observer=observe_pid):
    """Refresh only private endpoint evidence while runtime writers remain held.

    Exact executable, one observed process, owned loopback listeners and a
    successful metadata/project/workspace query are required. No service starts,
    sends, guard watch call, pause changes or runtime epoch write occur here.
    """
    executable=Path(executable)
    if executable.is_symlink() or not executable.is_file():raise ValueError('NATIVE_EXECUTABLE_MISSING')
    candidates=[row for row in (observed_processes() if rows is None else rows) if same_path(row[0]['executable'],executable)]
    if len(candidates)!=1:raise ValueError('NATIVE_PROCESS_ABSENT_OR_AMBIGUOUS')
    identity,argv,_=candidates[0];tokens=[]
    for index,arg in enumerate(argv):
        if arg=='--csrf_token' and index+1<len(argv):tokens.append(argv[index+1])
        elif arg.startswith('--csrf_token='):tokens.append(arg.split('=',1)[1])
    if len(tokens)!=1 or not isinstance(tokens[0],str) or not 1<=len(tokens[0])<=512 or any(ord(c)<33 for c in tokens[0]):raise ValueError('NATIVE_CSRF_ARGUMENT_UNVERIFIED')
    if not identity_matches(identity,observer(identity['pid'])):raise ValueError('NATIVE_PROCESS_CHANGED_DURING_REFRESH')
    pairs={(ip,port) for ip,port in listeners(identity['pid']) if ip in ('127.0.0.1','::1') and type(port) is int and 1<=port<=65535}
    if native_port is not None:
        if type(native_port) is not int or not 1<=native_port<=65535:raise ValueError('NATIVE_PORT_INVALID')
        pairs={(ip,port) for ip,port in pairs if port==native_port}
    # IPv4 and IPv6 for the same owned port are one endpoint choice. Prefer its
    # exact IPv4 loopback address when both are observed, without guessing ports.
    ports=sorted({port for ip,port in pairs})
    if not ports:raise ValueError('LOOPBACK_LISTENER_REQUIRED')
    if len(ports)>4:raise ValueError('BOUNDED_NATIVE_PORT_SELECTION_REQUIRED')
    conversation=comp.get('antigravityConversationId')
    if not isinstance(conversation,str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}',conversation):raise ValueError('EXACT_NATIVE_CONVERSATION_REQUIRED')
    verified=[]
    for port in ports:
        address=('127.0.0.1' if ('127.0.0.1',port) in pairs else '[::1]')+':'+str(port)
        private={'ANTIGRAVITY_LS_ADDRESS':address,'ANTIGRAVITY_CSRF_TOKEN':tokens[0],'ANTIGRAVITY_LS_PID':str(identity['pid'])}
        env=os.environ.copy();env.update(private);env.pop('ANTIGRAVITY_SOURCE_METADATA',None)
        if not identity_matches(identity,observer(identity['pid'])):raise ValueError('NATIVE_PROCESS_CHANGED_DURING_REFRESH')
        try:
            result=execute([str(executable),'agentapi','get-conversation-metadata',conversation],env=env,capture_output=True,text=True,encoding='utf-8',timeout=5,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            if result.returncode==0:
                metadata=validate_metadata(strict_loads(result.stdout),comp)
                verified.append((private,metadata))
        except (ValueError,OSError,subprocess.TimeoutExpired):pass
    if not identity_matches(identity,observer(identity['pid'])):raise ValueError('NATIVE_PROCESS_CHANGED_DURING_REFRESH')
    if len(verified)!=1:raise ValueError('NATIVE_METADATA_ENDPOINT_AMBIGUOUS' if verified else 'NATIVE_METADATA_ENDPOINT_UNVERIFIED')
    private,metadata=verified[0]
    state_root=Path(state_root)
    if state_root.is_symlink():raise ValueError('NATIVE_STATE_ROOT_SYMLINK')
    state_root.mkdir(parents=True,exist_ok=True);destination=state_root/'ACTIVE_LS_ENV.json'
    if destination.is_symlink():raise ValueError('NATIVE_ENV_SYMLINK')
    private.update(process_identity=identity,updated_at_utc=datetime.now(timezone.utc).isoformat(),metadata_response_sha256=metadata['response_sha256'])
    import tempfile
    descriptor,name=tempfile.mkstemp(prefix='.native-env-',suffix='.tmp',dir=state_root)
    try:
        with os.fdopen(descriptor,'w',encoding='utf-8') as stream:json.dump(private,stream,separators=(',',':'))
        os.replace(name,destination)
    finally:
        if Path(name).exists():Path(name).unlink()
    return {'schema_version':3,'status':'CONNECTION_REFRESHED','scope':'private_connection_metadata_only','process_identity':identity,'owned_loopback_ports_examined':len(ports),'native_metadata':metadata,'runtime_epoch_changed':False,'services_started':False,'messages_sent':False}


def heartbeat_health(identity,heartbeat,state,*,now=None):
    report=health(identity,identity,heartbeat,now=now,max_age=60)
    if report['healthy'] is not True:return report
    if heartbeat.get('service')!='companion_bridge' or type(state.get('epoch')) is not int or heartbeat.get('runtime_epoch')!=state['epoch'] or not state.get('runtime_instance') or heartbeat.get('runtime_instance')!=state['runtime_instance']:
        report.update(healthy=None,reason='HEARTBEAT_RUNTIME_EPOCH_MISMATCH')
    return report


def write_bridge_heartbeat(pid,script,destination,state):
    identity,argv,_=process_details(pid)
    if not command_matches(argv,script,('watch',)):raise ValueError('BRIDGE_COMMAND_IDENTITY_MISMATCH')
    if type(state.get('epoch')) is not int:raise ValueError('RUNTIME_STATE_UNAVAILABLE')
    record={'schema_version':1,'service':'companion_bridge','process_identity':identity,'epoch':time.time(),'runtime_epoch':state['epoch'],'runtime_instance':state.get('runtime_instance')}
    destination=Path(destination);destination.parent.mkdir(parents=True,exist_ok=True)
    if destination.is_symlink():raise ValueError('HEARTBEAT_SYMLINK_REFUSED')
    temporary=destination.with_name(destination.name+'.'+str(os.getpid())+'.tmp')
    with temporary.open('x',encoding='utf-8') as f:json.dump(record,f,separators=(',',':'))
    os.replace(temporary,destination)
    return record


def commit_runtime_identity(identity,database):
    c=Coordinator(database);before=c.snapshot();instance=instance_from_identity(identity)
    after=c.observe_runtime(instance)
    if before.get('runtime_instance') is not None and before.get('runtime_instance')!=instance:raise Rejected('RUNTIME_INSTANCE_CHANGED_RECONCILE_REQUIRED')
    return {'status':'INITIALIZED' if before.get('runtime_instance') is None else 'VERIFIED','epoch':after['epoch'],'is_standby':after['is_standby'],'runtime_instance_sha256':hashlib.sha256(instance.encode()).hexdigest(),'scope':'runtime_identity_only'}


def configured_selection(project_key=None):
    cfg=read_object(runtime_path('ANTIGRAVITY_DATA_ROOT','companion_bridge_config.json'))
    companions=cfg.get('browser',{}).get('companions',{})
    if not isinstance(companions,dict):raise ValueError('COMPANION_CONFIGURATION_REQUIRED')
    if project_key is None:
        keys=sorted(k for k,v in companions.items() if isinstance(v,dict) and all(v.get(f) for f in ('projectId','projectPath','antigravityConversationId')))
        if len(keys)!=1:raise ValueError('EXACT_PROJECT_KEY_REQUIRED')
        project_key=keys[0]
    comp=companions.get(project_key)
    if not isinstance(comp,dict):raise ValueError('EXACT_PROJECT_KEY_REQUIRED')
    return comp


def bootstrap(project_key,database):
    comp=configured_selection(project_key);state_root=runtime_path('AGENTIC_STATE_ROOT');executable=runtime_path('ANTIGRAVITY_INSTALL_ROOT','resources/bin/language_server.exe')
    try:connection(state_root,executable)
    except (ValueError,OSError):refresh_connection(comp,state_root,executable)
    proof=probe_native(comp,state_root,executable)
    result=commit_runtime_identity(proof['process_identity'],database)
    result['native_metadata']=proof
    return result


def service_reports(*,state,scripts,state_root,ide_exe,ls_exe,companions):
    names=('companion_bridge','process_guard','telegram_bot','ide')
    reports={name:{'identity_verified':False,'alive':None,'healthy':None,'reason':'PROCESS_PROVIDER_UNAVAILABLE'} for name in names}
    try:rows=list(observed_processes())
    except Exception:return reports
    specs={'companion_bridge':(Path(scripts)/'companion_bridge.js',('watch',),'COMPANION_BRIDGE_HEARTBEAT.json'),'process_guard':(Path(scripts)/'antigravity_process_guard.py',('--watch',),'PROCESS_GUARD_HEARTBEAT.json'),'telegram_bot':(Path(scripts)/'telegram_cycle_bot.py',(),'TELEGRAM_BOT_HEARTBEAT.json')}
    for name,(script,args,hbfile) in specs.items():
        matched=[identity for identity,argv,parent in rows if command_matches(argv,script,args)]
        if len(matched)!=1:
            reports[name]={'identity_verified':False,'alive':bool(matched),'healthy':None,'reason':'PROCESS_ABSENT_OR_AMBIGUOUS','matching_process_count':len(matched)};continue
        identity=matched[0]
        try:heartbeat=read_object(Path(state_root)/hbfile)
        except Exception:heartbeat=None
        report=heartbeat_health(identity,heartbeat,state) if name=='companion_bridge' else health(identity,identity,heartbeat)
        reports[name]={**report,'process_identity':identity}
    ide_rows=[identity for identity,argv,parent in rows if same_path(identity['executable'],ide_exe)]
    # Electron subprocesses share the executable. Health attaches to the actual
    # ancestor of the selected language server, never to the first matching PID.
    reports['ide']={'identity_verified':False,'alive':bool(ide_rows),'healthy':None,'reason':'NATIVE_HEALTH_UNVERIFIED'}
    try:
        selected=[v for v in companions.values() if isinstance(v,dict) and all(v.get(f) for f in ('projectId','projectPath','antigravityConversationId'))]
        if not selected:raise ValueError('CONFIGURED_NATIVE_PROJECT_REQUIRED')
        proofs=[probe_native(comp,state_root,ls_exe) for comp in selected]
        ls=proofs[0]['process_identity']
        if any(not identity_matches(ls,p['process_identity']) for p in proofs):raise ValueError('NATIVE_RUNTIME_AMBIGUOUS')
        if state.get('runtime_instance')!=instance_from_identity(ls):raise ValueError('RUNTIME_IDENTITY_NOT_BOOTSTRAPPED')
        parent=process_details(ls['pid'])[2];visited=set();observed_ide=None
        while parent>0 and parent not in visited and len(visited)<16:
            visited.add(parent);identity,argv,parent=process_details(parent)
            if same_path(identity['executable'],ide_exe):observed_ide=identity;break
        if observed_ide is None:raise ValueError('IDE_NATIVE_ANCESTRY_UNVERIFIED')
        reports['ide']={'identity_verified':True,'alive':True,'healthy':True,'reason':'NATIVE_METADATA_PROJECT_WORKSPACE_HEALTH_VERIFIED','process_identity':observed_ide,'native_process_identity':ls,'epoch':time.time(),'runtime_epoch':state['epoch'],'configured_project_count':len(proofs),'scope':'native_metadata_responsiveness_only'}
    except Exception as error:
        reports['ide']['reason']=str(error) if type(error) is ValueError and re.fullmatch('[A-Z_]+',str(error)) else 'NATIVE_HEALTH_UNVERIFIED'
    reports['action_bridge']={'managed':False,'identity_verified':False,'alive':None,'healthy':None,'reason':'AUTOMATIC_IMPORT_OWNED_BY_TRANSPORT_V2'}
    return reports


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--command',choices=['heartbeat','bootstrap','report','refresh-connection'],required=True);parser.add_argument('--pid',type=int);parser.add_argument('--project-key');parser.add_argument('--native-port',type=int);parser.add_argument('--database',type=Path);args=parser.parse_args()
    from pipeline_runtime_state import snapshot,database_path
    database=args.database or database_path()
    try:
        if args.command=='heartbeat':
            if args.pid is None:raise ValueError('PID_REQUIRED')
            write_bridge_heartbeat(args.pid,runtime_path('AGENTIC_RUNTIME_SCRIPTS_DIR','companion_bridge.js'),runtime_path('AGENTIC_STATE_ROOT','COMPANION_BRIDGE_HEARTBEAT.json'),snapshot(database));result={'status':'RECORDED','scope':'bridge_loop_liveness_only'}
        elif args.command=='bootstrap':result=bootstrap(args.project_key,database)
        elif args.command=='refresh-connection':result=refresh_connection(configured_selection(args.project_key),runtime_path('AGENTIC_STATE_ROOT'),runtime_path('ANTIGRAVITY_INSTALL_ROOT','resources/bin/language_server.exe'),native_port=args.native_port)
        else:
            cfg=read_object(runtime_path('ANTIGRAVITY_DATA_ROOT','companion_bridge_config.json'))
            result={'schema_version':3,'status':'OBSERVED','observed_utc':datetime.now(timezone.utc).isoformat(),'epoch':snapshot(database).get('epoch'),'services':service_reports(state=snapshot(database),scripts=runtime_path('AGENTIC_RUNTIME_SCRIPTS_DIR'),state_root=runtime_path('AGENTIC_STATE_ROOT'),ide_exe=runtime_path('ANTIGRAVITY_INSTALL_ROOT','Antigravity.exe'),ls_exe=runtime_path('ANTIGRAVITY_INSTALL_ROOT','resources/bin/language_server.exe'),companions=cfg.get('browser',{}).get('companions',{}))}
        result.setdefault('schema_version',3)
        print(json.dumps(result,separators=(',',':')));return 0
    except Exception as error:
        reason=str(error) if isinstance(error,(ValueError,Rejected)) and re.fullmatch('[A-Z0-9_]+',str(error)) else 'NATIVE_PROBE_UNAVAILABLE'
        print(json.dumps({'schema_version':3,'status':'HOLD','reason':reason}));return 2

if __name__=='__main__':raise SystemExit(main())
