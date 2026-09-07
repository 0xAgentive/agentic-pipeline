"""Observed agentapi acceptance contract. No fabricated native message identity."""
import hashlib
import json
from pathlib import Path
import re
from native_health import strict_loads

ADAPTER='agentapi-send-echo-v1'


def digest(value):return hashlib.sha256(value).hexdigest()


def parse_echo(body,conversation,message):
    if not all(isinstance(x,str) and x for x in (conversation,message)):raise ValueError('NATIVE_ACK_REQUEST_IDENTITY_REQUIRED')
    if not isinstance(body,dict) or 'error' in body:raise ValueError('NATIVE_ACK_ERROR_OR_SCHEMA_UNKNOWN')
    try:ack=body['response']['sendMessage']
    except (KeyError,TypeError):raise ValueError('NATIVE_ACK_SCHEMA_UNKNOWN')
    if not isinstance(ack,dict) or ack.get('recipientId')!=conversation or ack.get('content')!=message:raise ValueError('NATIVE_ACK_RECIPIENT_OR_CONTENT_MISMATCH')
    return {'ack_adapter':ADAPTER,'api_accepted':True,'request_sha256':digest(message.encode()),'response_sha256':digest(json.dumps(body,sort_keys=True,separators=(',',':')).encode()),'execution_observed':False,'exactly_once_proven':False,'completion_scope':'native_api_acceptance_only'}


def parse_acceptance(body,conversation,message,operation):
    if not isinstance(operation,str) or not operation.startswith('injection:') or operation=='injection:':raise ValueError('NATIVE_ACK_REQUEST_IDENTITY_REQUIRED')
    return {**parse_echo(body,conversation,message),'operation_id':operation}


def parse_recovery_acceptance(body,conversation,message,work_id,goal_epoch,event_id):
    if not all(isinstance(x,str) and x for x in (work_id,event_id)) or type(goal_epoch) not in (str,int):raise ValueError('NATIVE_RECOVERY_IDENTITY_REQUIRED')
    operation=digest(json.dumps([work_id,goal_epoch,event_id],separators=(',',':')).encode())
    return {**parse_echo(body,conversation,message),'effect_kind':'recovery','operation_id':operation,'work_item_id':work_id,'goal_epoch':goal_epoch,'conversation_sha256':digest(conversation.encode()),'event_sha256':digest(event_id.encode())}


def acceptance_receipt_valid(proof,packet_id,conversation):
    return isinstance(proof,dict) and proof.get('ack_adapter')==ADAPTER and proof.get('api_accepted') is True and proof.get('operation_id')=='injection:'+packet_id and proof.get('packet_id')==packet_id and proof.get('conversation_id')==conversation and all(isinstance(proof.get(k),str) and re.fullmatch('[0-9a-f]{64}',proof[k]) for k in ('request_sha256','response_sha256')) and proof.get('execution_observed') is False and proof.get('exactly_once_proven') is False


def receipt_digest(proof):return digest(json.dumps(proof,sort_keys=True,separators=(',',':')).encode())


def probe_report(result,project_key,evidence_path):
    if not acceptance_receipt_valid(result,result.get('packet_id',''),result.get('conversation_id','')) or not result.get('target_executable_sha256'):raise ValueError('CURRENT_TARGET_ACK_PROOF_REQUIRED')
    cap={'probe_passed':True,'agentapi_send_message':True,'ack_adapter':ADAPTER,'evidence_ref':'sha256:'+receipt_digest(result),'probe_evidence_path':str(Path(evidence_path).resolve()),'target_executable_sha256':result['target_executable_sha256'],'conversation_sha256':digest(result['conversation_id'].encode()),'scope':'native_api_acceptance_only'}
    return {'schema_version':3,'status':'API_ACCEPTED','receipt':result,'capability_patch':{'browser':{'companions':{project_key:{'nativeDispatchCapability':cap}}}},'effects_performed':True,'completion_scope':'native_api_acceptance_only','exactly_once_proven':False,'execution_observed':False}


def validate_ack_capability(capability,conversation,executable):
    if not isinstance(capability,dict) or capability.get('ack_adapter')!=ADAPTER or capability.get('probe_passed') is not True or capability.get('agentapi_send_message') is not True:raise ValueError('NATIVE_ACK_CAPABILITY_UNVERIFIED')
    path=Path(capability.get('probe_evidence_path',''))
    if path.is_symlink() or not path.is_file() or path.stat().st_size>1024*1024:raise ValueError('EXACT_NATIVE_ACK_EVIDENCE_REQUIRED')
    report=strict_loads(path.read_text(encoding='utf-8-sig'));receipt=report.get('receipt')
    if not isinstance(receipt,dict) or not acceptance_receipt_valid(receipt,receipt.get('packet_id',''),conversation) or capability.get('evidence_ref')!='sha256:'+receipt_digest(receipt):raise ValueError('NATIVE_ACK_EVIDENCE_MISMATCH')
    binary=digest(Path(executable).read_bytes())
    if binary!=capability.get('target_executable_sha256') or binary!=receipt.get('target_executable_sha256') or capability.get('conversation_sha256')!=digest(conversation.encode()):raise ValueError('NATIVE_ACK_TARGET_CHANGED_REPROBE_REQUIRED')
    return True
