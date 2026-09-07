#!/usr/bin/env python3
"""Native delivery seam using the existing agentapi command; no progress/release claim."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from effect_owner import EffectOwner
from native_recovery import validate_live_binding
from pipeline_runtime_state import database_path
from process_identity import instance_from_identity, observe_pid, identity_matches
from recovery_coordinator import Rejected
from native_health import strict_loads, validate_metadata
from native_ack import ADAPTER, parse_acceptance, acceptance_receipt_valid, probe_report, validate_ack_capability
from runtime_paths import runtime_path


def load_module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module


def native_ports(config,comp,*,probe_ack=False):
    capability=comp.get('nativeDispatchCapability')
    if probe_ack:
        capability={'ack_adapter':ADAPTER,'target_probe_in_progress':True}
    elif not isinstance(capability,dict) or capability.get('probe_passed') is not True or capability.get('agentapi_send_message') is not True or not capability.get('evidence_ref'):
        raise Rejected('NATIVE_DISPATCH_CAPABILITY_UNVERIFIED')
    exe=Path(runtime_path('ANTIGRAVITY_INSTALL_ROOT','resources/bin/language_server.exe'))
    if not exe.is_file() or exe.is_symlink():raise Rejected('NATIVE_EXECUTABLE_MISSING')
    if not probe_ack and capability.get('ack_adapter')==ADAPTER:
        try:validate_ack_capability(capability,comp['antigravityConversationId'],exe)
        except ValueError as error:raise Rejected(str(error))
    elif not probe_ack:
        if not isinstance(capability.get('receipt_pointer'),list) or not capability['receipt_pointer']:raise Rejected('NATIVE_DISPATCH_CAPABILITY_UNVERIFIED')
        from native_onboarding import validate_capability_provenance
        try:validate_capability_provenance(capability)
        except ValueError as error:raise Rejected(str(error))
    capability={**capability,'target_executable_sha256':hashlib.sha256(exe.read_bytes()).hexdigest()}
    from native_health import connection as verified_local_connection
    connection,identity=verified_local_connection(runtime_path('AGENTIC_STATE_ROOT'),exe)
    from native_health import same_path
    if not same_path(identity['executable'],exe):raise Rejected('NATIVE_EXECUTABLE_IDENTITY_MISMATCH')
    instance=instance_from_identity(identity)
    env=os.environ.copy();env.update(connection);env.pop('ANTIGRAVITY_SOURCE_METADATA',None)
    def run(args):
        if not identity_matches(identity,observe_pid(identity['pid'])):raise Rejected('NATIVE_PROCESS_CHANGED_BEFORE_CALL')
        result=subprocess.run([str(exe),'agentapi',*args],env=env,capture_output=True,text=True,encoding='utf-8',timeout=15,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        if not identity_matches(identity,observe_pid(identity['pid'])):raise Rejected('NATIVE_PROCESS_CHANGED_DURING_CALL')
        return result
    return run,capability,instance,env


def inject(root,project_key,*,database=None,config_path=None,bridge=None,ports=None,expected_packet_id=None,expected_source_sha256=None,expected_epoch=None,probe_native_ack=False):
    root=Path(root).resolve();database=Path(database) if database else database_path()
    cfg=strict_loads(Path(config_path or runtime_path('ANTIGRAVITY_DATA_ROOT','companion_bridge_config.json')).read_text(encoding='utf-8-sig'))
    comp=cfg.get('browser',{}).get('companions',{}).get(project_key)
    if not isinstance(comp,dict) or not comp.get('projectPath') or Path(comp['projectPath']).resolve()!=root or not comp.get('antigravityConversationId') or not comp.get('projectId'):
        raise Rejected('NATIVE_PROJECT_CONVERSATION_BINDING_REQUIRED')
    bridge=bridge or load_module('injection_action_bridge',Path(__file__).with_name('companion_action_bridge.py'))
    owner=EffectOwner(database)
    with bridge.project_transaction_lock(root):
        bridge.recover_import_transaction(root)
        packet=bridge.load_json(root/'.agy/inbox/ACTIVE_ACTION_PACKET/ACTION_PACKET.json');receipt=bridge.load_json(root/'.agy/ACTION_PACKET_RECEIPT.json')
        if expected_packet_id is not None and packet.get('packet_id')!=expected_packet_id:raise Rejected('EXPECTED_PACKET_ID_MISMATCH')
        if expected_source_sha256 is not None and receipt.get('source_sha256')!=expected_source_sha256:raise Rejected('EXPECTED_SOURCE_HASH_MISMATCH')
        bridge.validate_packet(packet,require_capability=True);bridge.validate_current_identity(packet,root)
        capability=bridge.load_json(root/'.agy/ACTION_BRIDGE_CAPABILITY.json')
        if capability.get('project_id')!=packet['project_id'] or capability.get('capability_token')!=packet['capability_token']:raise Rejected('PACKET_CAPABILITY_MISMATCH')
        if receipt.get('packet_id')!=packet['packet_id'] or not receipt.get('activated_at_utc') or not bridge.verify_generation(root/'.agy/inbox/ACTIVE_ACTION_PACKET',receipt.get('active_manifest_sha256',''),packet['packet_id']):raise Rejected('VERIFIED_ACTIVATION_REQUIRED')
        state=owner.coordinator.snapshot()
        if expected_epoch is not None and state['epoch']!=expected_epoch:raise Rejected('STALE_EPOCH')
        binding=state.get('work_bindings',{}).get(project_key)
        work,action=validate_live_binding(binding)
        if action.get('route')!=packet['route'] or work.get('goal')!=packet['goal']:raise Rejected('ACTIVATED_ROUTE_GOAL_MISMATCH')
        operation='injection:'+packet['packet_id'];previous=owner.observe(project_key,operation)
        if previous and previous['status']=='SUCCEEDED':
            proof=previous.get('receipt') or {}
            if proof.get('packet_id')!=packet['packet_id'] or proof.get('conversation_id')!=comp['antigravityConversationId'] or not (proof.get('message_id') or acceptance_receipt_valid(proof,packet['packet_id'],comp['antigravityConversationId'])):raise Rejected('DELIVERY_RECEIPT_IDENTITY_MISMATCH')
            bridge._acknowledge_packet_locked(root,packet['packet_id'],receipt['packet_payload_sha256'],'injection',True)
            return {'status':'PASS','completion_scope':'injection_only','delivery_status':'API_ACCEPTED' if proof.get('api_accepted') else 'DELIVERED','replayed':True,**proof}
        if receipt.get('injected_at_utc'):raise Rejected('LEGACY_INJECTION_RECONCILIATION_REQUIRED')
        run,cap,instance,env=ports(cfg,comp) if ports else native_ports(cfg,comp,probe_ack=probe_native_ack)
        metadata=run(['get-conversation-metadata',comp['antigravityConversationId']])
        try:native_project=strict_loads(metadata.stdout)['response']['conversationMetadata']['metadata']['projectId']
        except (ValueError,TypeError,KeyError):raise Rejected('NATIVE_METADATA_SCHEMA_UNVERIFIED')
        if metadata.returncode!=0 or native_project!=comp['projectId']:raise Rejected('NATIVE_CONVERSATION_PROJECT_MISMATCH')
        if not ports or cap.get('ack_adapter')==ADAPTER:
            try:validate_metadata(strict_loads(metadata.stdout),comp)
            except ValueError as error:raise Rejected(str(error))
        # Fresh observed command+creation identity fences old runtime workers.
        original_epoch=state['epoch']
        state=owner.coordinator.observe_runtime(instance)
        if state['epoch']!=original_epoch:raise Rejected('RUNTIME_INSTANCE_CHANGED_RECONCILE_REQUIRED')
        env['ANTIGRAVITY_PROJECT_ID']=native_project;env['ANTIGRAVITY_CONVERSATION_ID']=comp['antigravityConversationId']
        lease=owner.acquire('activation-injector',project_key,packet['packet_id'],state['epoch'],receipt['packet_payload_sha256'],'send',operation,work_item_id=work['work_item_id'],goal_epoch=work['goal_epoch'])
        owner.begin_effect(lease)
        try:
            message=packet['route']+'\n\nExecute the already approved current work item '+work['work_item_id']+' using .agy/WORK_ITEM.json and .agy/NEXT_ACTION.json. Packet '+packet['packet_id']+'. Preserve its goal, scope, pause and owner-decision boundaries.'
            result=run(['send-message','--title=Approved Action Packet',comp['antigravityConversationId'],message])
            if result.returncode!=0:raise Rejected('NATIVE_SEND_RESULT_UNCERTAIN')
            response=strict_loads(result.stdout)
            proof={'packet_id':packet['packet_id'],'work_item_id':work['work_item_id'],'conversation_id':comp['antigravityConversationId']}
            if cap.get('ack_adapter')==ADAPTER:
                proof.update(parse_acceptance(response,comp['antigravityConversationId'],message,operation))
                proof.update(target_executable_sha256=cap.get('target_executable_sha256'),runtime_instance_sha256=hashlib.sha256(instance.encode()).hexdigest())
            else:
                if not isinstance(response,dict) or 'error' in response:raise Rejected('NATIVE_SEND_RESULT_UNCERTAIN')
                for key in cap['receipt_pointer']:response=response[key]
                if not isinstance(response,str) or not response:raise Rejected('NATIVE_SENT_IDENTITY_UNVERIFIED')
                proof['message_id']=response
            owner.ack(lease,'SUCCEEDED',proof)
            bridge._acknowledge_packet_locked(root,packet['packet_id'],receipt['packet_payload_sha256'],'injection',True)
            return {'status':'PASS','completion_scope':'injection_only','delivery_status':'API_ACCEPTED' if proof.get('api_accepted') else 'DELIVERED','replayed':False,**proof}
        except BaseException:
            try:owner.ack(lease,'UNCERTAIN')
            except Rejected:pass
            raise


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--project-root',type=Path,required=True);parser.add_argument('--project-key',required=True);parser.add_argument('--recovery-db',type=Path);parser.add_argument('--config',type=Path);parser.add_argument('--expected-packet-id');parser.add_argument('--expected-source-sha256');parser.add_argument('--expected-epoch',type=int);parser.add_argument('--probe-native-ack',action='store_true');parser.add_argument('--probe-output',type=Path);args=parser.parse_args()
    if args.probe_native_ack and (not args.probe_output or args.expected_epoch is None or not args.expected_packet_id or not args.expected_source_sha256):parser.error('Native canary requires exact packet, source hash, epoch and a new probe output')
    if bool(args.probe_output)!=args.probe_native_ack:parser.error('Probe output is only for explicit native canary')
    report_file=args.probe_output.open('x',encoding='utf-8') if args.probe_output else None
    try:
        result=inject(args.project_root,args.project_key,database=args.recovery_db,config_path=args.config,expected_packet_id=args.expected_packet_id,expected_source_sha256=args.expected_source_sha256,expected_epoch=args.expected_epoch,probe_native_ack=args.probe_native_ack)
        if report_file:json.dump(probe_report(result,args.project_key,args.probe_output),report_file,indent=2);report_file.close()
        print(json.dumps(result,ensure_ascii=False));return 0
    except Exception as error:
        if report_file and not report_file.closed:
            json.dump({'schema_version':3,'status':'HOLD','reason':'NATIVE_CANARY_NOT_ACKNOWLEDGED','effects_performed':'consult_durable_operation_journal','completion_scope':'native_api_acceptance_only'},report_file);report_file.close()
        # Never echo native stdout, argv, environment or provider secrets.
        print(json.dumps({'status':'HOLD','reason':str(error) if isinstance(error,Rejected) else type(error).__name__,'completion_scope':'native_delivery_only'},ensure_ascii=False));return 2


if __name__=='__main__':raise SystemExit(main())
