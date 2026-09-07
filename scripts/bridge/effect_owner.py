"""Durable, shared final effect boundary. No process/network effects are performed here.

begin_effect linearizes dispatch relative to pause; it cannot cancel a previously
begun external action. Pause always commits promptly. Lost/stale ACKs require
receiver-bound reconciliation before another effect owner can proceed.
"""
import hashlib
import json
from pathlib import Path
import secrets
import sys
import time
from recovery_coordinator import Coordinator, Rejected, RETRYABLE, retry_delay

KINDS = {'send', 'context_send', 'activation', 'recovery', 'runtime', 'owner_command', 'owner_message'}
TERMINAL = {'completed', 'done', 'closed', 'cancelled', 'failed', 'blocked'}


class EffectOwner:
    def __init__(self, database):
        if not Path(database).is_file():
            raise Rejected('NOT_INITIALIZED')
        self.coordinator = Coordinator(database)
        self.coordinator.snapshot()
        with self.coordinator._transaction() as db:
            db.execute('CREATE TABLE IF NOT EXISTS v2_effects(project TEXT, operation_id TEXT, data TEXT NOT NULL, PRIMARY KEY(project,operation_id))')
            db.execute('CREATE TABLE IF NOT EXISTS v2_effect_lease(id INTEGER PRIMARY KEY CHECK(id=1), data TEXT NOT NULL)')

    @staticmethod
    def _validate(state, effect):
        if type(effect.get('epoch')) is not int or effect['epoch'] != state['epoch']:
            raise Rejected('STALE_EPOCH')
        if effect['effect_kind'] != 'owner_message':
            if effect['effect_kind'] == 'recovery':
                Coordinator._allowed(state, effect['project'])
            elif state['is_standby'] or state['projects'].get(effect['project'], {}).get('is_paused'):
                raise Rejected('PAUSED')
        if effect['effect_kind'] in {'send', 'recovery'}:
            binding = state.get('work_bindings', {}).get(effect['project'], {})
            if not binding or any(type(binding.get(k)) is not type(effect.get(k)) or binding.get(k) != effect.get(k) for k in ('work_item_id', 'goal_epoch')):
                raise Rejected('WORK_BINDING_MISMATCH')
            if binding.get('status') in TERMINAL or binding.get('owner_approved') is not True or binding.get('hard_stop') is not False:
                raise Rejected('WORK_NOT_ACTIVE')
            if binding.get('project_root'):
                from native_recovery import validate_live_binding
                validate_live_binding(binding)

    def acquire(self, owner, project, turn, epoch, context_hash, effect_kind, operation_id, work_item_id=None, goal_epoch=None, failure_kind=None, lease_seconds=30, now=None):
        now = time.time() if now is None else now
        for value in (owner, project, turn, operation_id):
            if not isinstance(value, str) or not value or len(value) > 256:
                raise Rejected('INVALID_EFFECT_IDENTITY')
        if effect_kind not in KINDS or not isinstance(context_hash, str) or len(context_hash) != 64 or any(c not in '0123456789abcdef' for c in context_hash):
            raise Rejected('INVALID_EFFECT_BINDING')
        if not isinstance(lease_seconds, (int, float)) or isinstance(lease_seconds, bool) or not 0 < lease_seconds <= 300:
            raise Rejected('INVALID_LEASE_DURATION')
        if effect_kind == 'recovery' and failure_kind not in RETRYABLE:
            raise Rejected('NON_RETRYABLE:' + str(failure_kind))
        item = dict(owner=owner, project=project, turn=turn, epoch=epoch, context_hash=context_hash, effect_kind=effect_kind, operation_id=operation_id, work_item_id=work_item_id, goal_epoch=goal_epoch, failure_kind=failure_kind)
        with self.coordinator._transaction() as db:
            state = self.coordinator._read(db)
            self._validate(state, item)
            # Legacy and v2 reservations share one exclusive effect boundary at cutover.
            legacy = db.execute('SELECT data FROM lease WHERE id=1').fetchone()
            if legacy and json.loads(legacy['data'])['expires_at'] > now:
                raise Rejected('LEGACY_EFFECT_OWNED')
            # An old v1 in-flight effect must be reconciled before v2 takeover.
            if db.execute("SELECT 1 FROM operations WHERE status IN ('DISPATCHED','UNCERTAIN')").fetchone():
                raise Rejected('LEGACY_RECONCILIATION_REQUIRED')
            if db.execute("SELECT 1 FROM v2_effects WHERE json_extract(data,'$.status') IN ('DISPATCHED','UNCERTAIN')").fetchone():
                raise Rejected('RECONCILIATION_REQUIRED')
            held = db.execute('SELECT data FROM v2_effect_lease WHERE id=1').fetchone()
            if held and json.loads(held['data'])['expires_at'] > now:
                raise Rejected('EFFECT_OWNED')
            row = db.execute('SELECT data FROM v2_effects WHERE project=? AND operation_id=?', (project, operation_id)).fetchone()
            attempt = 1
            if row:
                prior = json.loads(row['data'])
                identity = ('project', 'turn', 'context_hash', 'effect_kind', 'operation_id', 'work_item_id', 'goal_epoch')
                if any(prior.get(k) != item.get(k) for k in identity):
                    raise Rejected('OPERATION_ID_REBOUND')
                if prior['status'] == 'SUCCEEDED':
                    raise Rejected('ALREADY_SUCCEEDED')
                if prior['status'] in {'DISPATCHED', 'UNCERTAIN'}:
                    raise Rejected('RECONCILIATION_REQUIRED')
                if prior.get('retry_at', 0) > now:
                    raise Rejected('BACKOFF')
                attempt = prior['attempt'] + 1
                # Non-recovery explicit jobs never automatically retry uncertain effects;
                # FAILED_SAFE can be replayed only by the durable caller with same ID.
            if effect_kind == 'recovery':
                budget_key = str(work_item_id) + ':' + str(goal_epoch)
                row = db.execute('SELECT attempts FROM budgets WHERE project=? AND budget_key=?', (project, budget_key)).fetchone()
                used = row['attempts'] if row else 0
                if used >= 4:
                    raise Rejected('WORK_BUDGET_EXHAUSTED')
                db.execute('INSERT OR REPLACE INTO budgets VALUES(?,?,?)', (project, budget_key, used + 1))
            item.update(status='RESERVED', token=secrets.token_hex(24), expires_at=now + lease_seconds, attempt=attempt, retry_at=0)
            db.execute('INSERT OR REPLACE INTO v2_effects VALUES(?,?,?)', (project, operation_id, json.dumps(item)))
            db.execute('INSERT OR REPLACE INTO v2_effect_lease VALUES(1,?)', (json.dumps(item),))
            return item

    def _check(self, db, lease, now):
        row = db.execute('SELECT data FROM v2_effect_lease WHERE id=1').fetchone()
        if not row:
            raise Rejected('STALE_TOKEN')
        held = json.loads(row['data'])
        if any(held.get(k) != lease.get(k) for k in ('token','epoch','owner','project','turn','context_hash','operation_id','effect_kind','work_item_id','goal_epoch')):
            raise Rejected('STALE_TOKEN')
        if held['expires_at'] <= now:
            raise Rejected('EXPIRED_LEASE')
        self._validate(self.coordinator._read(db), held)
        return held

    def assert_lease(self, lease, now=None):
        with self.coordinator._transaction() as db:
            return self._check(db, lease, time.time() if now is None else now)

    def begin_effect(self, lease, now=None):
        with self.coordinator._transaction() as db:
            held = self._check(db, lease, time.time() if now is None else now)
            row = db.execute('SELECT data FROM v2_effects WHERE project=? AND operation_id=?', (held['project'], held['operation_id'])).fetchone()
            item = json.loads(row['data'])
            if item['status'] != 'RESERVED':
                raise Rejected('ALREADY_DISPATCHED')
            item['status'] = 'DISPATCHED'
            db.execute('UPDATE v2_effects SET data=? WHERE project=? AND operation_id=?', (json.dumps(item), item['project'], item['operation_id']))
            return item

    def ack(self, lease, outcome='SUCCEEDED', receipt=None, now=None):
        if outcome not in {'SUCCEEDED','FAILED_SAFE','UNCERTAIN'}:
            raise Rejected('INVALID_OUTCOME')
        now = time.time() if now is None else now
        with self.coordinator._transaction() as db:
            held = self._check(db, lease, now)
            row = db.execute('SELECT data FROM v2_effects WHERE project=? AND operation_id=?', (held['project'], held['operation_id'])).fetchone()
            item = json.loads(row['data'])
            if item['status'] != 'DISPATCHED':
                raise Rejected('NOT_DISPATCHED')
            item.update(status=outcome, receipt=receipt, retry_at=now + retry_delay(min(item['attempt'],4)) if outcome=='FAILED_SAFE' and item['effect_kind']=='recovery' else 0)
            db.execute('UPDATE v2_effects SET data=? WHERE project=? AND operation_id=?', (json.dumps(item), item['project'], item['operation_id']))
            db.execute('DELETE FROM v2_effect_lease')
            return item

    def observe(self, project, operation_id):
        with self.coordinator._connect() as db:
            row = db.execute('SELECT data FROM v2_effects WHERE project=? AND operation_id=?', (project, operation_id)).fetchone()
            return json.loads(row['data']) if row else None

    def reconcile(self, project, operation_id, epoch, observed_performed, evidence_ref, now=None):
        if type(observed_performed) is not bool or not isinstance(evidence_ref, str) or not evidence_ref.strip():
            raise Rejected('EVIDENCE_REQUIRED')
        with self.coordinator._transaction() as db:
            if type(epoch) is not int or self.coordinator._read(db)['epoch'] != epoch:
                raise Rejected('STALE_EPOCH')
            row = db.execute('SELECT data FROM v2_effects WHERE project=? AND operation_id=?', (project, operation_id)).fetchone()
            item = json.loads(row['data']) if row else None
            if not item or item['status'] not in {'DISPATCHED','UNCERTAIN'}:
                raise Rejected('NOT_RECONCILABLE')
            item.update(status='SUCCEEDED' if observed_performed else 'FAILED_SAFE', evidence_ref=evidence_ref, retry_at=0)
            db.execute('UPDATE v2_effects SET data=? WHERE project=? AND operation_id=?', (json.dumps(item), project, operation_id))
            held = db.execute('SELECT data FROM v2_effect_lease WHERE id=1').fetchone()
            if held and json.loads(held['data'])['token'] == item['token']:
                db.execute('DELETE FROM v2_effect_lease')
            return item


def main():
    request = json.loads(sys.stdin.read())
    try:
        owner = EffectOwner(request['database'])
        operation = request['method']
        if operation not in {'acquire','assert_lease','begin_effect','ack','observe','reconcile'}:
            raise Rejected('UNSUPPORTED_METHOD')
        result = getattr(owner, operation)(**request.get('args', {}))
        print(json.dumps({'ok':True,'result':result}, ensure_ascii=False))
    except (Rejected, ValueError, KeyError, TypeError) as error:
        print(json.dumps({'ok':False,'reason':str(error)}, ensure_ascii=False))
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
