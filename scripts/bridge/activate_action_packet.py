#!/usr/bin/env python3
"""Serialized activation adapter; no IDE injection and no product-ready claim."""
from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import uuid
from effect_owner import EffectOwner
from pipeline_runtime_state import database_path
from native_recovery import admit_work


def pause_snapshot(path=None,*,recovery_db=None,standalone=False):
    """Read the authoritative pause source; an unreadable source never grants permission.

    Standalone is an explicit noncyclic, pre-enrollment mode. It cannot override an
    enrolled coordinator or an explicitly supplied legacy pause source.
    """
    configured=os.environ.get('AGENTIC_RECOVERY_DB')
    if configured is not None and not configured.strip():
        raise ValueError('Activation HOLD: AGENTIC_RECOVERY_DB is empty')
    if recovery_db is not None and configured is not None and Path(recovery_db).resolve()!=Path(configured).resolve():
        raise ValueError('Activation HOLD: conflicting recovery database configuration')
    database=Path(recovery_db) if recovery_db is not None else (Path(configured) if configured is not None else None)
    default_database=database_path()
    if database is None and default_database.exists():database=default_database
    if standalone:
        if database is not None or path is not None:
            raise ValueError('Activation HOLD: standalone cannot override a configured pause source')
        return {'is_standby':False,'mode':'NORMAL','projects':{}}
    if database is None and path is None:
        raise ValueError('Activation HOLD: configure recovery database, explicit legacy state, or noncyclic standalone mode')
    validator_path=Path(__file__).with_name('recovery_coordinator.py')
    try:
        spec=importlib.util.spec_from_file_location('activation_recovery_validator',validator_path)
        validator=importlib.util.module_from_spec(spec);spec.loader.exec_module(validator)
        if database is not None:
            if not database.is_file():raise ValueError('Configured recovery database is missing')
            with sqlite3.connect(database.resolve().as_uri()+'?mode=ro',uri=True,timeout=2) as db:
                db.execute('PRAGMA query_only=ON')
                row=db.execute('SELECT data FROM state WHERE id=1').fetchone()
            if row is None:raise ValueError('Recovery database has no state')
            state=validator.validate_state(json.loads(row[0]))
        else:
            state=validator.validate_state(json.loads(Path(path).read_text(encoding='utf-8-sig')),legacy=True)
    except Exception as error:
        raise ValueError('Activation HOLD: pause state missing, malformed, or unreadable') from error
    return state


def check_pause(path,packet,project_key,*,recovery_db=None,standalone=False):
    state=pause_snapshot(path,recovery_db=recovery_db,standalone=standalone)
    if state['is_standby']:raise ValueError('Activation held by global owner/recovery pause')
    projects=state.get('projects',{})
    key=project_key or packet['project_id']
    if projects.get(key,{}).get('is_paused'):raise ValueError('Activation held by project owner pause')
    if not project_key and key not in projects and any(p.get('is_paused') for p in projects.values()):
        raise ValueError('Provide exact project-key before activation while any project pause is active')


def run_child(command,timeout):
    options={'stdout':subprocess.PIPE,'stderr':subprocess.PIPE,'stdin':subprocess.DEVNULL}
    if os.name=='nt':options['creationflags']=subprocess.CREATE_NEW_PROCESS_GROUP|subprocess.CREATE_NO_WINDOW
    else:options['start_new_session']=True
    child=subprocess.Popen(command,**options)
    try:
        stdout,stderr=child.communicate(timeout=timeout)
        return child.returncode,stdout,stderr
    except subprocess.TimeoutExpired:
        if os.name=='nt':
            subprocess.run(['taskkill','/F','/T','/PID',str(child.pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=5,creationflags=subprocess.CREATE_NO_WINDOW)
        else:
            try:os.killpg(child.pid,signal.SIGKILL)
            except ProcessLookupError:pass
        try:child.communicate(timeout=5)
        except subprocess.TimeoutExpired:child.kill()
        raise RuntimeError('Activation timed out; reconcile work-item files before any retry')


def activate(root,bridge,*,apply=False,packet_directory=None,project_key='',standby_path=None,recovery_db=None,standalone=False,command=None,timeout=120,fault_injection=0,expected_packet_id=None,expected_source_sha256=None,expected_epoch=None):
    root=Path(root).resolve();active=root/'.agy/inbox/ACTIVE_ACTION_PACKET'
    target=Path(packet_directory).resolve() if packet_directory else active
    if target!=active:raise ValueError('Activation must bind current imported generation; import alternate packets first')
    if not apply:
        receipt=bridge.load_json(root/'.agy/ACTION_PACKET_RECEIPT.json')
        return {'status':'PLAN','packet_id':receipt.get('packet_id'),'completion_scope':'activation_plan','effects_performed':False}
    with bridge.project_transaction_lock(root):
        bridge.recover_import_transaction(root)
        receipt=bridge.load_json(root/'.agy/ACTION_PACKET_RECEIPT.json');packet=bridge.load_json(active/'ACTION_PACKET.json')
        if expected_packet_id is not None and packet.get('packet_id')!=expected_packet_id:raise ValueError('EXPECTED_PACKET_ID_MISMATCH')
        if expected_source_sha256 is not None and receipt.get('source_sha256')!=expected_source_sha256:raise ValueError('EXPECTED_SOURCE_HASH_MISMATCH')
        bridge.validate_packet(packet,require_capability=True)
        if receipt.get('packet_id')!=packet['packet_id'] or receipt.get('status') not in ('imported','activated','injected','activation_failed'):
            raise ValueError('Activation requires matching imported receipt')
        if not bridge.verify_generation(active,receipt.get('active_manifest_sha256',''),packet['packet_id']):raise ValueError('Activation generation hash mismatch')
        capability=bridge.load_json(root/'.agy/ACTION_BRIDGE_CAPABILITY.json')
        if capability.get('project_id')!=packet['project_id'] or capability.get('capability_token')!=packet['capability_token']:raise ValueError('Activation capability identity mismatch')
        bridge.validate_current_identity(packet,root)
        check_pause(standby_path,packet,project_key,recovery_db=recovery_db,standalone=standalone)
        if receipt.get('activated_at_utc'):return {'status':'PASS','packet_id':packet['packet_id'],'completion_scope':'activation_only','replayed':True}
        if command is None:
            pwsh=shutil.which('pwsh')
            if not pwsh:raise RuntimeError('PowerShell 7 is required for actual activation')
            core=root/'scripts/windows/companion/Activate-ActionPacketCore.ps1'
            command=[pwsh,'-NoLogo','-NoProfile','-NonInteractive','-File',str(core),'-ProjectRoot',str(root),'-PacketDirectory',str(active),'-Apply']
            if fault_injection:command+=['-FaultInjectionAfterPublishes',str(fault_injection)]
        observed={'schema_version':'1.0.0','packet_id':packet['packet_id'],'packet_payload_sha256':receipt['packet_payload_sha256'],'at_utc':dt.datetime.now(dt.timezone.utc).isoformat(),'status':'running'}
        observation=root/'.agy/action-bridge/activation-observations'/f'{uuid.uuid4().hex}.json'
        bridge.atomic_json(observation,observed)
        try:
            effect_owner = None
            effect_lease = None
            if not standalone:
                db_path = recovery_db or database_path()
                effect_owner = EffectOwner(db_path)
                current_state = effect_owner.coordinator.snapshot()
                if expected_epoch is not None and current_state['epoch'] != expected_epoch:raise ValueError('STALE_EPOCH')
                effect_lease = effect_owner.acquire("activation", project_key or packet['project_id'], packet['packet_id'], current_state['epoch'], receipt['packet_payload_sha256'], 'activation', 'activation:' + packet['packet_id'], lease_seconds=min(timeout + 10, 300))
                effect_owner.begin_effect(effect_lease)
            code,out,err=run_child(command,timeout)
            observed.update(return_code=code,stdout_sha256=hashlib.sha256(out).hexdigest(),stderr_sha256=hashlib.sha256(err).hexdigest())
            if code!=0:raise RuntimeError(f'Activation process failed with exit code {code}')
            current=bridge.load_json(root/'.agy/ACTION_PACKET_RECEIPT.json')
            if current.get('packet_id')!=packet['packet_id'] or current.get('packet_payload_sha256')!=receipt['packet_payload_sha256']:raise ValueError('Receipt changed during activation; reconciliation required')
            if not bridge.verify_generation(active,receipt['active_manifest_sha256'],packet['packet_id']):raise ValueError('Active packet changed during activation')
            work=bridge.load_json(root/'.agy/WORK_ITEM.json');next_action=bridge.load_json(root/'.agy/NEXT_ACTION.json')
            if work.get('goal')!=packet['goal'] or work.get('owner_approved') is not True:raise ValueError('Observed work-item goal or approval mismatch')
            if packet['operation']=='new_work_item':
                if work.get('action_packet_id')!=packet['packet_id'] or not work.get('work_item_id'):raise ValueError('Observed activation belongs to another packet')
                if work.get('goal_epoch')!=(packet.get('goal_epoch') or 1):raise ValueError('Observed goal epoch mismatch')
            elif work.get('work_item_id')!=packet['work_item_id'] or work.get('goal_epoch')!=packet['goal_epoch']:raise ValueError('Observed continuation identity mismatch')
            if next_action.get('work_item_id')!=work['work_item_id'] or next_action.get('route')!=packet['route']:raise ValueError('Observed NEXT_ACTION mismatch')
            check_pause(standby_path,packet,project_key,recovery_db=recovery_db,standalone=standalone)
            if effect_owner is not None:
                effect_owner.ack(effect_lease, outcome='SUCCEEDED', receipt={'packet_id':packet['packet_id'],'observation':str(observation.relative_to(root))})
                admit_work(project_key or packet['project_id'], root, effect_lease['epoch'], database=db_path)
            observed.update(status='verified',work_item_id=work['work_item_id'],work_item_sha256=bridge.sha256_file(root/'.agy/WORK_ITEM.json'),next_action_sha256=bridge.sha256_file(root/'.agy/NEXT_ACTION.json'))
            bridge.atomic_json(observation,observed)
            bridge._acknowledge_packet_locked(root,packet['packet_id'],receipt['packet_payload_sha256'],'activation',True)
            return {'status':'PASS','packet_id':packet['packet_id'],'work_item_id':work['work_item_id'],'completion_scope':'activation_only','evidence_ref':str(observation.relative_to(root)),'replayed':False}
        except Exception as error:
            if 'effect_owner' in locals() and effect_owner is not None and effect_lease is not None:
                try: effect_owner.ack(effect_lease, outcome='UNCERTAIN')
                except Exception: pass  # Preserve durable DISPATCHED after stale epoch or lost ACK.
            observed.update(status='failed',error_type=type(error).__name__)
            bridge.atomic_json(observation,observed)
            bridge._acknowledge_packet_locked(root,packet['packet_id'],receipt['packet_payload_sha256'],'activation',False)
            raise


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-root',required=True,type=Path);parser.add_argument('--packet-directory',type=Path)
    parser.add_argument('--project-key',default='');parser.add_argument('--apply',action='store_true')
    parser.add_argument('--recovery-db',type=Path,help='Authoritative coordinator database; missing or invalid means HOLD')
    parser.add_argument('--standby-state',type=Path,help='Explicit pre-cutover legacy source; ignored after coordinator enrollment')
    parser.add_argument('--standalone',action='store_true',help='Explicit noncyclic, pre-enrollment activation; never overrides a pause source')
    parser.add_argument('--expected-packet-id');parser.add_argument('--expected-source-sha256');parser.add_argument('--expected-epoch',type=int)
    parser.add_argument('--fault-injection',type=int,choices=range(6),default=0)
    args=parser.parse_args()
    module_path=Path(__file__).with_name('companion_action_bridge.py')
    spec=importlib.util.spec_from_file_location('action_bridge',module_path);bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
    result=activate(args.project_root,bridge,apply=args.apply,packet_directory=args.packet_directory,project_key=args.project_key,standby_path=args.standby_state,recovery_db=args.recovery_db,standalone=args.standalone,fault_injection=args.fault_injection,expected_packet_id=args.expected_packet_id,expected_source_sha256=args.expected_source_sha256,expected_epoch=args.expected_epoch)
    print(json.dumps(result,ensure_ascii=False));return 0

if __name__=='__main__':raise SystemExit(main())
