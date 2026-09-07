"""Work admission and native error normalization; never derive permission from prose."""
import hashlib
import json
from pathlib import Path
from recovery_coordinator import Coordinator, Rejected, classify_failure

RECOVERY_ROUTES = ('/nextphase','/fixcritical','/auditphase','/fastpatch','/shipcheck')
TERMINAL={'completed','done','closed','cancelled','canceled','failed','blocked'}


def read_work(root):
    root=Path(root).resolve()
    work_bytes=(root/'.agy/WORK_ITEM.json').read_bytes()
    action_bytes=(root/'.agy/NEXT_ACTION.json').read_bytes()
    work=json.loads(work_bytes.decode('utf-8-sig'));action=json.loads(action_bytes.decode('utf-8-sig'))
    if not isinstance(work,dict) or not isinstance(action,dict):raise Rejected('WORK_CONTRACT_INVALID')
    if not isinstance(work.get('work_item_id'),str) or not work['work_item_id'] or type(work.get('goal_epoch')) not in (int,str) or work['goal_epoch']=='':raise Rejected('WORK_IDENTITY_REQUIRED')
    if work.get('owner_approved') is not True or work.get('hard_stop') is not False or str(work.get('status','')).lower() in TERMINAL:raise Rejected('WORK_NOT_ACTIVE')
    if action.get('work_item_id')!=work['work_item_id'] or action.get('route') not in RECOVERY_ROUTES:raise Rejected('ACTION_BINDING_MISMATCH')
    return work,action,{'project_root':str(root),'work_item_sha256':hashlib.sha256(work_bytes).hexdigest(),'next_action_sha256':hashlib.sha256(action_bytes).hexdigest()}


def admit_work(project,root,expected_epoch,*,database):
    """Trusted validated activation/existing-work seam. Copies authority, never creates it."""
    work,action,provenance=read_work(root)
    c=Coordinator(database)
    binding={**provenance,'work_item_id':work['work_item_id'],'goal_epoch':work['goal_epoch'],'owner_approved':True,'hard_stop':False,'status':work.get('status'),'recovery_routes':list(RECOVERY_ROUTES)}
    return c.bind_work(project, work['work_item_id'], work['goal_epoch'], expected_epoch, contract=binding)


def validate_live_binding(binding):
    if not isinstance(binding,dict) or not binding.get('project_root'):raise Rejected('LIVE_WORK_BINDING_REQUIRED')
    work,action,provenance=read_work(binding['project_root'])
    for key in ('work_item_id','goal_epoch'):
        if type(work[key]) is not type(binding.get(key)) or work[key]!=binding[key]:raise Rejected('WORK_BINDING_MISMATCH')
    if provenance['work_item_sha256']!=binding.get('work_item_sha256') or provenance['next_action_sha256']!=binding.get('next_action_sha256'):raise Rejected('WORK_CHANGED_REBIND_REQUIRED')
    return work,action


def structured_failure(event,capability):
    """Configured adapter must be established by a target read-only schema probe.

    Supported normalized surfaces: original explicit http_status/error_code fields,
    or a native grpc error object. Availability is never inferred from installation.
    """
    probe={'required':'native_transcript_error_schema','fields':['error.code','error.status','http_status','error_code','retry_after','created_at'],'action':'Capture one redacted structured failed-step response from the actual language-server transcript endpoint; confirm adapter and event identity; do not induce a paid failure.'}
    if not isinstance(capability,dict) or capability.get('probe_passed') is not True or not capability.get('evidence_ref'):
        raise Rejected('NATIVE_ERROR_CAPABILITY_UNVERIFIED:'+json.dumps(probe,separators=(',',':')))
    if capability.get('compiler_provenance') is not None:
        from native_onboarding import validate_capability_provenance
        try:validate_capability_provenance(capability)
        except ValueError as error:raise Rejected(str(error))
    if not isinstance(event,dict) or not event.get('created_at'):raise Rejected('NATIVE_EVENT_IDENTITY_MISSING')
    adapter=capability.get('error_adapter')
    if adapter=='structured-http-v1':
        return classify_failure(event.get('http_status'),code=event.get('error_code',''),retry_after=event.get('retry_after'))
    if adapter=='structured-grpc-v1':
        error=event.get('error')
        if not isinstance(error,dict):raise Rejected('NATIVE_ERROR_SCHEMA_MISMATCH')
        code=error.get('code');status=error.get('status')
        if code in {'insufficient_quota','quota_exhausted','credits_exhausted'}:return 'QUOTA_EXHAUSTED'
        if status in (16,7,'UNAUTHENTICATED','PERMISSION_DENIED'):return 'AUTH'
        if status in (3,'INVALID_ARGUMENT'):return 'SCHEMA'
        if status in (1,'CANCELLED'):return 'OWNER_DECISION_REQUIRED'
        if status in (14,'UNAVAILABLE'):return 'TRANSIENT_NETWORK'
        if status in (13,'INTERNAL'):return 'TRANSIENT_SERVER'
        return classify_failure(error.get('http_status'),code=code or '',retry_after=error.get('retry_after'))
    raise Rejected('NATIVE_ERROR_ADAPTER_UNSUPPORTED')


def prepare_recovery_send(comp,message,*,work_id,goal_epoch,event_id,expected_runtime_instance,expected_project_root,executable=None,state_root=None,execute=None,observer=None,connection_provider=None,metadata_probe=None):
    """Prepare a verified callback for the guard's existing single final lease.

    Preflight is read-only; only invoking the returned callback sends. It returns
    success solely after fresh exact recipient/content API acknowledgement. No
    independent lease, injection ID, retry, native message ID or progress claim.
    """
    import os
    import subprocess
    from types import SimpleNamespace
    from runtime_paths import runtime_path
    from native_health import connection,probe_native,same_path,strict_loads
    from native_ack import parse_recovery_acceptance
    from process_identity import observe_pid,identity_matches,instance_from_identity
    if not isinstance(comp,dict) or not comp.get('projectPath') or not same_path(comp['projectPath'],expected_project_root):raise Rejected('RECOVERY_NATIVE_WORK_ROOT_MISMATCH')
    if not isinstance(message,str) or not message:raise Rejected('RECOVERY_MESSAGE_REQUIRED')
    executable=Path(executable or runtime_path('ANTIGRAVITY_INSTALL_ROOT','resources/bin/language_server.exe'))
    state_root=Path(state_root or runtime_path('AGENTIC_STATE_ROOT'))
    execute=execute or subprocess.run;observer=observer or observe_pid
    connection_provider=connection_provider or connection;metadata_probe=metadata_probe or probe_native
    native_env,identity=connection_provider(state_root,executable)
    if not same_path(identity['executable'],executable):raise Rejected('NATIVE_EXECUTABLE_IDENTITY_MISMATCH')
    proof=metadata_probe(comp,state_root,executable,execute=execute,observer=observer)
    if proof.get('status')!='VERIFIED' or proof.get('project_identity_verified') is not True or proof.get('workspace_identity_verified') is not True or not identity_matches(identity,proof.get('process_identity')):raise Rejected('NATIVE_RECOVERY_METADATA_UNVERIFIED')
    instance=instance_from_identity(identity)
    if instance!=expected_runtime_instance:raise Rejected('RUNTIME_INSTANCE_CHANGED_RECONCILE_REQUIRED')
    conversation=comp.get('antigravityConversationId')
    if not isinstance(conversation,str) or not conversation:raise Rejected('NATIVE_CONVERSATION_REQUIRED')
    env=os.environ.copy();env.update(native_env);env.update(ANTIGRAVITY_PROJECT_ID=comp['projectId'],ANTIGRAVITY_CONVERSATION_ID=conversation);env.pop('ANTIGRAVITY_SOURCE_METADATA',None)
    def send():
        if not identity_matches(identity,observer(identity['pid'])):raise Rejected('NATIVE_PROCESS_CHANGED_BEFORE_RECOVERY_SEND')
        result=execute([str(executable),'agentapi','send-message','--title=Auto-Resume Interrupted Task',conversation,message],env=env,capture_output=True,text=True,encoding='utf-8',timeout=15,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        if not identity_matches(identity,observer(identity['pid'])):raise Rejected('NATIVE_PROCESS_CHANGED_DURING_RECOVERY_SEND')
        if result.returncode!=0:raise Rejected('NATIVE_RECOVERY_SEND_UNCERTAIN')
        receipt=parse_recovery_acceptance(strict_loads(result.stdout),conversation,message,work_id,goal_epoch,event_id)
        receipt['runtime_instance_sha256']=hashlib.sha256(instance.encode()).hexdigest()
        return SimpleNamespace(returncode=0,stdout='',stderr='',effect_receipt=receipt)
    return send
