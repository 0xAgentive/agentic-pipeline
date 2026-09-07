#!/usr/bin/env python3
"""Compile existing exact-selected native evidence into a reviewable config patch.

No sends/services, no token output, no configuration overwrite. The optional native
metadata query is read-only. Echoes and prose never establish receipt/error schema.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
from native_health import read_object,probe_native,strict_loads
from runtime_paths import KEYS,runtime_path

KNOWN=frozenset({'response','conversationMetadata','metadata','projectId','workspaceUris','created_at','error','code','status','http_status','error_code','retry_after','messageId','message_id','turnId','turn_id','receiptId','receipt_id','operation_id','conversationId','conversation_id','role','sendMessage','recipientId','content'})
RECEIPTS=frozenset({'messageId','message_id','turnId','turn_id','receiptId','receipt_id','operation_id'})
CODES=frozenset({'insufficient_quota','quota_exhausted','credits_exhausted','unauthenticated','invalid_api_key','permission_denied','invalid_argument','invalid_schema','validation_error','policy_violation','policy_denied','rate_limit_exceeded','temporary_rate_limit','stream_interrupted','connection_reset','timeout','connection_refused'})


def sha(data):return hashlib.sha256(data).hexdigest()


def shape(value,depth=0):
    if depth>6:return 'depth_limited'
    if isinstance(value,dict):
        result={k:shape(v,depth+1) for k,v in value.items() if k in KNOWN}
        unknown=len(set(value)-KNOWN)
        if unknown:result['unknown_field_count']=unknown
        return result
    if isinstance(value,list):return {'type':'array','count':len(value)}
    return 'null' if value is None else type(value).__name__


def exact_bytes(path,limit=32*1024*1024):
    path=Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size>limit:raise ValueError('EXACT_REGULAR_EVIDENCE_REQUIRED')
    before=path.stat();raw=path.read_bytes();after=path.stat()
    if (before.st_ino,before.st_mtime_ns,before.st_size)!=(after.st_ino,after.st_mtime_ns,after.st_size):raise ValueError('EVIDENCE_CHANGED_DURING_READ')
    return raw


def exact_event(path,line):
    if type(line) is not int or line<1:raise ValueError('EXACT_EVENT_LINE_REQUIRED')
    raw=exact_bytes(path);lines=raw.splitlines()
    if line>len(lines):raise ValueError('EXACT_EVENT_LINE_UNAVAILABLE')
    value=strict_loads(lines[line-1].decode('utf-8-sig'))
    if not isinstance(value,dict):raise ValueError('EVENT_OBJECT_REQUIRED')
    source={'path':str(Path(path).resolve()),'sha256':sha(raw),'line':line,'line_sha256':sha(lines[line-1]),'selection':'exact_jsonl_line'}
    return value,source


def capability_provenance(sources):
    return {'schema_version':3,'compiler':'native_onboarding_v3','sources':sources}


def validate_capability_provenance(capability):
    provenance=capability.get('compiler_provenance') if isinstance(capability,dict) else None
    if not isinstance(provenance,dict) or provenance.get('schema_version')!=3 or provenance.get('compiler')!='native_onboarding_v3' or not isinstance(provenance.get('sources'),list) or not provenance['sources']:raise ValueError('COMPILED_NATIVE_PROVENANCE_REQUIRED')
    for source in provenance['sources']:
        if source.get('selection')=='exact_jsonl_line':
            _,observed=exact_event(source['path'],source['line'])
            if observed['line_sha256']!=source.get('line_sha256'):raise ValueError('NATIVE_EVIDENCE_LINE_CHANGED')
        elif source.get('selection')=='exact_response_file':
            if sha(exact_bytes(source['path']))!=source.get('sha256'):raise ValueError('NATIVE_RESPONSE_EVIDENCE_CHANGED')
        else:raise ValueError('NATIVE_PROVENANCE_SELECTION_UNSUPPORTED')
    return True


def compile_recovery(transcript,line):
    event,source=exact_event(transcript,line)
    report={'status':'UNKNOWN','schema':shape(event),'provenance':source,'capability':None,'reason':'NO_SUPPORTED_STRUCTURED_ERROR'}
    if not isinstance(event.get('created_at'),str) or not event['created_at']:return report
    adapter=None
    # Numeric error_code has no established HTTP/gRPC namespace in real history.
    if type(event.get('http_status')) is int and 400<=event['http_status']<=599 or isinstance(event.get('error_code'),str) and event['error_code'] in CODES:
        adapter='structured-http-v1'
    error=event.get('error')
    if isinstance(error,dict) and (isinstance(error.get('code'),str) and error['code'] in CODES or type(error.get('status')) is int and error['status'] in (1,3,7,13,14,16) or error.get('status') in ('CANCELLED','INVALID_ARGUMENT','PERMISSION_DENIED','INTERNAL','UNAVAILABLE','UNAUTHENTICATED')):
        if adapter:return {**report,'reason':'AMBIGUOUS_ERROR_ADAPTER'}
        adapter='structured-grpc-v1'
    if adapter:
        report.update(status='SCHEMA_VERIFIED',reason='EXISTING_STRUCTURED_EVENT',capability={'probe_passed':True,'evidence_ref':'sha256:'+source['line_sha256'],'error_adapter':adapter,'compiler_provenance':capability_provenance([source])})
    return report


def compile_dispatch(response_path,pointer,transcript,line,conversation):
    if not isinstance(pointer,list) or not pointer or len(pointer)>8 or any(not isinstance(k,str) or k not in KNOWN for k in pointer) or pointer[-1] not in RECEIPTS:raise ValueError('EXACT_SUPPORTED_RECEIPT_POINTER_REQUIRED')
    raw=exact_bytes(response_path);body=strict_loads(raw.decode('utf-8-sig'));event,source=exact_event(transcript,line)
    response_source={'path':str(Path(response_path).resolve()),'sha256':sha(raw),'selection':'exact_response_file'}
    report={'status':'UNKNOWN','response_schema':shape(body),'event_schema':shape(event),'provenance':[response_source,source],'capability':None,'reason':'NATIVE_SENT_EVENT_IDENTITY_UNVERIFIED'}
    value=body
    try:
        for key in pointer:value=value[key]
    except (KeyError,TypeError):return report
    if not isinstance(value,str) or not value or event.get('role')!='user' or not isinstance(event.get('created_at'),str) or not event['created_at']:return report
    event_id=event.get('message_id',event.get('messageId'));event_conversation=event.get('conversation_id',event.get('conversationId'))
    # Turn/receipt values cannot stand in for a message ID without a separately
    # established event mapping. Only an exact message identity is supported.
    if pointer[-1] not in ('messageId','message_id') or event_id!=value or event_conversation!=conversation:return report
    report.update(status='EXISTING_RECEIPT_MATCHED',reason='EXACT_USER_MESSAGE_AND_CONVERSATION_MATCH',capability={'probe_passed':True,'agentapi_send_message':True,'evidence_ref':'sha256:'+response_source['sha256'],'receipt_pointer':pointer,'compiler_provenance':capability_provenance([response_source,source]),'conversation_sha256':sha(conversation.encode())})
    return report


def collect(runtime_config,bridge_config,project_key,*,native_metadata=False,error_event_line=None,send_response=None,receipt_pointer=None,sent_event_line=None):
    runtime=read_object(runtime_config);bridge=read_object(bridge_config)
    if set(runtime)-KEYS-{'schema_version'} or runtime.get('schema_version',1)!=1:raise ValueError('INVALID_RUNTIME_CONFIG')
    companions=bridge.get('browser',{}).get('companions',{});comp=companions.get(project_key) if isinstance(companions,dict) else None
    if not isinstance(comp,dict) or not isinstance(comp.get('antigravityConversationId'),str) or not re.fullmatch('[A-Za-z0-9_-]{1,128}',comp['antigravityConversationId']):raise ValueError('EXACT_NATIVE_PROJECT_SELECTION_REQUIRED')
    rp=lambda key,suffix='':runtime_path(key,suffix,config=runtime,environ={})
    transcript=Path(rp('ANTIGRAVITY_DATA_ROOT'))/'brain'/comp['antigravityConversationId']/'.system_generated/logs/transcript.jsonl'
    report={'schema_version':3,'status':'OBSERVED','scope':'READ_ONLY_NATIVE_ONBOARDING','effects_performed':False,'runtime_config_sha256':sha(exact_bytes(runtime_config)),'bridge_config_sha256':sha(exact_bytes(bridge_config)),'project_key':project_key,'configured_conversation_sha256':sha(comp['antigravityConversationId'].encode()),'capability_patch':{'browser':{'companions':{project_key:{}}}},'native_metadata':{'status':'NOT_RUN'},'recovery':{'status':'UNKNOWN','capability':None},'dispatch':{'status':'UNKNOWN','capability':None,'reason':'EXISTING_NATIVE_SEND_RESPONSE_AND_MATCHING_USER_EVENT_REQUIRED'}}
    try:
        raw=exact_bytes(transcript);lines=raw.splitlines()
        if error_event_line is not None:recovery=compile_recovery(transcript,error_event_line)
        else:
            candidates=[]
            for n in range(max(1,len(lines)-24),len(lines)+1):
                try:candidates.append(compile_recovery(transcript,n))
                except (ValueError,UnicodeError):continue
            valid=[x for x in candidates if x['capability']]
            recovery=valid[-1] if valid else {'status':'UNKNOWN','capability':None,'reason':'NO_SUPPORTED_ERROR_IN_LAST_25_EVENTS','candidate_shapes':[x['schema'] for x in candidates],'source_sha256':sha(raw)}
        report['recovery']=recovery
        if recovery['capability']:report['capability_patch']['browser']['companions'][project_key]['nativeRecoveryCapability']=recovery['capability']
        if send_response is not None:
            if receipt_pointer is None or sent_event_line is None:raise ValueError('EXACT_RECEIPT_AND_SENT_EVENT_SELECTION_REQUIRED')
            report['dispatch']=compile_dispatch(send_response,receipt_pointer,transcript,sent_event_line,comp['antigravityConversationId'])
    except Exception as error:
        report['transcript_hold']=str(error) if isinstance(error,ValueError) and re.fullmatch('[A-Z0-9_]+',str(error)) else 'EXACT_TRANSCRIPT_UNAVAILABLE'
    if native_metadata:
        try:report['native_metadata']=probe_native(comp,rp('AGENTIC_STATE_ROOT'),rp('ANTIGRAVITY_INSTALL_ROOT','resources/bin/language_server.exe'))
        except Exception:report['native_metadata']={'status':'UNKNOWN','reason':'CURRENT_NATIVE_METADATA_UNVERIFIED'}
    dispatch=report['dispatch'].get('capability')
    if dispatch and report['native_metadata'].get('status')=='VERIFIED':
        dispatch['target_process_identity']=report['native_metadata']['process_identity']
        report['capability_patch']['browser']['companions'][project_key]['nativeDispatchCapability']=dispatch
    elif dispatch:report['dispatch']['reason']='EXISTING_RECEIPT_MATCHED_CURRENT_TARGET_METADATA_REQUIRED'
    report['ready_for_review']=bool(report['capability_patch']['browser']['companions'][project_key])
    return report


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--runtime-config',type=Path,required=True);p.add_argument('--bridge-config',type=Path,required=True);p.add_argument('--project-key',required=True);p.add_argument('--native-metadata',action='store_true');p.add_argument('--error-event-line',type=int);p.add_argument('--send-response',type=Path);p.add_argument('--receipt-pointer',type=json.loads);p.add_argument('--sent-event-line',type=int);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.output.exists() or a.output.is_symlink():p.error('New output path required')
    try:report=collect(a.runtime_config,a.bridge_config,a.project_key,native_metadata=a.native_metadata,error_event_line=a.error_event_line,send_response=a.send_response,receipt_pointer=a.receipt_pointer,sent_event_line=a.sent_event_line)
    except Exception:report={'schema_version':3,'status':'UNKNOWN','reason':'EXACT_INPUT_CONFIGURATION_UNAVAILABLE','effects_performed':False}
    with a.output.open('x',encoding='utf-8') as f:json.dump(report,f,ensure_ascii=False,indent=2);f.write('\n')
    print(json.dumps({'status':report['status'],'ready_for_review':report.get('ready_for_review',False),'effects_performed':False}));return 0

if __name__=='__main__':raise SystemExit(main())
