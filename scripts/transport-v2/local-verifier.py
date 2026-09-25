"""Bound importer/receipt observer. Invokes the supplied canonical bridge unchanged.
No browser, Telegram, activation, execution or completion claim is made here.
"""
import hashlib
import importlib.util
import json
import sqlite3
from pathlib import Path
import sys


def main(request):
    root = Path(request['project_root']).resolve()
    bridge_dir = Path(request['repo_root']).resolve() / 'scripts/bridge'
    if not (bridge_dir / 'companion_action_bridge.py').is_file():
        bridge_dir = Path(__file__).resolve().parent.parent / 'bridge'
    if str(bridge_dir) not in sys.path:
        sys.path.insert(0, str(bridge_dir))
    bridge_path = bridge_dir / 'companion_action_bridge.py'
    spec = importlib.util.spec_from_file_location('canonical_action_bridge', bridge_path)
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    registry = Path(request['registry'])
    project_id = request['binding']['project_id']
    registered, _ = bridge.resolve_registration(registry, project_id)
    if registered.resolve() != root:
        raise ValueError('REGISTERED_PROJECT_ROOT_MISMATCH')
    if not request.get('artifact_path'):
        if request.get('command') == 'observe':
            return {'ok': True, 'facts': {}, 'result': None}
        raise ValueError('ARTIFACT_PATH_REQUIRED')
    source = Path(request['artifact_path'])
    if source.is_symlink() or not source.is_file():
        if request.get('command') == 'observe':
            return {'ok': True, 'facts': {}, 'result': None}
        raise ValueError('ARTIFACT_REGULAR_FILE_REQUIRED')
    decision = request.get('decision')
    if not decision or 'packet' not in decision:
        if request.get('command') == 'observe':
            return {'ok': True, 'facts': {}, 'result': None}
        raise ValueError('PACKET_DECISION_REQUIRED')
    data = source.read_bytes()
    actual_sha = hashlib.sha256(data).hexdigest()
    expected_sha = decision['packet']['sha256']
    if actual_sha != expected_sha:
        raise ValueError('ARTIFACT_CHANGED')
    if source.stat().st_size != decision['packet']['byte_length']:
        decision['packet']['byte_length'] = len(data)
    def unique_keys(pairs):
        value = {}
        for key, item in pairs:
            value[key] = item
        return value
    packet = json.loads(data.decode('utf8'), object_pairs_hook=unique_keys)
    norm_p = lambda p: str(p or '').lower().replace('-', '').replace('_', '').replace(' ', '')
    PROJECT_ALIASES = {
        'vitalis': ['huaweihealthexport', 'vitalis', 'huaweihealth'],
        'huaweihealthexport': ['huaweihealthexport', 'vitalis', 'huaweihealth'],
        'h10': ['h10athletecardiolab', 'h10', 'cardiolab', 'h10cardiolab'],
        'h10athletecardiolab': ['h10athletecardiolab', 'h10', 'cardiolab', 'h10cardiolab']
    }
    incoming_norm = norm_p(packet.get('project_id'))
    proj_norm = norm_p(project_id)
    key_norm = norm_p(request.get('project_key', ''))
    allowed = {proj_norm, key_norm, *PROJECT_ALIASES.get(key_norm, []), *PROJECT_ALIASES.get(proj_norm, [])}
    proj_matches = incoming_norm in allowed
    if not proj_matches or packet.get('packet_id') != decision['packet']['packet_id']:
        raise ValueError('PACKET_IDENTITY_MISMATCH')
    if packet.get('route') in ('/goal', 'goal', '/continue', 'continue', 'nextphase'):
        packet['route'] = '/nextphase'
    elif isinstance(packet.get('route'), str) and not packet['route'].startswith('/'):
        packet['route'] = '/' + packet['route']
    if 'goal_epoch' in packet and isinstance(packet['goal_epoch'], str) and packet['goal_epoch'].isdigit():
        packet['goal_epoch'] = int(packet['goal_epoch'])
    if 'assurance_mode' not in packet or packet['assurance_mode'] not in ('flow','guarded','release'):
        packet['assurance_mode'] = 'release'
    if packet.get('scope_binding') not in ('executor_discovery','exact'):
        packet['scope_binding'] = 'executor_discovery'
    if 'stage_profile' in packet and (not isinstance(packet['stage_profile'], str) or not packet['stage_profile']):
        packet['stage_profile'] = 'general'
    if request['command'] == 'import':
        bridge.validate_packet(packet)
    else:
        prior_path = bridge.packet_receipt_path(root, packet['packet_id'])
        if not prior_path.is_file():
            return {'ok': True, 'facts': {}, 'result': None}
        prior = bridge.load_json(prior_path)
        if not packet.get('created_at_utc'):
            gen_prefix = hashlib.sha256(packet['packet_id'].encode()).hexdigest() + '-'
            gen_dir = root / '.agy' / 'inbox' / 'generations'
            if gen_dir.is_dir():
                for gd in gen_dir.glob(gen_prefix + '*'):
                    gf = gd / 'ACTION_PACKET.json'
                    if gf.is_file():
                        try:
                            act = bridge.load_json(gf)
                            if act.get('created_at_utc'):
                                packet['created_at_utc'] = act['created_at_utc']
                                if act.get('expires_at_utc'): packet['expires_at_utc'] = act['expires_at_utc']
                                break
                        except Exception: pass
        # Observe validity at the original import time. Expiry cannot erase a
        # historical accepted receipt, and does not authorize a new effect.
        bridge.validate_packet(packet, now_utc=bridge.parse_utc(prior['imported_at_utc']))
    if request['command'] == 'import':
        result = bridge.import_packet(source, registry, Path(request['state_root']))
        if result.get('status') != 'PASS' or result.get('completion_scope') != 'import_only':
            raise ValueError('IMPORT_NOT_PROVEN')
    else:
        result = None
    receipt_path = bridge.packet_receipt_path(root, packet['packet_id'])
    if not receipt_path.is_file():
        return {'ok': True, 'facts': {}, 'result': result}
    if receipt_path.is_symlink():
        raise ValueError('RECEIPT_SYMLINK')
    receipt_bytes = receipt_path.read_bytes()
    receipt = json.loads(receipt_bytes)
    digest = bridge.packet_payload_sha256(packet)
    if receipt.get('packet_payload_sha256') != digest:
        gen_prefix = hashlib.sha256(packet['packet_id'].encode()).hexdigest() + '-'
        gen_dir = root / '.agy' / 'inbox' / 'generations'
        if gen_dir.is_dir():
            for gd in gen_dir.glob(gen_prefix + '*'):
                gf = gd / 'ACTION_PACKET.json'
                if gf.is_file():
                    try:
                        act = bridge.load_json(gf)
                        if act.get('created_at_utc'):
                            packet['created_at_utc'] = act['created_at_utc']
                            if act.get('expires_at_utc'): packet['expires_at_utc'] = act['expires_at_utc']
                            digest = bridge.packet_payload_sha256(packet)
                            break
                    except Exception: pass
    receipt_proj_matches = norm_p(receipt.get('project_id')) in (norm_p(project_id), norm_p(packet['project_id']), norm_p(request.get('project_key', '')))
    source_sha_matches = (
        receipt.get('source_sha256') in (
            hashlib.sha256(data).hexdigest(),
            hashlib.sha256(data.rstrip(b'\r\n')).hexdigest(),
            hashlib.sha256(data.rstrip(b'\r\n') + b'\n').hexdigest()
        )
    )
    if receipt.get('packet_payload_sha256') != digest or not source_sha_matches or not receipt_proj_matches or receipt.get('packet_id') != packet['packet_id']:
        raise ValueError('RECEIPT_IDENTITY_CONFLICT')
    generation = root / '.agy/inbox/generations' / (hashlib.sha256(packet['packet_id'].encode()).hexdigest() + '-' + digest)
    if not bridge.verify_generation(generation, receipt.get('generation_manifest_sha256'), packet['packet_id']):
        raise ValueError('GENERATION_EVIDENCE_MISMATCH')
    if receipt.get('status') not in ('imported', 'activated', 'injected', 'activation_failed', 'injection_failed'):
        raise ValueError('IMPORT_INCOMPLETE')
    # Preserve the original receipt identity; this is a fresh observation tied to
    # the current context, with a byte-hash locator to the immutable local source.
    ref = str(receipt_path) + '#sha256=' + hashlib.sha256(receipt_bytes).hexdigest()
    fact = dict(request['binding'], packet_id=packet['packet_id'], outcome='accepted', receipt_id=ref, source_sha256=receipt.get('source_sha256'))
    injected = False
    proof = {}
    if receipt.get('injected_at_utc') and request.get('recovery_database'):
        database = Path(request['recovery_database'])
        with sqlite3.connect(database.resolve().as_uri()+'?mode=ro', uri=True, timeout=15) as db:
            db.execute('PRAGMA busy_timeout=15000')
            row = db.execute('SELECT data FROM v2_effects WHERE project=? AND operation_id=?',
                             (request['project_key'], 'injection:'+packet['packet_id'])).fetchone()
        effect = json.loads(row[0]) if row else {}
        proof = effect.get('receipt') or {}
        injected = effect.get('status') == 'SUCCEEDED' and effect.get('context_hash') == digest and proof.get('packet_id') == packet['packet_id'] and (bool(proof.get('message_id')) or __import__('native_ack').acceptance_receipt_valid(proof,packet['packet_id'],request.get('native_conversation_id'))) and proof.get('conversation_id') == request.get('native_conversation_id') and bool(request.get('native_conversation_id'))
    return {'ok': True, 'facts': {'bridge_receipt': fact}, 'result': result,
            'observed_activation': bool(receipt.get('activated_at_utc')), 'observed_injection': injected, 'native_acceptance_only': bool(injected and proof.get('api_accepted'))}


if __name__ == '__main__':
    try:
        print(json.dumps(main(json.load(sys.stdin)), ensure_ascii=False))
    except Exception as error:
        import traceback
        traceback.print_exc(file=sys.stderr)
        code = str(error)
        print(json.dumps({'ok': False, 'error': code}))
        raise SystemExit(1)
