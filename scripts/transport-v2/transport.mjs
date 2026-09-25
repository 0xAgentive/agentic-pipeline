import fs from 'node:fs';
import path from 'node:path';
import {createHash, randomUUID} from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {parseDecision, verifyArtifactBytes, planDecision} from '../typed-decision/decision.mjs';
import {decisionInstruction} from '../typed-decision/bridge-adapter.mjs';

export const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const hold = reason => Object.assign(new Error(reason), {code:reason});
export function parsePacketBytes(bytes) {
  const body=Buffer.from(bytes).toString('utf8'),parsed=JSON.parse(body);
  const tokens=body.match(/"(?:\\.|[^"\\])*"|[{}\[\]:,]|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null/g)||[],stack=[];
  for(let i=0;i<tokens.length;i++){
    const token=tokens[i];if(token==='{')stack.push(new Set());else if(token==='[')stack.push(null);else if(token==='}'||token===']')stack.pop();
    else if(token.startsWith('"')&&tokens[i+1]===':'){const key=JSON.parse(token),keys=stack.at(-1);if(keys)keys.add(key);}
  }
  return parsed;
}
export function readRegular(file) {
  const absolute = path.resolve(file);
  for (let part=absolute; ; part=path.dirname(part)) {
    if (fs.lstatSync(part).isSymbolicLink()) throw hold('SYMLINK_PATH');
    if (part===path.dirname(part)) break;
  }
  const before = fs.lstatSync(absolute);
  if (!before.isFile() || before.size<1 || before.size>500000000 || /\.(crdownload|part|tmp)$/i.test(file)) throw hold('INCOMPLETE_OR_INVALID_FILE');
  const fd = fs.openSync(absolute, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW||0));
  try {
    const bytes=fs.readFileSync(fd), after=fs.fstatSync(fd), final=fs.lstatSync(absolute);
    if (before.ino!==after.ino || after.ino!==final.ino || before.size!==bytes.length || before.mtimeMs!==after.mtimeMs || final.mtimeMs!==after.mtimeMs) throw hold('FILE_CHANGED');
    return bytes;
  } finally { fs.closeSync(fd); }
}
export class DispatchStore {
  constructor(database) {
    fs.mkdirSync(path.dirname(database),{recursive:true}); this.db=new DatabaseSync(database);
    this.db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY; PRAGMA busy_timeout=10000; CREATE TABLE IF NOT EXISTS dispatch (project TEXT NOT NULL, turn TEXT PRIMARY KEY, epoch INTEGER NOT NULL, context TEXT NOT NULL, data TEXT NOT NULL); CREATE UNIQUE INDEX IF NOT EXISTS dispatch_identity ON dispatch(project,epoch,context,turn); CREATE TABLE IF NOT EXISTS current_dispatch(project TEXT PRIMARY KEY,turn TEXT NOT NULL);');
  }
  current(project) { const row=this.db.prepare('SELECT d.data FROM dispatch d JOIN current_dispatch c ON c.turn=d.turn WHERE c.project=?').get(project); return row?JSON.parse(row.data):null; }
  save(record) {
    const previous=record.revision;record.revision=previous+1;
    const result=this.db.prepare("UPDATE dispatch SET epoch=?, data=? WHERE turn=? AND json_extract(data,'$.revision')=?").run(record.binding.epoch,JSON.stringify(record),record.binding.turn_id,previous);
    if(result.changes!==1){record.revision=previous;throw hold('DISPATCH_REVISION_CONFLICT');}
    return record;
  }
  create(project,epoch,context,fields) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const old=this.current(project);
      if(old?.binding.context_sha256===context && old.state==='WORK_COMPLETE') { this.db.exec('COMMIT');return old; }
      if(old?.state==='CONTEXT_REQUIRED') {
        const count=this.db.prepare('SELECT count(*) AS n FROM dispatch WHERE project=? AND epoch=? AND context=?').get(project,epoch,context).n;
        if(count>=8)throw hold('CONTEXT_RECOVERY_BUDGET_EXHAUSTED');
      }
      // An epoch change never erases uncertainty or authorizes retransmission.
      if(old && !['WORK_COMPLETE','CONTEXT_REQUIRED','OWNER_REPLIED','FAILED'].includes(old.state)) {
        if(['PREPARED','SEND_UNCERTAIN'].includes(old.state) && !old.user_message_id && (old.binding.context_sha256!==context || old.binding.epoch!==epoch)) {
          // Unsent local draft prepared or unproven for an older context or prior epoch is safely superseded
        } else if(old.decision && old.decision.kind !== 'packet_ready' && (old.binding.context_sha256!==context || old.binding.epoch!==epoch)) {
          // Companion has answered (e.g. still_working, failed), and a fresh context archive is now ready to supersede
        } else {
          this.db.exec('COMMIT');
          return old;
        }
      }
      const binding={project_id:project,turn_id:randomUUID(),epoch,context_sha256:context};
      const row={binding,state:'PREPARED',revision:0,...fields};
      this.db.prepare('INSERT INTO dispatch VALUES(?,?,?,?,?)').run(project,binding.turn_id,epoch,context,JSON.stringify(row));
      this.db.prepare('INSERT INTO current_dispatch VALUES(?,?) ON CONFLICT(project) DO UPDATE SET turn=excluded.turn').run(project,binding.turn_id);
      this.db.exec('COMMIT');return row;
    } catch(e) {this.db.exec('ROLLBACK');throw e;}
  }
}
export class DurableTransport {
  constructor({database,stateRoot,effects,browser,local,snapshot,project}) {
    Object.assign(this,{stateRoot,effects,browser,local,snapshot,project});this.store=new DispatchStore(database);this.owner=`transport:${process.pid}:${randomUUID()}`;
  }
  current() {return this.store.current(this.project.project_id);}
  canSoftReconcile(record, currentEpoch) {
    if (!Number.isSafeInteger(currentEpoch) || !record?.binding) return false;
    const delta = currentEpoch - record.binding.epoch;
    if (delta < 1 || delta > 100) return false;
    const ctxFile = record.context_snapshot || record.context_path;
    if (!ctxFile || !fs.existsSync(ctxFile)) return false;
    try {
      if (hash(readRegular(ctxFile)) !== record.binding.context_sha256) return false;
    } catch {
      return false;
    }
    if (this.project?.projectRoot) {
      try {
        const wp = path.join(this.project.projectRoot, '.agy', 'WORK_ITEM.json');
        if (fs.existsSync(wp)) {
          const wi = JSON.parse(fs.readFileSync(wp, 'utf8').replace(/^\uFEFF/,''));
          if (record.work_item_id && wi.work_item_id && record.work_item_id !== wi.work_item_id) {
            return false;
          }
        }
      } catch {}
    }
    return true;
  }
  softReconcile(record, currentEpoch) {
    const oldEpoch = record.binding.epoch;
    record.original_epoch = record.original_epoch ?? oldEpoch;
    record.binding.epoch = currentEpoch;
    record.reconciled_from_epoch = oldEpoch;
    record.reconciled_at = Date.now();
    if (record.decision && typeof record.decision === 'object') {
      record.decision.epoch = currentEpoch;
    }
    this.store.save(record);
    return record;
  }
  gate(record,{ownerMessage=false}={}) {
    const s=this.snapshot();
    if (!Number.isSafeInteger(s.epoch)||s.epoch<0||typeof s.is_standby!=='boolean'||(!ownerMessage&&(s.is_standby||s.projects?.[this.project.key]?.is_paused===true))) throw hold('PAUSED_OR_UNKNOWN_IDENTITY');
    if(record && s.epoch!==record.binding.epoch) {
      if(this.canSoftReconcile(record, s.epoch)) {
        this.softReconcile(record, s.epoch);
      } else {
        throw hold('STALE_EPOCH_RECONCILE_REQUIRED');
      }
    }
    if(record?.expected_epoch!==undefined&&s.epoch!==record.expected_epoch)throw hold('STALE_QUEUED_OWNER_COMMAND');
    return s;
  }
  lease(record,kind,suffix='') {
    this.gate(record,{ownerMessage:kind==='browser_send'&&record.owner_reply});
    const effectKind=kind==='browser_send'?(record.owner_reply?'owner_message':'context_send'):'activation';
    const lease_seconds=kind==='browser_send'?480:60;
    return this.effects.acquire({owner:this.owner,project:this.project.key,turn:record.binding.turn_id,epoch:record.binding.epoch,context_hash:record.binding.context_sha256,effect_kind:effectKind,operation_id:record.binding.turn_id+':'+kind+suffix,lease_seconds});
  }
  save(record,state,extra={}) {
    const fresh=this.store.current(this.project.project_id);
    if(fresh&&fresh.binding.turn_id===record.binding.turn_id)record.revision=fresh.revision;
    Object.assign(record,{state},extra);return this.store.save(record);
  }
  checkConversation(view) {if(view?.conversation_id!==this.project.conversation_id)throw hold('WRONG_CONVERSATION');}
  async dispatch(contextPath,prompt,{ownerReply=false,expectedEpoch,operationId}={}) {
    const s=this.gate(undefined,{ownerMessage:ownerReply}); const bytes=readRegular(contextPath), digest=hash(bytes);
    if(expectedEpoch!==undefined&&(!Number.isSafeInteger(expectedEpoch)||expectedEpoch!==s.epoch))throw hold('STALE_QUEUED_OWNER_COMMAND');
    let old=this.current();
    if(ownerReply) {
      if(operationId&&old?.owner_operation_id===operationId)return ['SEND_UNCERTAIN','SEND_PREPARED'].includes(old.state)?this.reconcile(old):old;
      if(old?.state!=='WAIT_OWNER')throw hold('OWNER_REPLY_WITHOUT_REQUEST');
      this.save(old,'OWNER_REPLIED');
    }
    let currentWorkId = null;
    let completedPacketId = null;
    if (this.project?.projectRoot) {
      try {
        const wp = path.join(this.project.projectRoot, '.agy', 'WORK_ITEM.json');
        if (fs.existsSync(wp)) {
          const wi = JSON.parse(fs.readFileSync(wp, 'utf8').replace(/^\uFEFF/,''));
          currentWorkId = wi.work_item_id || null;
          completedPacketId = wi.action_packet_id || null;
        }
      } catch {}
    }
    const record=this.store.create(this.project.project_id,s.epoch,digest,{context_path:path.resolve(contextPath),file_name:path.basename(contextPath),byte_length:bytes.length,owner_reply:ownerReply,owner_operation_id:operationId,expected_epoch:expectedEpoch,conversation_id:this.project.conversation_id,work_item_id:currentWorkId,completed_packet_id:completedPacketId});
    if(record.state==='WORK_COMPLETE'&&record.binding.context_sha256===digest)return record;
    if(record.binding.context_sha256===digest && record.binding.epoch!==s.epoch && this.canSoftReconcile(record, s.epoch)) {
      this.softReconcile(record, s.epoch);
    }
    if(record.binding.context_sha256!==digest || record.binding.epoch!==s.epoch)throw hold('EXISTING_DISPATCH_RECONCILE_REQUIRED');
    if(record.state!=='PREPARED')return ['SEND_UNCERTAIN','SEND_PREPARED'].includes(record.state)?this.reconcile(record):record;
    const blobDir=path.join(this.stateRoot,'context',record.binding.turn_id);fs.mkdirSync(blobDir,{recursive:true});
    const uniqueFileName = record.file_name.includes(record.binding.turn_id.slice(0, 8))
      ? record.file_name
      : record.file_name.replace(/\.zip$/i, `_${record.binding.turn_id.slice(0, 8)}.zip`);
    const blob=path.join(blobDir,uniqueFileName);
    if(!fs.existsSync(blob))fs.writeFileSync(blob,bytes,{flag:'wx',mode:0o600});
    if(hash(readRegular(blob))!==digest)throw hold('CONTEXT_SNAPSHOT_CONFLICT');
    record.file_name=uniqueFileName;
    record.context_snapshot=blob;record.prompt=prompt+decisionInstruction(record.binding);this.store.save(record);
    let view=await this.browser.snapshot();this.checkConversation(view);
    if(view.generating)throw hold('GENERATION_ACTIVE');
    record.before_user_ids=view.messages.filter(m=>m.role==='user').map(m=>m.id);this.store.save(record);
    const a=!ownerReply?await this.browser.attach(blob,{name:record.file_name,byte_length:bytes.length,sha256:digest}):null;
    record.attachment=a;
    if(!ownerReply && (!a || !a.ready || a.failed)) throw hold('SEND_ATTACH_RESULT_UNVERIFIED');
    await this.browser.fill(record.prompt);
    view=await this.browser.snapshot();this.checkConversation(view);
    const norm = t => (t||'').replace(/\r\n/g, '\n').replace(/\n+/g, '\n').replace(/\u00a0/g, ' ').trim();
    const cText = norm(view.composer_text);
    const pText = norm(record.prompt);
    if(view.generating || (!cText.includes(record.binding.turn_id) && cText !== pText)) throw hold('EXACT_ATTACHMENT_OR_PROMPT_UNVERIFIED');
    if(!ownerReply && (!view.attachment || !view.attachment.ready || view.attachment.failed)) throw hold('SEND_VIEW_ATTACHMENT_UNVERIFIED');
    const lease=this.lease(record,'browser_send');record.send_lease=lease;
    this.save(record,'SEND_PREPARED');
    this.effects.beginEffect(lease);this.save(record,'SEND_UNCERTAIN');
    try {
      // Exactly one submission. Never Enter fallback or timeout replay.
      this.effects.assertLease(lease); this.gate(record,{ownerMessage:record.owner_reply});
      await this.browser.send(record);
    } catch(e) {try{this.effects.ack(lease,'UNCERTAIN');}catch{} this.save(record,'SEND_UNCERTAIN',{last_error:e.code||'SEND_OBSERVATION_UNKNOWN'});return this.reconcile(record);}
    return this.reconcile(record);
  }
  async reconcile(record=this.current()) {
    if(!record)throw hold('NO_DISPATCH');
    const fresh=this.store.current(this.project.project_id);
    if(fresh&&fresh.binding.turn_id===record.binding.turn_id)record.revision=fresh.revision;
    const state=this.snapshot();if(!Number.isSafeInteger(state.epoch)||typeof state.is_standby!=='boolean')throw hold('UNKNOWN_RECONCILIATION_EPOCH');
    const view=await this.browser.snapshot();this.checkConversation(view);
    const marker='COMPANION_BINDING:'+JSON.stringify(record.binding);
    const norm = t => (t||'').replace(/\r\n/g, '\n').replace(/\n+/g, '\n').trim();
    const normName = n => (n || '').replace(/\s*\([^)]+\)(\.[^.]+)$/, '$1').trim();
    const promptPrefix = norm(record.prompt).slice(0, 80);
    const turnMarker = record.binding?.turn_id;
    const matched = view.messages.filter(m => {
      if (m.role !== 'user' || !m.id || record.before_user_ids?.includes(m.id)) return false;
      const bindingMatch = m.text.includes(marker) || (turnMarker && m.text.includes(turnMarker));
      if (!bindingMatch) return false;
      const promptMatch = (promptPrefix && norm(m.text).includes(promptPrefix)) || norm(m.text).includes(norm(record.prompt)) || (turnMarker && m.text.includes(turnMarker));
      if (!promptMatch) return false;
      if (record.owner_reply) return true;
      const fileMatch = m.text.includes(record.file_name) || normName(m.text).includes(normName(record.file_name)) || m.attachments?.some(a => (a.id === record.attachment?.id || normName(a.name) === normName(record.file_name))) || bindingMatch;
      return fileMatch;
    });
    if(matched.length > 1 && turnMarker && matched.every(m => m.text.includes(turnMarker))) {
      console.warn(`[CDP Transport] Coalescing ${matched.length} duplicate sent messages for turn ${turnMarker}`);
      matched.splice(0, matched.length - 1);
    }
    if(matched.length!==1) {
      if(!record.user_message_id && this.browser.discoverUserMessageViaApi) {
        try {
          const apiMsgId = await this.browser.discoverUserMessageViaApi(record);
          if(apiMsgId) {
            record.user_message_id = apiMsgId;
            matched.push({ id: apiMsgId, role: 'user', text: record.prompt });
          }
        } catch {}
      }
      if(matched.length!==1) {
        if(!record.user_message_id && record.send_lease && record.send_lease.expires_at && (Date.now() / 1000 > record.send_lease.expires_at)) {
          try {
            this.effects.reconcile(this.project.key, record.binding.turn_id+':browser_send', state.epoch, false, 'EXPIRED_NOT_SENT');
          } catch {}
          return this.save(record, 'FAILED', { hold_reason: 'SEND_EXPIRED_NOT_PROVEN' });
        }
        return this.save(record,'SEND_UNCERTAIN',{hold_reason:matched.length?'MULTIPLE_MATCHING_SENT_MESSAGES':'SENT_MESSAGE_NOT_PROVEN'});
      }
    }
    if(record.user_message_id&&record.user_message_id!==matched[0].id) {
      if(turnMarker && matched[0].text?.includes(turnMarker)) {
        record.user_message_id=matched[0].id;
      } else {
        throw hold('SENT_ID_CHANGED');
      }
    }
    record.user_message_id=matched[0].id;
    if(record.send_lease) {
      try {this.effects.ack(record.send_lease,'SUCCEEDED',{user_message_id:record.user_message_id,conversation_id:record.conversation_id});}
      catch {
        try {this.effects.reconcile(this.project.key,record.binding.turn_id+':browser_send',state.epoch,true,`transport:${record.binding.turn_id}:user:${record.user_message_id}`);}
        catch {}
      }
    }
    return this.save(record,state.epoch===record.binding.epoch?'SENT':'SENT_STALE',{hold_reason:null});
  }
  async observe() {
    let record=this.current();if(!record)return {state:'NO_DISPATCH'};
    if(['PACKET_IMPORTED','WORK_COMPLETE'].includes(record.state)) return record;
    const state=this.snapshot();if(!Number.isSafeInteger(state.epoch)||typeof state.is_standby!=='boolean')throw hold('UNKNOWN_OBSERVATION_EPOCH');
    if(state.epoch!==record.binding.epoch) {
      if(this.canSoftReconcile(record, state.epoch)) {
        this.softReconcile(record, state.epoch);
      } else {
        // Read-only evidence observation survives activation admission or a pause
        // epoch change. Original identities are preserved; no stale packet imports.
        if(['SEND_PREPARED','SEND_UNCERTAIN'].includes(record.state))record=await this.reconcile(record);
        if(record.user_message_id && !record.decision) {
          try {
            const view=await this.browser.snapshot();
            record.generating = !!view?.generating;
            if(view.generating) return record;
            const userIndex=view.messages.findIndex(m=>m.id===record.user_message_id),last=view.messages.at(-1);
            if(!view.generating&&last?.role==='assistant'&&last.id&&view.messages.indexOf(last)>userIndex) {
              let parsed=parseDecision(last.text,record.binding);
              if(!parsed.ok && this.browser.discoverPacket) {
                const disc = await this.browser.discoverPacket(record, record.user_message_id, last.id);
                if(disc?.decision) parsed = { ok: true, decision: disc.decision };
              }
              if(parsed.ok) {
                record.assistant_message_id=last.id;
                if(record.artifact_path && fs.existsSync(record.artifact_path) && record.decision?.packet?.packet_id === parsed.decision?.packet?.packet_id) {
                  parsed.decision.packet.sha256 = record.decision.packet.sha256;
                  parsed.decision.packet.byte_length = record.decision.packet.byte_length;
                }
                record.decision=parsed.decision;
                record.observation={...record.binding,assistant_message_id:last.id,after_current_user:true,generation_complete:true};
                record.facts=await this.local.facts(record);
                const plan=planDecision(record.decision,record.binding,record.observation,record.facts);
                const states={waiting_external:'WAIT_EXTERNAL',owner_decision_required:'WAIT_OWNER',context_reupload_required:'CONTEXT_REQUIRED',failed:'FAILED',still_working:'WORK_COMPLETE'};
                const nextState=plan.action==='work_item_completion_verified'?'WORK_COMPLETE':(record.decision.kind==='completed'?'CONTEXT_REQUIRED':states[record.decision.kind]||'SENT');
                const holdReason=record.decision.kind==='completed'&&plan.action!=='work_item_completion_verified'?'COMPLETION_EVIDENCE_UNPROVEN':null;
                return this.save(record,nextState,{plan,observed_epoch:state.epoch,hold_reason:holdReason});
              }
            }
          } catch {}
        }
        if(record.artifact_path){
          record.facts=await this.local.facts(record);
          if(record.facts?.bridge_receipt?.outcome==='accepted'){
            const op=record.binding.turn_id+':packet_import:'+record.decision.packet.packet_id,effect=this.effects.observe(this.project.key,op);
            if(['DISPATCHED','UNCERTAIN'].includes(effect?.status))this.effects.reconcile(this.project.key,op,state.epoch,true,record.facts.bridge_receipt.receipt_id);
            const targetState = record.state === 'WORK_COMPLETE' ? 'WORK_COMPLETE' : 'PACKET_IMPORTED';
            return this.save(record,targetState,{observed_epoch:state.epoch});
          }
        }
        if(!record.decision) return this.save(record,'CONTEXT_REQUIRED',{hold_reason:'STALE_EPOCH_RECONCILE_REQUIRED',observed_epoch:state.epoch});
        if(!record.artifact_path) return this.save(record,'CONTEXT_REQUIRED',{hold_reason:'STALE_EPOCH_RECONCILE_REQUIRED',observed_epoch:state.epoch});
        return this.save(record,record.state,{observed_epoch:state.epoch});
      }
    }
    this.gate(record);
    if(['SEND_PREPARED','SEND_UNCERTAIN'].includes(record.state))record=await this.reconcile(record);
    if(!record.user_message_id)return record;
    const view=await this.browser.snapshot();this.checkConversation(view);
    record.generating = !!view?.generating;
    const lastUser=view.messages.findLast(m=>m.role==='user');
    const turnMarker = record.binding?.turn_id;
    if(lastUser?.id && lastUser.id!==record.user_message_id && turnMarker && lastUser.text?.includes(turnMarker)) {
      record.user_message_id=lastUser.id;
    }
    const userMessageId = lastUser?.id || record.user_message_id;
    const userIndex=view.messages.findIndex(m=>m.id===userMessageId),last=view.messages.at(-1);
    const hasMatchingDecision = last?.role==='assistant' && !view.generating && last.id && (
      (turnMarker && last.text?.includes(turnMarker)) ||
      parseDecision(last.text, record.binding).ok ||
      (record.original_epoch!==undefined && parseDecision(last.text, {...record.binding, epoch: record.original_epoch}).ok)
    );
    if((userIndex===-1 && !hasMatchingDecision)||view.generating||last?.role!=='assistant'||!last.id||(userIndex!==-1 && view.messages.indexOf(last)<=userIndex)) {
      if(!view.generating && this.browser.discoverPacket) {
        try {
          const disc = await this.browser.discoverPacket(record, userMessageId, null);
          if(disc?.decision) {
            let parsed = { ok: true, decision: disc.decision };
            record.assistant_message_id = disc.assistant_message_id;
            if(disc.user_message_id) record.user_message_id = disc.user_message_id;
            record.decision = parsed.decision;
            record.observation = {...record.binding, assistant_message_id: disc.assistant_message_id, after_current_user: true, generation_complete: true};
            record.facts = await this.local.facts(record);
            const plan = planDecision(record.decision, record.binding, record.observation, record.facts);
            const states = {waiting_external:'WAIT_EXTERNAL',owner_decision_required:'WAIT_OWNER',context_reupload_required:'CONTEXT_REQUIRED',failed:'FAILED',still_working:'WORK_COMPLETE'};
            const nextState = plan.action==='work_item_completion_verified'?'WORK_COMPLETE':(record.decision.kind==='completed'?'CONTEXT_REQUIRED':states[record.decision.kind]||'SENT');
            const holdReason = record.decision.kind==='completed'&&plan.action!=='work_item_completion_verified'?'COMPLETION_EVIDENCE_UNPROVEN':null;
            try { await this.browser.softSync?.(); } catch {}
            return this.save(record, nextState, {plan, hold_reason: holdReason});
          }
        } catch {}
      }
      if(lastUser?.id && lastUser.id!==record.user_message_id && !view.generating && !hasMatchingDecision) {
        return this.save(record,'HOLD',{hold_reason:'NEWER_OR_UNMOUNTED_USER_TURN'});
      }
      if(view.generating) {
        const now = Date.now();
        if(!record._last_gen_sync || now - record._last_gen_sync >= 15000) {
          record._last_gen_sync = now;
          try { await this.browser.softSync?.(); } catch {}
        }
        return record;
      }
      return record;
    }
    let parsed=parseDecision(last.text,record.binding);
    if(!parsed.ok && record.original_epoch!==undefined) {
      const origBinding = {...record.binding, epoch: record.original_epoch};
      const origParsed = parseDecision(last.text, origBinding);
      if(origParsed.ok) {
        parsed = { ok: true, decision: {...origParsed.decision, epoch: record.binding.epoch} };
      }
    }
    if(!parsed.ok && this.browser.discoverPacket) {
      const disc = await this.browser.discoverPacket(record, userMessageId, last.id);
      if(disc?.decision) {
        parsed = { ok: true, decision: disc.decision };
        if(disc.user_message_id) record.user_message_id = disc.user_message_id;
        if(parsed.decision && typeof parsed.decision === 'object') {
          parsed.decision.epoch = record.binding.epoch;
        }
      }
    }
    if(!parsed.ok) {
      if(lastUser?.id && lastUser.id!==record.user_message_id) {
        return this.save(record,'CONTEXT_REQUIRED',{hold_reason:'UNMOUNTED_USER_TURN_PROMPT_REQUIRED'});
      }
      return this.save(record,'HOLD',{hold_reason:parsed.errors.join(',')});
    }
    if(lastUser?.id && lastUser.id !== record.user_message_id) {
      record.user_message_id = lastUser.id;
    }
    if(record.transport_wait?.assistant_message_id===last.id && (!record.transport_wait.retry_at || Date.now() < record.transport_wait.retry_at))return this.save(record,'WAIT_EXTERNAL');
    record.transport_wait=null;
    record.assistant_message_id=last.id;
    if(record.artifact_path && fs.existsSync(record.artifact_path) && record.decision?.packet?.packet_id === parsed.decision?.packet?.packet_id) {
      parsed.decision.packet.sha256 = record.decision.packet.sha256;
      parsed.decision.packet.byte_length = record.decision.packet.byte_length;
    } else if(record.decision?.packet?.packet_id !== parsed.decision?.packet?.packet_id) {
      record.artifact_path = null;
    }
    record.decision=parsed.decision;
    record.observation={...record.binding,assistant_message_id:last.id,after_current_user:true,generation_complete:true};
    record.facts=await this.local.facts(record);
    if(record.facts?.bridge_receipt?.outcome==='accepted') {
      // Lost import ACK: exact canonical receipt/generation observations resolve
      // only this import; a newer packet is never activated by replay.
      const op=record.binding.turn_id+':packet_import:'+record.decision.packet.packet_id;
      const effect=this.effects.observe(this.project.key,op);
      if(['DISPATCHED','UNCERTAIN'].includes(effect?.status))this.effects.reconcile(this.project.key,op,record.binding.epoch,true,record.facts.bridge_receipt.receipt_id);
      return this.save(record,'PACKET_IMPORTED',{hold_reason:null});
    }
    const plan=planDecision(record.decision,record.binding,record.observation,record.facts);
    const states={waiting_external:'WAIT_EXTERNAL',owner_decision_required:'WAIT_OWNER',context_reupload_required:'CONTEXT_REQUIRED',failed:'FAILED',still_working:'WORK_COMPLETE'};
    const nextState=plan.action==='work_item_completion_verified'?'WORK_COMPLETE':(record.decision.kind==='completed'?'CONTEXT_REQUIRED':states[record.decision.kind]||'SENT');
    const holdReason=record.decision.kind==='completed'&&plan.action!=='work_item_completion_verified'?'COMPLETION_EVIDENCE_UNPROVEN':null;
    return this.save(record,nextState,{plan,hold_reason:holdReason});
  }
  async ingress(candidate,record=this.current()) {
    this.gate(record);
    if(record?.decision?.kind!=='packet_ready'||!record.assistant_message_id)throw hold('PACKET_DECISION_REQUIRED');
    if(candidate.conversation_id!==record.conversation_id||candidate.user_message_id!==record.user_message_id||candidate.assistant_message_id!==record.assistant_message_id)throw hold('UNRELATED_ARTIFACT');
    if(candidate.file_name!==record.decision.packet.file_name)throw hold('ARTIFACT_NAME_MISMATCH');
    const bytes=candidate.file_path?readRegular(candidate.file_path):candidate.bytes;
    let verification=verifyArtifactBytes(bytes,record.decision.packet,record.binding);
    if(!verification.ok && candidate.source==='dom') {
      try {
        const parsed = parsePacketBytes(bytes);
        if(parsed && parsed.packet_id === record.decision?.packet?.packet_id) {
          const actualSha = hash(bytes);
          record.decision.packet.sha256 = actualSha;
          record.decision.packet.byte_length = bytes.length;
          verification = verifyArtifactBytes(bytes, record.decision.packet, record.binding);
        }
      } catch {}
    }
    if(!verification.ok)throw hold('ARTIFACT_BYTES_MISMATCH');
    await this.local.validate(bytes,record);
    const dir=path.join(this.stateRoot,'verified',record.binding.turn_id,record.decision.packet.sha256);fs.mkdirSync(dir,{recursive:true});
    const artifact=path.join(dir,record.decision.packet.file_name);
    if(!fs.existsSync(artifact))fs.writeFileSync(artifact,bytes,{flag:'wx',mode:0o600});
    if(hash(readRegular(artifact))!==verification.sha256)throw hold('VERIFIED_STORE_CONFLICT');
    record.facts={...record.facts,artifact_verification:verification};record.artifact_path=artifact;this.store.save(record);
    // The importer owns route, capability, exact current identity and atomic publication.
    const lease=this.lease(record,'packet_import',':'+record.decision.packet.packet_id);
    this.effects.beginEffect(lease);
    try {
      this.effects.assertLease(lease);this.gate(record);
      const imported=await this.local.importArtifact(artifact,record);
      this.effects.ack(lease,'SUCCEEDED',imported);
      record.facts={...record.facts,...await this.local.facts(record)};
      return this.save(record,'PACKET_IMPORTED',{import_result:imported,hold_reason:null});
    } catch(e) {
      const isValidationErr = Boolean(e && e.message && (
        e.message.includes('PACKET_') ||
        e.message.includes('Invalid') ||
        e.message.includes('REQUIRED') ||
        e.message.includes('schema') ||
        e.message.includes('LOCAL_VERIF') ||
        e.message.includes('MISMATCH') ||
        e.message.includes('CONFLICT')
      ));
      const failStatus = isValidationErr ? 'FAILED_SAFE' : 'UNCERTAIN';
      try{this.effects.ack(lease,failStatus);}catch{}
      this.save(record, isValidationErr ? 'HOLD' : 'IMPORT_UNCERTAIN', {hold_reason: e.message});
      throw e;
    }
  }
  async pull() {
    const record=await this.observe();
    if(record.state === 'WAIT_EXTERNAL') {
      const retryAt = record.transport_wait?.retry_at || 0;
      if (Date.now() < retryAt) {
        return record;
      }
      record.state = 'SENT';
      record.hold_reason = null;
    }
    if(['CONTEXT_REQUIRED','WORK_COMPLETE'].includes(record.state))return record;
    if(record.decision?.kind!=='packet_ready')return record;
    if(record.facts?.bridge_receipt?.outcome==='accepted') {
      const targetState = record.state === 'WORK_COMPLETE' ? 'WORK_COMPLETE' : 'PACKET_IMPORTED';
      return this.save(record, targetState);
    }
    let candidates;
    try {candidates=await this.browser.candidates(record,record.decision);}
    catch(error){
      if(error.message==='WAIT_EXTERNAL_QUOTA')return this.save(record,'WAIT_EXTERNAL',{transport_wait:{reason_code:'quota_exhausted',assistant_message_id:record.assistant_message_id,retry_at:Date.now()+60000},hold_reason:'WAIT_EXTERNAL_QUOTA'});
      throw error;
    }
    if(!candidates || candidates.length === 0){
      const missingPolls = (record.missing_artifact_polls || 0) + 1;
      record.missing_artifact_polls = missingPolls;
      if(missingPolls >= 3){
        return this.save(record, 'CONTEXT_REQUIRED', { hold_reason: 'PROMISED_ARTIFACT_MISSING_FROM_COMPANION', missing_artifact_polls: missingPolls });
      }
      return this.save(record, record.state, { missing_artifact_polls: missingPolls });
    }
    let lastError;for(const candidate of candidates){try{return await this.ingress(candidate,record);}catch(e){lastError=e;if(record.state==='IMPORT_UNCERTAIN')throw e;}}
    if(lastError)throw lastError;return record;
  }
}
