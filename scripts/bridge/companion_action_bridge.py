#!/usr/bin/env python3
from __future__ import annotations
import argparse,datetime as dt,hashlib,hmac,json,os,re,shutil,sys,tempfile,time,zipfile
from pathlib import Path
from typing import Any

def configure_utf8_standard_streams():
 for stream,errors in ((sys.stdout,'strict'),(sys.stderr,'backslashreplace')):
  reconfigure=getattr(stream,'reconfigure',None)
  if callable(reconfigure):reconfigure(encoding='utf-8',errors=errors)

SCHEMA_VERSION='1.2.9'
ECOSYSTEM_VERSION='1.2.20'
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
def load_json(path:Path):return json.loads(path.read_text(encoding='utf-8-sig'))
def parse_utc(value):
 text=str(value or '');text=text[:-1]+'+00:00' if text.endswith('Z') else text;parsed=dt.datetime.fromisoformat(text)
 if parsed.tzinfo is None:raise ValueError('Packet timestamp must include a timezone')
 return parsed.astimezone(dt.timezone.utc)
def validate_summary(text:str):
 for h in HEADINGS:
  if h not in text:raise ValueError(f'Owner summary heading missing: {h}')
 if len(text)>2400 or '```' in text:raise ValueError('Owner summary is not compact plain-language output')
def validate_packet(packet:dict[str,Any])->dict[str,Any]:
 if packet.get('schema_version')!=SCHEMA_VERSION or packet.get('ecosystem_version')!=ECOSYSTEM_VERSION:raise ValueError('Unsupported ecosystem/action packet version')
 if packet.get('packet_format','single_json')!='single_json':raise ValueError('Unsupported packet format')
 if packet.get('owner_approved') is not True or packet.get('owner_interaction_policy')!='hard_stop_only':raise ValueError('Packet is not owner-approved')
 if packet.get('operation') not in VALID_OPERATIONS or packet.get('route') not in VALID_ROUTES:raise ValueError('Packet operation or route is invalid')
 if packet.get('operation')=='continue_work_item' and (not packet.get('work_item_id') or not isinstance(packet.get('goal_epoch'),int)):raise ValueError('Continuation packet lacks exact work-item identity')
 if not re.fullmatch(r'[A-Za-z0-9._-]{8,128}',str(packet.get('packet_id',''))):raise ValueError('Packet ID is empty or unsafe')
 if not packet.get('project_id') or not packet.get('goal') or not str(packet.get('technical_task_markdown','')).strip():raise ValueError('Project, goal and technical task are required')
 if 'capability_token' in packet:raise ValueError('External Action Packet must not contain a local capability')
 validate_summary(str(packet.get('owner_summary_ru','')))
 created=parse_utc(packet.get('created_at_utc'));expires=parse_utc(packet.get('expires_at_utc'));now=dt.datetime.now(dt.timezone.utc)
 if expires<=created or now>expires or created>now+dt.timedelta(minutes=5):raise ValueError('Packet time window is invalid or expired')
 return packet
def safe_member(name:str)->bool:
 n=name.replace('\\','/');parts=[p for p in n.split('/') if p not in ('','.')];return not n.startswith('/') and not (parts and ':' in parts[0]) and '..' not in parts
def load_packet(source:Path)->dict[str,Any]:
 if source.suffix.lower()=='.json':return validate_packet(load_json(source))
 if source.suffix.lower()!='.zip':raise ValueError('Only .json and legacy .zip packets are supported')
 with tempfile.TemporaryDirectory(prefix='agentic-action-legacy-') as t:
  root=Path(t)
  with zipfile.ZipFile(source,'r') as z:
   names=z.namelist()
   if not names or len(names)!=len(set(names)) or any(not safe_member(n) for n in names):raise ValueError('Legacy ZIP is unsafe')
   z.extractall(root)
  packet=load_json(root/'ACTION_PACKET.json')
  if 'technical_task_markdown' not in packet:packet['technical_task_markdown']=(root/'AGENT_TASK.md').read_text(encoding='utf-8')
  if 'owner_summary_ru' not in packet:packet['owner_summary_ru']=(root/'OWNER_SUMMARY_RU.md').read_text(encoding='utf-8')
  packet['schema_version']=SCHEMA_VERSION;packet['ecosystem_version']=ECOSYSTEM_VERSION;packet['packet_format']='single_json'
  return validate_packet(packet)
def resolve_registration(registry_path:Path,project_id:str):
 registry=load_json(registry_path)
 if registry.get('schema_version')!=SCHEMA_VERSION or registry.get('ecosystem_version')!=ECOSYSTEM_VERSION:raise ValueError('Project registry ecosystem version is stale')
 for item in registry.get('projects',[]):
  if item.get('project_id')==project_id:
   root=Path(os.path.expandvars(os.path.expanduser(str(item.get('project_root',''))))).resolve();token=str(item.get('capability_token',''))
   if not root.is_dir() or not (root/'.agy').is_dir() or not (root/'.agents').is_dir():raise ValueError(f'Registered root is invalid: {root}')
   if not re.fullmatch(r'[0-9a-f]{64}',token):raise ValueError('Registered capability is missing')
   if item.get('ecosystem_version')!=ECOSYSTEM_VERSION:raise ValueError('Registered project version is stale')
   capability_path=root/'.agy'/'ACTION_BRIDGE_CAPABILITY.json'
   capability=load_json(capability_path) if capability_path.is_file() else {}
   if capability.get('project_id')!=project_id or not hmac.compare_digest(str(capability.get('capability_token','')),token):raise ValueError('Local capability and project registry do not agree')
   manifest_path=root/'.agy'/'INSTALLATION_MANIFEST.json'
   if not manifest_path.is_file():raise ValueError('Installed runtime manifest is missing')
   manifest=load_json(manifest_path)
   if manifest.get('package_version')!=ECOSYSTEM_VERSION or manifest.get('runtime_version')!=ECOSYSTEM_VERSION:raise ValueError('Installed project runtime version is stale')
   return root,token
 raise ValueError(f'Unknown project_id: {project_id}')
def validate_current_identity(packet:dict[str,Any],root:Path):
 hint=packet.get('project_root_hint')
 if hint and Path(os.path.expandvars(os.path.expanduser(str(hint)))).resolve()!=root:raise ValueError('Packet project root hint does not match the registered project')
 if packet.get('operation')!='continue_work_item':return
 work_path=root/'.agy'/'WORK_ITEM.json'
 if not work_path.is_file():raise ValueError('Continuation packet requires an active work item')
 work=load_json(work_path)
 if str(work.get('work_item_id',''))!=str(packet.get('work_item_id','')) or work.get('goal_epoch')!=packet.get('goal_epoch'):raise ValueError('Continuation packet identity is stale')
 if str(work.get('goal',''))!=str(packet.get('goal','')):raise ValueError('Continuation packet attempts to change the immutable owner goal')
 expected=packet.get('owner_goal_sha256')
 if expected and not hmac.compare_digest(str(expected),hashlib.sha256(str(work.get('goal','')).encode('utf-8')).hexdigest()):raise ValueError('Continuation owner-goal fingerprint is stale')
def processed_ids(path:Path)->set[str]:
 if not path.is_file():return set()
 out=set()
 for line in path.read_text(encoding='utf-8').splitlines():
  try:
   v=json.loads(line)
   if v.get('packet_id'):out.add(str(v['packet_id']))
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
def import_packet(source:Path,registry_path:Path,state_root:Path):
 source=source.resolve();packet=load_packet(source);project_root,registered_token=resolve_registration(registry_path,str(packet['project_id']))
 validate_current_identity(packet,project_root)
 ledger=state_root/'accepted_packets.ndjson';packet_id=str(packet['packet_id'])
 if packet_id in processed_ids(ledger):raise ValueError(f'Action packet replay rejected: {packet_id}')
 inbox=project_root/'.agy'/'inbox';active=inbox/'ACTIVE_ACTION_PACKET';staged=inbox/f'.incoming-{packet_id}';history=inbox/'history'/time.strftime('%Y%m%d_%H%M%S')
 if staged.exists():shutil.rmtree(staged)
 local_packet=dict(packet);local_packet['capability_token']=registered_token
 materialize(local_packet,staged)
 if active.exists():
  history.parent.mkdir(parents=True,exist_ok=True)
  if history.exists():history=history.with_name(f'{history.name}-{time.time_ns()}')
  archived_packet=load_json(active/'ACTION_PACKET.json')
  os.replace(active,history)
  try:
   redacted_packet=dict(archived_packet);redacted_packet.pop('capability_token',None);materialize(redacted_packet,history)
   os.replace(staged,active)
  except Exception:
   if not active.exists() and history.exists():materialize(archived_packet,history);os.replace(history,active)
   raise
 else:os.replace(staged,active)
 receipt={'schema_version':SCHEMA_VERSION,'ecosystem_version':ECOSYSTEM_VERSION,'packet_id':packet_id,'project_id':packet['project_id'],'operation':packet['operation'],'route':packet['route'],'status':'imported','source_file':str(source),'source_sha256':sha256_file(source),'imported_at_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'activated_at_utc':None,'injected_at_utc':None}
 atomic_json(project_root/'.agy'/'ACTION_PACKET_RECEIPT.json',receipt);append_jsonl(ledger,{'packet_id':packet_id,'project_id':packet['project_id'],'accepted_at_utc':receipt['imported_at_utc'],'source_sha256':receipt['source_sha256']})
 return{'status':'PASS','project_root':str(project_root),'packet_id':packet_id}
def scan(inbox:Path,registry:Path,state_root:Path)->int:
 processed=state_root/'processed';failed=state_root/'failed';processed.mkdir(parents=True,exist_ok=True);failed.mkdir(parents=True,exist_ok=True);failures=0
 packets=sorted(list(inbox.glob('AGENTIC_ACTION_PACKET_*.json'))+list(inbox.glob('AGENTIC_ACTION_PACKET_*.zip')),key=lambda p:p.stat().st_mtime_ns)
 for source in packets:
  try:
   result=import_packet(source,registry,state_root);target=processed/source.name
   if target.exists():target=processed/f'{source.stem}-{time.time_ns()}{source.suffix}'
   shutil.move(str(source),str(target));atomic_json(target.with_suffix(target.suffix+'.result.json'),result)
  except Exception as e:
   failures+=1;target=failed/source.name
   if target.exists():target=failed/f'{source.stem}-{time.time_ns()}{source.suffix}'
   shutil.move(str(source),str(target));target.with_suffix(target.suffix+'.error.txt').write_text(str(e),encoding='utf-8')
 return failures
def main():
 configure_utf8_standard_streams()
 p=argparse.ArgumentParser();sub=p.add_subparsers(dest='command',required=True);i=sub.add_parser('import');i.add_argument('--packet',type=Path,required=True);i.add_argument('--registry',type=Path,required=True);i.add_argument('--state-root',type=Path,required=True);s=sub.add_parser('scan');s.add_argument('--inbox',type=Path,required=True);s.add_argument('--registry',type=Path,required=True);s.add_argument('--state-root',type=Path,required=True);a=p.parse_args()
 if a.command=='import':print(json.dumps(import_packet(a.packet,a.registry,a.state_root),ensure_ascii=False));return 0
 return 1 if scan(a.inbox,a.registry,a.state_root) else 0
if __name__=='__main__':raise SystemExit(main())
