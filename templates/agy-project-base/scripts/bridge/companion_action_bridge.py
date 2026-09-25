#!/usr/bin/env python3
from __future__ import annotations
import argparse,contextlib,datetime as dt,hashlib,hmac,io,json,math,os,re,shutil,stat,sys,tempfile,time,zipfile
from pathlib import Path
from typing import Any

def configure_utf8_standard_streams():
 for stream,errors in ((sys.stdout,'strict'),(sys.stderr,'backslashreplace')):
  reconfigure=getattr(stream,'reconfigure',None)
  if callable(reconfigure):reconfigure(encoding='utf-8',errors=errors)

SCHEMA_VERSION='1.2.9'
ECOSYSTEM_VERSION='1.2.27'
VALID_OPERATIONS={'new_work_item','continue_work_item'}
VALID_ROUTES={'/nextphase','/fixcritical','/auditphase','/fastpatch','/shipcheck'}
HEADINGS=['## Что происходит','## Что уже сделано','## Что будет дальше','## Нужно ли что-то от владельца']

def sha256_file(path:Path)->str:
 h=hashlib.sha256()
 with path.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()

def atomic_json(path:Path,value:Any):
 path.parent.mkdir(parents=True,exist_ok=True);tmp=path.with_name(f'{path.name}.tmp-{os.getpid()}-{time.time_ns()}');tmp.write_bytes((json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode('utf-8'));os.replace(tmp,path)

def append_jsonl(path:Path,value:Any):
 path.parent.mkdir(parents=True,exist_ok=True)
 with path.open('a',encoding='utf-8') as f:f.write(json.dumps(value,ensure_ascii=False)+'\n')

def record_metric(project_root:Path,operation:str,duration_ms:float,success:bool,error:str|None=None):
 try:
  metrics_path=project_root/'.agy'/'RUN_METRICS.ndjson'
  append_jsonl(metrics_path,{
   'schema_version':'1.0.0',
   'at_utc':dt.datetime.now(dt.timezone.utc).isoformat(),
   'operation':operation,
   'duration_ms':round(duration_ms,2),
   'success':success,
   'status':'completed' if success else 'failed',
   'error':str(error or '')
  })
 except Exception:pass

def load_json(path:Path):return json.loads(path.read_text(encoding='utf-8-sig'))

def set_windows_clipboard_command(text: str):
    try:
        import ctypes
        CF_UNICODETEXT = 13
        GMEM_MOVEABLE = 0x0002
        user32 = ctypes.windll.user32
        kernel32 = ctypes.windll.kernel32
        kernel32.GlobalAlloc.restype = ctypes.c_void_p
        kernel32.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
        kernel32.GlobalLock.restype = ctypes.c_void_p
        kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
        kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
        user32.SetClipboardData.restype = ctypes.c_void_p
        user32.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]
        for attempt in range(5):
            if user32.OpenClipboard(None):
                user32.EmptyClipboard()
                encoded = text.encode('utf-16-le') + b'\x00\x00'
                h_mem = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(encoded))
                if h_mem:
                    ptr = kernel32.GlobalLock(h_mem)
                    if ptr:
                        ctypes.memmove(ptr, encoded, len(encoded))
                        kernel32.GlobalUnlock(h_mem)
                        user32.SetClipboardData(CF_UNICODETEXT, h_mem)
                user32.CloseClipboard()
                break
            time.sleep(0.05)
        user32.MessageBeep(0x00000040)
    except Exception:
        pass


# Schema parity source: schemas/companion/action-packet.schema.json (0092ccb).
# SHA-256: 509ef172b1f79710bd28350ee2b2a46c63bf21f646366cc4b193bb27b817946e
REQUIRED_FIELDS={'schema_version','ecosystem_version','packet_id','project_id','operation','route','goal','assurance_mode','owner_approved','owner_interaction_policy','scope_binding','technical_task_markdown','owner_summary_ru','created_at_utc','expires_at_utc'}
ALLOWED_FIELDS=REQUIRED_FIELDS|{'packet_format','project_root_hint','capability_token','work_item_id','goal_epoch','owner_goal_sha256','stage_profile','acceptance','non_goals','risk_hints','audit_dimensions','forensic_program','artifact_id','goal_mode','execution_semantics','context_binding'}
MAX_SAFE_INTEGER=9007199254740991


def parse_utc(value):
 if not isinstance(value,str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})',value):raise ValueError('Packet timestamp must be RFC3339 with timezone')
 if value[-1]!='Z' and (int(value[-5:-3])>23 or int(value[-2:])>59):raise ValueError('Packet timestamp timezone is invalid')
 parsed=dt.datetime.fromisoformat(value[:-1]+'+00:00' if value.endswith('Z') else value)
 return parsed.astimezone(dt.timezone.utc)

def validate_summary(text:str):
 if not isinstance(text,str):raise ValueError('Owner summary must be a string')
 for h in HEADINGS:
  if h not in text:raise ValueError(f'Owner summary heading missing: {h}')
 if len(text)>2400 or '```' in text:raise ValueError('Owner summary is not compact plain-language output')

def is_safe_integer(value):
 return type(value) in (int,float) and 1<=value<=MAX_SAFE_INTEGER and math.isfinite(value) and int(value)==value

def validate_packet(packet:dict[str,Any],*,require_capability:bool=False,allow_capability:bool=True,now_utc=None)->dict[str,Any]:
 if type(packet) is not dict:raise ValueError('Packet must be an object')
 if REQUIRED_FIELDS-set(packet):raise ValueError(f'Packet missing required fields: {REQUIRED_FIELDS-set(packet)}')
 try:json.dumps(packet,allow_nan=False)
 except (TypeError,ValueError):raise ValueError('Packet must contain finite JSON values')
 if packet['schema_version']!=SCHEMA_VERSION or packet['ecosystem_version']!=ECOSYSTEM_VERSION:raise ValueError('Unsupported ecosystem/action packet version')
 if 'packet_format' in packet and packet['packet_format']!='single_json':raise ValueError('Unsupported packet format')
 if packet['owner_approved'] is not True or packet['owner_interaction_policy']!='hard_stop_only':raise ValueError('Packet is not owner-approved')
 if not isinstance(packet['operation'],str) or not isinstance(packet['route'],str) or packet['operation'] not in VALID_OPERATIONS or packet['route'] not in VALID_ROUTES:raise ValueError('Packet operation or route is invalid')
 for key in ('packet_id','project_id','goal','technical_task_markdown','owner_summary_ru','created_at_utc','expires_at_utc'):
  if not isinstance(packet[key],str) or not packet[key]:raise ValueError(f'Packet {key} must be a nonempty string')
 if not re.fullmatch(r'[A-Za-z0-9._-]{8,128}',packet['packet_id']):raise ValueError('Packet ID is empty or unsafe')
 if not packet['technical_task_markdown'].strip():raise ValueError('Technical task is required')
 for key in ('project_root_hint','work_item_id','owner_goal_sha256'):
  if key in packet and packet[key] is not None and not isinstance(packet[key],str):raise ValueError(f'Packet {key} must be a string or null')
 if packet.get('owner_goal_sha256') is not None and not re.fullmatch('[0-9a-f]{64}',packet['owner_goal_sha256']):raise ValueError('Invalid owner-goal fingerprint')
 if 'goal_epoch' in packet and packet['goal_epoch'] is not None and not is_safe_integer(packet['goal_epoch']):raise ValueError('Goal epoch must be a positive interoperable integer')
 if packet['operation']=='continue_work_item' and (not packet.get('work_item_id') or not is_safe_integer(packet.get('goal_epoch'))):raise ValueError('Continuation packet lacks exact work-item identity')
 if packet['assurance_mode'] not in ('flow','guarded','release'):raise ValueError('Invalid assurance mode')
 if packet['scope_binding'] not in ('executor_discovery','exact'):raise ValueError('Invalid scope binding')
 if 'stage_profile' in packet and packet['stage_profile'] not in ('general','protocol_freeze','analytical_validation','empirical_validation'):raise ValueError('Invalid stage profile')
 for key in ('acceptance','non_goals','risk_hints'):
  if key in packet and (not isinstance(packet[key],list) or any(not isinstance(x,str) for x in packet[key])):raise ValueError(f'Packet {key} must be an array of strings')
 if 'audit_dimensions' in packet and type(packet['audit_dimensions']) is not dict:raise ValueError('Audit dimensions must be an object')
 if require_capability:
  if not isinstance(packet.get('capability_token'),str) or not re.fullmatch('[0-9a-f]{64}',packet['capability_token']):raise ValueError('Local capability is required')
 elif not allow_capability and 'capability_token' in packet:raise ValueError('External capability is forbidden')
 validate_summary(packet['owner_summary_ru'])
 created=parse_utc(packet['created_at_utc']);expires=parse_utc(packet['expires_at_utc']);now=now_utc or dt.datetime.now(dt.timezone.utc)
 if expires<=created or now>expires or created>now+dt.timedelta(minutes=5):raise ValueError('Packet time window is invalid or expired')
 return packet

def safe_member(name:str)->bool:
 n=name.replace('\\','/');parts=n.split('/')
 return bool(n) and not n.startswith('/') and all(p not in ('','.', '..') and ':' not in p and not p.endswith((' ','.')) for p in parts)

def load_packet(source:Path,*,source_bytes:bytes|None=None)->dict[str,Any]:
 if source_bytes is None:
  if source.stat().st_size>100_000_000:raise ValueError('Action packet exceeds byte limit')
  source_bytes=source.read_bytes()
 if len(source_bytes)>100_000_000:raise ValueError('Action packet exceeds byte limit')
 if source.suffix.lower()=='.json':return validate_packet(json.loads(source_bytes.decode('utf-8-sig')))
 if source.suffix.lower()!='.zip':raise ValueError('Only .json and legacy .zip packets are supported')
 with zipfile.ZipFile(io.BytesIO(source_bytes),'r') as archive:
  members=archive.infolist();names=[m.filename for m in members]
  if not names or len(members)>5000 or sum(m.file_size for m in members)>100_000_000:raise ValueError('Legacy ZIP limits exceeded')
  normalized=[name.replace('\\','/').rstrip('/').casefold() for name in names]
  if len(normalized)!=len(set(normalized)):raise ValueError('Legacy ZIP has colliding paths')
  for member in members:
   mode=member.external_attr >> 16
   checked_name=member.filename[:-1] if member.is_dir() else member.filename
   allowed_types=(0,stat.S_IFDIR) if member.is_dir() else (0,stat.S_IFREG)
   if not safe_member(checked_name) or member.flag_bits&1 or stat.S_IFMT(mode) not in allowed_types:raise ValueError('Legacy ZIP contains an unsafe or special member')
  if 'ACTION_PACKET.json' not in names:raise ValueError('Legacy ZIP packet is missing')
  packet=json.loads(archive.read('ACTION_PACKET.json').decode('utf-8-sig'))
  if type(packet) is not dict:raise ValueError('Legacy packet must be an object')
  # Only materialize missing presentation fields. Versions, route and authority never change.
  for key,member in [('technical_task_markdown','AGENT_TASK.md'),('owner_summary_ru','OWNER_SUMMARY_RU.md')]:
   if key not in packet and member in names:packet[key]=archive.read(member).decode('utf-8-sig')
  return validate_packet(packet)

def resolve_registration(registry_path:Path,project_id:str):
 registry=load_json(registry_path)
 if registry.get('schema_version')!=SCHEMA_VERSION or registry.get('ecosystem_version')!=ECOSYSTEM_VERSION:raise ValueError('Project registry ecosystem version is stale')
 for item in registry.get('projects',[]):
  aliases = [str(a).lower() for a in item.get('aliases', [])]
  if item.get('project_id')==project_id or str(project_id).lower() in aliases:
   root=Path(os.path.expandvars(os.path.expanduser(str(item.get('project_root',''))))).resolve();token=str(item.get('capability_token',''))
   if not root.is_dir() or not (root/'.agy').is_dir() or not (root/'.agents').is_dir():raise ValueError(f'Registered root is invalid: {root}')
   if not re.fullmatch(r'[0-9a-f]{64}',token):raise ValueError('Registered capability is missing')
   if item.get('ecosystem_version')!=ECOSYSTEM_VERSION:raise ValueError('Registered project version is stale')
   capability_path=root/'.agy'/'ACTION_BRIDGE_CAPABILITY.json'
   capability=load_json(capability_path) if capability_path.is_file() else {}
   canonical_id = item.get('project_id')
   if (capability.get('project_id')!=canonical_id and capability.get('project_id')!=project_id) or not hmac.compare_digest(str(capability.get('capability_token','')),token):raise ValueError('Local capability and project registry do not agree')
   manifest_path=root/'.agy'/'INSTALLATION_MANIFEST.json'
   if not manifest_path.is_file():raise ValueError('Installed runtime manifest is missing')
   manifest=load_json(manifest_path)
   if manifest.get('package_version')!=ECOSYSTEM_VERSION or manifest.get('runtime_version')!=ECOSYSTEM_VERSION:raise ValueError('Installed project runtime version is stale')
   return root,token
 raise ValueError(f'Unknown project_id: {project_id}')

def are_goals_compatible(g1:str,g2:str,threshold:float=0.7)->bool:
 # Compatibility name retained for callers; fuzzy comparison cannot preserve authorization.
 return isinstance(g1,str) and isinstance(g2,str) and g1==g2

def validate_current_identity(packet:dict[str,Any],root:Path):
 hint=packet.get('project_root_hint')
 if hint and Path(os.path.expandvars(os.path.expanduser(hint))).resolve()!=root:raise ValueError('Packet project root hint does not match the registered project')
 if packet.get('operation')!='continue_work_item':return
 work_path=root/'.agy'/'WORK_ITEM.json'
 if not work_path.is_file():raise ValueError('Continuation packet requires an active work item')
 work=load_json(work_path)
 if not is_safe_integer(work.get('goal_epoch')) or not is_safe_integer(packet.get('goal_epoch')) or work.get('work_item_id')!=packet.get('work_item_id') or work.get('goal_epoch')!=packet.get('goal_epoch'):raise ValueError('Continuation packet identity is stale')
 if not are_goals_compatible(packet.get('goal'),work.get('goal')):raise ValueError('Continuation packet attempts to change the immutable owner goal')
 expected=packet.get('owner_goal_sha256')
 if expected is not None and not hmac.compare_digest(expected,hashlib.sha256(work['goal'].encode('utf-8')).hexdigest()):raise ValueError('Continuation owner-goal fingerprint is stale')

def processed_ids(path:Path,project_id:str|None=None)->set[str]:
 if not path.is_file():return set()
 out=set()
 for line in path.read_text(encoding='utf-8').splitlines():
  try:
   v=json.loads(line)
   if v.get('packet_id') and (project_id is None or v.get('project_id') in (None,project_id)):out.add(str(v['packet_id']))
  except json.JSONDecodeError:pass
 return out

def canonical_markdown(value:Any)->str:
 return str(value).replace('\r\n','\n').replace('\r','\n').rstrip()+'\n'

def materialize(packet:dict[str,Any],root:Path):
 root.mkdir(parents=True,exist_ok=True)
 materialized=dict(packet);materialized['technical_task_markdown']=canonical_markdown(packet['technical_task_markdown']);materialized['owner_summary_ru']=canonical_markdown(packet['owner_summary_ru'])
 atomic_json(root/'ACTION_PACKET.json',materialized)
 (root/'AGENT_TASK.md').write_bytes(materialized['technical_task_markdown'].encode('utf-8'))
 (root/'OWNER_SUMMARY_RU.md').write_bytes(materialized['owner_summary_ru'].encode('utf-8'))
 files=[]
 for name in ['ACTION_PACKET.json','AGENT_TASK.md','OWNER_SUMMARY_RU.md']:
  p=root/name;files.append({'path':name,'size_bytes':p.stat().st_size,'sha256':sha256_file(p)})
 atomic_json(root/'MANIFEST.json',{'schema_version':SCHEMA_VERSION,'ecosystem_version':ECOSYSTEM_VERSION,'files':files})

def safe_rmtree(path:Path,retries:int=5,delay:float=0.1):
 if not path.exists():return
 for i in range(retries):
  try:
   shutil.rmtree(path)
   return
  except OSError:
   if i==retries-1:raise
   time.sleep(delay)

def packet_payload_sha256(packet):
 external={k:v for k,v in packet.items() if k!='capability_token'}
 return hashlib.sha256(json.dumps(external,sort_keys=True,ensure_ascii=False,separators=(',',':'),allow_nan=False).encode('utf-8')).hexdigest()

def packet_receipt_path(root:Path,packet_id:str)->Path:
 key=hashlib.sha256(packet_id.encode('utf-8')).hexdigest()
 return root/'.agy'/'action-bridge'/'receipts'/f'{key}.json'

@contextlib.contextmanager
def project_transaction_lock(root:Path,timeout_seconds:float=5.0):
 # OS advisory lock releases on process death. All mutating adapters must use it.
 lock=root/'.agy'/'action-bridge'/'.transaction.lock';lock.parent.mkdir(parents=True,exist_ok=True)
 handle=lock.open('a+b');handle.seek(0,2)
 if handle.tell()==0:handle.write(b'0');handle.flush()
 deadline=time.monotonic()+timeout_seconds;locked=False
 try:
  while not locked:
   try:
    handle.seek(0)
    if os.name=='nt':
     import msvcrt
     msvcrt.locking(handle.fileno(),msvcrt.LK_NBLCK,1)
    else:
     import fcntl
     fcntl.flock(handle.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
    locked=True
   except (OSError,IOError):
    if time.monotonic()>=deadline:raise TimeoutError('Project import transaction is busy; retry without changing the packet')
    time.sleep(0.025)
  yield
 finally:
  if locked:
   handle.seek(0)
   if os.name=='nt':
    import msvcrt
    msvcrt.locking(handle.fileno(),msvcrt.LK_UNLCK,1)
   else:
    import fcntl
    fcntl.flock(handle.fileno(),fcntl.LOCK_UN)
  handle.close()

def verify_generation(directory:Path,manifest_sha256:str,packet_id:str)->bool:
 try:
  manifest=directory/'MANIFEST.json'
  if sha256_file(manifest)!=manifest_sha256:return False
  data=load_json(manifest)
  if {item['path'] for item in data['files']}!={'ACTION_PACKET.json','AGENT_TASK.md','OWNER_SUMMARY_RU.md'}:return False
  for item in data['files']:
   member=directory/item['path']
   if member.is_symlink() or member.stat().st_size!=item['size_bytes'] or sha256_file(member)!=item['sha256']:return False
  return load_json(directory/'ACTION_PACKET.json').get('packet_id')==packet_id
 except (OSError,ValueError,KeyError,TypeError):return False

def redact_historical_packet(directory:Path):
 packet_file=directory/'ACTION_PACKET.json'
 if packet_file.is_file():
  packet=load_json(packet_file)
  if 'capability_token' in packet:
   redacted=dict(packet);redacted.pop('capability_token');materialize(redacted,directory)

def recover_import_transaction(root:Path):
 control=root/'.agy'/'action-bridge';journal_path=control/'IMPORT_TRANSACTION.json'
 if not journal_path.is_file():return
 journal=load_json(journal_path);txid=journal.get('transaction_id','')
 if not re.fullmatch('[0-9a-f]{32}',txid):raise ValueError('Import recovery journal is invalid')
 receipt=journal['receipt'];inbox=root/'.agy'/'inbox';active=inbox/'ACTIVE_ACTION_PACKET'
 history=inbox/'history'/txid;staged=inbox/f'.incoming-{txid}'
 target=packet_receipt_path(root,receipt['packet_id'])
 if verify_generation(active,receipt['active_manifest_sha256'],receipt['packet_id']):
  # The complete generation was published; interrupted receipt writes can now complete.
  receipt=dict(receipt,status='imported')
  atomic_json(target,receipt);atomic_json(root/'.agy'/'ACTION_PACKET_RECEIPT.json',receipt)
  redact_historical_packet(history)
 else:
  if history.exists():
   if active.exists():raise ValueError('Import recovery found an unrelated active generation; manual reconciliation required')
   os.replace(history,active)
  previous=journal.get('previous_receipt')
  if previous is not None:atomic_json(root/'.agy'/'ACTION_PACKET_RECEIPT.json',previous)
  elif (root/'.agy'/'ACTION_PACKET_RECEIPT.json').exists():(root/'.agy'/'ACTION_PACKET_RECEIPT.json').unlink()
  atomic_json(target,dict(receipt,status='import_failed'))
 safe_rmtree(staged);journal_path.unlink()

def acknowledge_packet(root:Path,packet_id:str,payload_sha256:str,phase:str,succeeded:bool):
 with project_transaction_lock(root):
  return _acknowledge_packet_locked(root,packet_id,payload_sha256,phase,succeeded)

def _acknowledge_packet_locked(root:Path,packet_id:str,payload_sha256:str,phase:str,succeeded:bool):
 # Internal seam: caller must hold project_transaction_lock for observed effects.
 if phase not in ('activation','injection') or type(succeeded) is not bool:raise ValueError('Invalid acknowledgment phase or result')
 recover_import_transaction(root)
 receipt_path=packet_receipt_path(root,packet_id)
 if not receipt_path.is_file():raise ValueError('Acknowledgment has no matching packet receipt')
 receipt=load_json(receipt_path)
 if receipt.get('packet_id')!=packet_id or receipt.get('packet_payload_sha256')!=payload_sha256:raise ValueError('Acknowledgment packet identity or digest mismatch')
 status=receipt.get('status')
 if status in ('publishing','import_failed'):raise ValueError('Cannot acknowledge an incomplete import')
 timestamp='activated_at_utc' if phase=='activation' else 'injected_at_utc'
 success_status='activated' if phase=='activation' else 'injected'
 if receipt.get(timestamp):
  if succeeded:return receipt
  raise ValueError('Late failed acknowledgment cannot revoke a successful effect')
 if phase=='injection' and not receipt.get('activated_at_utc'):raise ValueError('Injection acknowledgment requires confirmed activation')
 receipt=dict(receipt,status=success_status if succeeded else phase+'_failed')
 if succeeded:receipt[timestamp]=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
 atomic_json(receipt_path,receipt)
 current=root/'.agy'/'ACTION_PACKET_RECEIPT.json'
 active_receipt=load_json(current) if current.is_file() else {}
 if active_receipt.get('packet_id')==packet_id and active_receipt.get('packet_payload_sha256')==payload_sha256:atomic_json(current,receipt)
 return receipt

def import_packet(source:Path,registry_path:Path,state_root:Path):
 start_ns=time.time_ns();source=source.resolve()
 if source.stat().st_size>100_000_000:raise ValueError('Action packet exceeds byte limit')
 source_bytes=source.read_bytes();source_sha=hashlib.sha256(source_bytes).hexdigest();packet=load_packet(source,source_bytes=source_bytes)
 project_root,registered_token=resolve_registration(registry_path,packet['project_id'])
 if sha256_file(source)!=source_sha:raise ValueError('Source packet changed during import')
 digest=packet_payload_sha256(packet);packet_id=packet['packet_id'];receipt_path=packet_receipt_path(project_root,packet_id)
 with project_transaction_lock(project_root):
  recover_import_transaction(project_root)
  if receipt_path.is_file():
   previous_packet_receipt=load_json(receipt_path)
   if previous_packet_receipt.get('packet_payload_sha256')!=digest:raise ValueError('Packet ID collision: payload digest differs')
   if previous_packet_receipt.get('status') in ('imported','activated','injected','activation_failed','injection_failed'):
    return {'status':'PASS','completion_scope':'import_only','replayed':True,'project_root':str(project_root),'packet_id':packet_id,'packet_payload_sha256':digest,'receipt_status':previous_packet_receipt['status']}
  elif packet_id in processed_ids(state_root/'accepted_packets.ndjson',project_id=packet['project_id']):
   # Historical ledger lacks immutable payload binding. Do not reactivate it speculatively.
   raise ValueError('Legacy replay requires receipt reconciliation; payload identity is unproven')
  validate_current_identity(packet,project_root)
  if sha256_file(source)!=source_sha:raise ValueError('Source packet changed before publication')
  inbox=project_root/'.agy'/'inbox';active=inbox/'ACTIVE_ACTION_PACKET';txid=os.urandom(16).hex()
  staged=inbox/f'.incoming-{txid}';history=inbox/'history'/txid
  generation=inbox/'generations'/f'{hashlib.sha256(packet_id.encode()).hexdigest()}-{digest}'
  local_packet=dict(packet,capability_token=registered_token)
  if generation.exists():
   # Immutable generations contain only the external packet, never local capabilities.
   check=inbox/f'.verify-{txid}';materialize(packet,check)
   expected_manifest=sha256_file(check/'MANIFEST.json');safe_rmtree(check)
   if not verify_generation(generation,expected_manifest,packet_id):raise ValueError('Immutable generation collision')
  else:
   materialize(packet,staged);generation.parent.mkdir(parents=True,exist_ok=True);os.replace(staged,generation)
  manifest_sha=sha256_file(generation/'MANIFEST.json')
  if not verify_generation(generation,manifest_sha,packet_id):raise ValueError('Generation verification failed')
  materialize(local_packet,staged);active_manifest_sha=sha256_file(staged/'MANIFEST.json')
  receipt={'schema_version':SCHEMA_VERSION,'ecosystem_version':ECOSYSTEM_VERSION,'packet_id':packet_id,'project_id':packet['project_id'],'operation':packet['operation'],'route':packet['route'],'status':'publishing','completion_scope':'import_only','packet_payload_sha256':digest,'generation_manifest_sha256':manifest_sha,'active_manifest_sha256':active_manifest_sha,'source_file':str(source),'source_sha256':source_sha,'imported_at_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'activated_at_utc':None,'injected_at_utc':None}
  current=project_root/'.agy'/'ACTION_PACKET_RECEIPT.json';previous=load_json(current) if current.is_file() else None
  journal_path=project_root/'.agy'/'action-bridge'/'IMPORT_TRANSACTION.json'
  atomic_json(journal_path,{'transaction_id':txid,'receipt':receipt,'previous_receipt':previous})
  try:
   atomic_json(receipt_path,receipt);atomic_json(current,receipt)
   if active.exists():history.parent.mkdir(parents=True,exist_ok=True);os.replace(active,history)
   os.replace(staged,active)
   if not verify_generation(active,active_manifest_sha,packet_id):raise ValueError('Published generation verification failed')
   receipt=dict(receipt,status='imported');atomic_json(receipt_path,receipt);atomic_json(current,receipt)
   redact_historical_packet(history)
   journal_path.unlink()
  except Exception:
   # A partial write never becomes PASS. Recovery is durable if this process itself dies.
   recover_import_transaction(project_root)
   raise
  # The per-packet receipt is authoritative. The old aggregate ledger is an audit projection.
  try:append_jsonl(state_root/'accepted_packets.ndjson',{'packet_id':packet_id,'project_id':packet['project_id'],'accepted_at_utc':receipt['imported_at_utc'],'source_sha256':source_sha,'packet_payload_sha256':digest})
  except OSError:pass
 cmd_route = packet.get('route') or '/nextphase'
 cmd_to_run = f"{cmd_route} /goal"
 set_windows_clipboard_command(cmd_to_run)
 record_metric(project_root,'action_packet_import',(time.time_ns()-start_ns)/1_000_000,True)
 return {'status':'PASS','completion_scope':'import_only','replayed':False,'project_root':str(project_root),'packet_id':packet_id,'packet_payload_sha256':digest,'receipt_status':'imported'}

def is_candidate_ready(path:Path,debounce_seconds:float=0.1)->bool:
 try:
  size1=path.stat().st_size
  mtime1=path.stat().st_mtime_ns
  if debounce_seconds>0:
   time.sleep(debounce_seconds)
   stat2=path.stat()
   if stat2.st_size!=size1 or stat2.st_mtime_ns!=mtime1:
    return False
  with path.open('rb') as f:
   f.read(min(1024,max(1,size1)))
  return True
 except (OSError,PermissionError):
  return False

def scan(inbox:Path,registry:Path,state_root:Path,debounce_seconds:float=0.1)->int:
 processed=state_root/'processed';failed=state_root/'failed';processed.mkdir(parents=True,exist_ok=True);failed.mkdir(parents=True,exist_ok=True);failures=0
 packets=sorted(list(inbox.glob('AGENTIC_ACTION_PACKET_*.json'))+list(inbox.glob('AGENTIC_ACTION_PACKET_*.zip')),key=lambda p:p.stat().st_mtime_ns)
 for source in packets:
  if not is_candidate_ready(source,debounce_seconds):continue
  try:
   result=import_packet(source,registry,state_root);target=processed/source.name
   if target.exists():target=processed/f'{source.stem}-{time.time_ns()}{source.suffix}'
   shutil.move(str(source),str(target));atomic_json(target.with_suffix(target.suffix+'.result.json'),result)
  except Exception as e:
   failures+=1;target=failed/source.name
   if target.exists():target=failed/f'{source.stem}-{time.time_ns()}{source.suffix}'
   shutil.move(str(source),str(target));target.with_suffix(target.suffix+'.error.txt').write_text(str(e),encoding='utf-8')
 return failures

def acquire_singleton_lock(state_root:Path):
 lock_file=state_root/'.bridge_watch.lock'
 lock_file.parent.mkdir(parents=True,exist_ok=True)
 try:
  f=open(lock_file,'a+')
  import msvcrt
  msvcrt.locking(f.fileno(),msvcrt.LK_NBLCK,1)
  return f
 except (OSError,IOError,ImportError):
  try:f.close()
  except Exception:pass
  return None

def watch(inbox:Path,registry:Path,state_root:Path,poll_interval:float=0.5,debounce_seconds:float=0.1,max_iterations:int|None=None)->int:
 lock_handle=acquire_singleton_lock(state_root)
 if lock_handle is None:
  print("Another Action Bridge watcher is already active. Exiting.")
  return 0
 iterations=0
 try:
  while True:
   iterations+=1
   try:
    scan(inbox,registry,state_root,debounce_seconds=debounce_seconds)
   except Exception as e:
    try:
     log_file=state_root/'logs'/'watcher_error.log'
     log_file.parent.mkdir(parents=True,exist_ok=True)
     with log_file.open('a',encoding='utf-8') as f:f.write(f'[{dt.datetime.now(dt.timezone.utc).isoformat()}] Watcher error: {e}\n')
    except Exception:pass
   if max_iterations is not None and iterations>=max_iterations:
    break
   time.sleep(poll_interval)
 finally:
  try:
   import msvcrt
   msvcrt.locking(lock_handle.fileno(),msvcrt.LK_UNLCK,1)
   lock_handle.close()
  except Exception:pass
 return 0

def default_inbox()->Path:return Path(os.path.expanduser('~/Downloads')).resolve()
def default_registry()->Path:return Path(os.path.expanduser('~/.agentic-pipeline/project-registry.json')).resolve()
def default_state_root()->Path:return Path(os.path.expanduser('~/.agentic-pipeline/action-bridge')).resolve()

def main():
 configure_utf8_standard_streams()
 p=argparse.ArgumentParser();sub=p.add_subparsers(dest='command',required=True)
 i=sub.add_parser('import');i.add_argument('--packet',type=Path,required=True);i.add_argument('--registry',type=Path,default=default_registry());i.add_argument('--state-root',type=Path,default=default_state_root())
 s=sub.add_parser('scan');s.add_argument('--inbox',type=Path,default=default_inbox());s.add_argument('--registry',type=Path,default=default_registry());s.add_argument('--state-root',type=Path,default=default_state_root());s.add_argument('--debounce-seconds',type=float,default=0.1)
 w=sub.add_parser('watch');w.add_argument('--inbox',type=Path,default=default_inbox());w.add_argument('--registry',type=Path,default=default_registry());w.add_argument('--state-root',type=Path,default=default_state_root());w.add_argument('--poll-interval',type=float,default=0.5);w.add_argument('--debounce-seconds',type=float,default=0.1);w.add_argument('--max-iterations',type=int,default=None)
 a=p.parse_args()
 if a.command=='import':print(json.dumps(import_packet(a.packet,a.registry,a.state_root),ensure_ascii=False));return 0
 if a.command=='watch':return watch(a.inbox,a.registry,a.state_root,poll_interval=a.poll_interval,debounce_seconds=a.debounce_seconds,max_iterations=a.max_iterations)
 return 1 if scan(a.inbox,a.registry,a.state_root,debounce_seconds=a.debounce_seconds) else 0

if __name__=='__main__':raise SystemExit(main())
