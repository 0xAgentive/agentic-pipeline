#!/usr/bin/env python3
"""Read-only migration plan, or explicit quiesced exact-input cutover to a new DB."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from pipeline_runtime_state import import_legacy
from recovery_coordinator import Rejected, validate_state


def digest(data):return hashlib.sha256(data).hexdigest()


def _read_regular(path):
    path=Path(path)
    if path.is_symlink() or not path.is_file():raise Rejected('REGULAR_INPUT_REQUIRED')
    with path.open('rb') as handle:
        before=os.fstat(handle.fileno());data=handle.read();after=os.fstat(handle.fileno())
    current=path.stat()
    if (before.st_ino,before.st_mtime_ns,before.st_size)!=(after.st_ino,after.st_mtime_ns,after.st_size) or (after.st_ino,after.st_mtime_ns,after.st_size)!=(current.st_ino,current.st_mtime_ns,current.st_size):raise Rejected('INPUT_CHANGED_DURING_READ')
    return data


def initialize(legacy_state,seen_packets,database,*,apply=False,expected_state_sha256=None,expected_seen_sha256=None,writers_quiesced=False):
    state_path=Path(legacy_state);seen_path=Path(seen_packets);database=Path(database)
    if str(database).startswith(('\\\\','//')):raise Rejected('LOCAL_DATABASE_REQUIRED')
    if any(Path(str(database)+suffix).exists() for suffix in ('','-wal','-shm','-journal')) or database.is_symlink():raise Rejected('DATABASE_MUST_BE_ABSENT')
    state_bytes=_read_regular(state_path);seen_bytes=_read_regular(seen_path)
    state=json.loads(state_bytes.decode('utf-8-sig'));seen=json.loads(seen_bytes.decode('utf-8-sig'))
    validate_state(state,legacy=True)
    if not isinstance(seen,dict):raise Rejected('INVALID_SEEN_PACKETS')
    if any(isinstance(record,dict) and record.get('turnState')=='PAUSED_BY_OWNER' for record in seen.values()):raise Rejected('PAUSED_BY_OWNER_REQUIRES_RECEIPT_PHASE_RECONCILIATION')
    state_sha=digest(state_bytes);seen_sha=digest(seen_bytes)
    if expected_state_sha256 is not None and expected_state_sha256!=state_sha:raise Rejected('LEGACY_STATE_HASH_MISMATCH')
    if expected_seen_sha256 is not None and expected_seen_sha256!=seen_sha:raise Rejected('SEEN_PACKETS_HASH_MISMATCH')
    summary={'schema_version':1,'status':'PLAN','database':str(database),'legacy_state_sha256':state_sha,'seen_packets_sha256':seen_sha,'preserved_global_pause':state['is_standby'],'preserved_mode':state['mode'],'preserved_project_pause_count':sum(v['is_paused'] for v in state.get('projects',{}).values()),'seen_record_count':len(seen),'effects_performed':False,'required_before_apply':['all legacy state writers already quiesced','exact hashes from this plan','database and SQLite sidecars still absent']}
    if not apply:return summary
    if writers_quiesced is not True:raise Rejected('QUIESCED_WRITERS_ASSERTION_REQUIRED')
    if expected_state_sha256 is None or expected_seen_sha256 is None:raise Rejected('EXACT_INPUT_HASHES_REQUIRED')
    # Re-read at cutover; explicit quiescence is an operational assertion, not inferred from PID.
    if digest(_read_regular(state_path))!=state_sha or digest(_read_regular(seen_path))!=seen_sha:raise Rejected('INPUT_CHANGED_BEFORE_CUTOVER')
    database.parent.mkdir(parents=True,exist_ok=True)
    descriptor=os.open(database,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    os.close(descriptor)
    try:
        imported=import_legacy(state,seen,database)
        from recovery_coordinator import Coordinator
        coordinator=Coordinator(database)
        with coordinator._transaction() as db:
            db.execute('CREATE TABLE v2_migration(id INTEGER PRIMARY KEY CHECK(id=1),data TEXT NOT NULL)')
            db.execute('INSERT INTO v2_migration VALUES(1,?)',(json.dumps({'legacy_state_sha256':state_sha,'seen_packets_sha256':seen_sha,'writers_quiesced_asserted':True}),))
    except BaseException:
        # Preserve an incomplete created DB for inspection; never replace/reinitialize it.
        raise Rejected('CUTOVER_FAILED_NEW_DATABASE_RETAINED')
    summary.update(status='INITIALIZED',effects_performed=True,epoch=imported['epoch'],completion_scope='state_migration_only')
    return summary


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--legacy-state',type=Path,required=True);parser.add_argument('--seen-packets',type=Path,required=True);parser.add_argument('--database',type=Path,required=True)
    parser.add_argument('--apply',action='store_true');parser.add_argument('--writers-quiesced',action='store_true');parser.add_argument('--expected-state-sha256');parser.add_argument('--expected-seen-sha256');args=parser.parse_args()
    try:
        result=initialize(args.legacy_state,args.seen_packets,args.database,apply=args.apply,expected_state_sha256=args.expected_state_sha256,expected_seen_sha256=args.expected_seen_sha256,writers_quiesced=args.writers_quiesced)
        print(json.dumps(result,ensure_ascii=False));return 0
    except Exception as error:
        print(json.dumps({'status':'HOLD','reason':str(error) if isinstance(error,Rejected) else type(error).__name__,'completion_scope':'state_migration_only'}));return 2


if __name__=='__main__':raise SystemExit(main())
