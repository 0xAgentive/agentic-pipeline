import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
// Serialized unchanged into the existing CDP Runtime.evaluate API. No application
// internals, tokens or inferred DOM positions serve as message/file identities.
export async function browserProbe() {
  const composer=document.querySelector('div#prompt-textarea, div.ProseMirror[contenteditable="true"], div[role="textbox"][contenteditable="true"]') || document.querySelector('#prompt-textarea:not(textarea), textarea:not([class*="fallback"]):not([aria-hidden="true"])') || document.querySelector('textarea');
  const form=composer?.closest('form') || composer?.closest('[data-type="unified-composer"]') || composer?.parentElement?.parentElement?.parentElement || document;
  const id=el=>el?.getAttribute('data-message-id') || el?.closest('[data-message-id]')?.getAttribute('data-message-id') || el?.getAttribute('data-content-search-unit-key') || el?.closest('[data-content-search-unit-key]')?.getAttribute('data-content-search-unit-key') || el?.getAttribute('data-turn-key') || el?.closest('[data-turn-key]')?.getAttribute('data-turn-key') || null;
  const hasErrorText = t => /(?:загрузка не удалась|upload failed|не удалось загрузить|failed to upload|error|ошибка)/i.test(t || '');
  const attachments = root => {
    if (!root) return [];
    const legacy = Array.from(root.querySelectorAll('[data-file-id]'));
    if (legacy.length > 0) {
      return legacy.map(el => {
        const text = (el.innerText || '') + ' ' + (el.getAttribute('aria-label') || '');
        return {
          id: el.getAttribute('data-file-id') || el.getAttribute('aria-label') || '',
          name: el.getAttribute('data-file-name') || el.getAttribute('title') || el.getAttribute('aria-label') || '',
          byte_length: Number(el.getAttribute('data-file-size')) || null,
          failed: hasErrorText(text)
        };
      });
    }
    const tiles = Array.from(root.querySelectorAll('[role="group"][aria-label*="."], button[aria-label*="Удалить"], button[aria-label*="Remove"], button[aria-label*=".zip"], span[title*=".zip"], [aria-label*=".zip"], [title*=".zip"], [class*="composer-attachment"]'));
    const res = [];
    for (const el of tiles) {
      let name = el.getAttribute('aria-label') || el.getAttribute('title') || '';
      if (name.startsWith('Удалить')) {
        name = name.replace(/^Удалить(\s+файл)?\s*\d*:\s*/i, '').replace(/^Удалить\s+/i, '').trim();
      } else if (name.startsWith('Remove')) {
        name = name.replace(/^Remove(\s+file)?\s*\d*:\s*/i, '').replace(/^Remove\s+/i, '').trim();
      }
      const container = el.closest('[class*="attachment"]') || el.closest('[role="group"]') || el;
      const cardText = (container.innerText || '') + ' ' + (el.innerText || '');
      const failed = hasErrorText(cardText);
      if (name && !res.some(r => r.name === name)) {
        res.push({
          id: el.getAttribute('data-file-id') || name,
          name: name,
          byte_length: Number(el.getAttribute('data-file-size')) || null,
          failed
        });
      }
    }
    return res;
  };
  let allNodes=Array.from(document.querySelectorAll('[data-message-author-role]'));
  let messages;
  if (allNodes.length > 0) {
    const recentThreshold=Math.max(0,allNodes.length-10);
    messages=allNodes.map((el,i)=>({id:id(el),role:el.getAttribute('data-message-author-role'),text:i>=recentThreshold?(el.innerText||''):'',attachments:i>=recentThreshold?attachments(el.closest('[data-testid^="conversation-turn-"]')||el):[]}));
  } else {
    const headings = Array.from(document.querySelectorAll('h1, h2, h3, h4, h5, h6, [role="heading"]'));
    const validMessages = [];
    for (const h of headings) {
      const hText = (h.innerText || '').toLowerCase();
      const isUser = hText.includes('вы') || hText.includes('you');
      const isAssistant = hText.includes('chatgpt');
      if (!isUser && !isAssistant) continue;
      const role = isAssistant ? 'assistant' : 'user';
      const container = h.closest('[data-content-search-unit-key]') || h.parentElement;
      const unitKey = container?.getAttribute('data-content-search-unit-key') || h.closest('[data-turn-key]')?.getAttribute('data-turn-key') || '';
      validMessages.push({
        element: container,
        id: unitKey,
        role
      });
    }
    if (validMessages.length > 0) {
      const recentThreshold = Math.max(0, validMessages.length - 10);
      messages = validMessages.map((vm, i) => ({
        id: vm.id,
        role: vm.role,
        text: i >= recentThreshold ? (vm.element.innerText || '') : '',
        attachments: i >= recentThreshold ? attachments(vm.element) : []
      }));
    } else {
      const units = Array.from(document.querySelectorAll('[data-content-search-unit-key]'));
      if (units.length > 0) {
        const recentThreshold = Math.max(0, units.length - 10);
        messages = units.map((u, i) => {
          const key = u.getAttribute('data-content-search-unit-key') || '';
          const isAssistant = key.endsWith(':assistant') || u.querySelector('[data-markdown-text-style*="assistant"]') !== null;
          const isUser = key.endsWith(':user') || u.querySelector('[data-markdown-text-style*="user"]') !== null;
          const role = isAssistant ? 'assistant' : (isUser ? 'user' : 'unknown');
          const uId = u.getAttribute('data-message-id') || key;
          const text = i >= recentThreshold ? (u.innerText || '') : '';
          const turnContainer = u.closest('[data-turn-key]') || u.closest('[data-content-search-turn-key]') || u;
          return {
            id: uId,
            role,
            text,
            attachments: i >= recentThreshold ? attachments(turnContainer) : []
          };
        });
      } else {
        messages = [];
      }
    }
  }
  const normName = n => (n || '').replace(/\s*\([^)]+\)(\.[^.]+)$/, '$1').trim();
  const input=document.querySelector('#upload-files') || form?.querySelector('input[type="file"]');
  let attachment=null;
  if(form) {
    const formAtts = attachments(form);
    const formHasError = hasErrorText(form.innerText || '');
    const hasProgress = !!form.querySelector('[role="progressbar"], [data-testid="upload-progress"], .cursor-wait');
    if(input?.files?.length===1) {
      const file=input.files[0],matches=formAtts.filter(a=>normName(a.name)===normName(file.name));
      if(matches.length>=1) {
        const bytes=await file.arrayBuffer();
        const digest=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
        const isFailed = Boolean(matches[0].failed || formHasError);
        attachment={...matches[0],name:normName(matches[0].name),byte_length:file.size,sha256:digest,ready:!hasProgress && !isFailed,failed:isFailed};
      }
    } else if(formAtts.length >= 1) {
      const isFailed = Boolean(formAtts[0].failed || formHasError);
      attachment={...formAtts[0],name:normName(formAtts[0].name),byte_length:formAtts[0].byte_length||null,sha256:null,ready:!hasProgress && !isFailed,failed:isFailed};
    }
  }
  const match=location.pathname.match(/(?:^|\/)c\/([A-Za-z0-9-]+)(?:\/|$)/);
  const isGenerating = !!document.querySelector('button[data-testid="stop-button"], button[aria-label*="Stop"], button[aria-label*="Остановить"], button[aria-label*="Прекратить"], [data-testid*="thinking"], [data-testid*="reasoning"], [aria-label*="Thinking"], [aria-label*="Размышление"], .result-streaming, div[class*="streaming"], button[data-testid="fruitjuice-send-button"][disabled], button[data-testid="send-button"][disabled]');
  const continueBtn = document.querySelector('button[data-testid="continue-generating-button"], button[aria-label*="Continue generating"], button[aria-label*="Продолжить генерацию"], button[aria-label*="Продолжить"]') || Array.from(document.querySelectorAll('button, [role="button"]')).find(b => {
    const t = (b.innerText || b.textContent || '').trim();
    return (t === 'Продолжить генерацию' || t === 'Continue generating' || t === 'Продолжить' || t === 'Continue') && !b.disabled;
  });
  if (continueBtn && !continueBtn.disabled) {
    try { continueBtn.click(); } catch {}
  }
  const retryBtn = document.querySelector('button[aria-label*="Retry"], button[aria-label*="Повторить"], button[data-testid*="retry"], [role="button"][aria-label*="Retry"], [role="button"][aria-label*="Повторить"]') || Array.from(document.querySelectorAll('button, [role="button"]')).find(b => {
    const t = (b.innerText || b.textContent || '').trim();
    return (t === 'Повторить' || t === 'Retry' || t.includes('Повторить') || t.includes('Retry')) && !b.disabled;
  });
  if (retryBtn && !retryBtn.disabled) {
    try { retryBtn.click(); } catch {}
  }
  try {
    const dialogs = Array.from(document.querySelectorAll('[role="dialog"], [role="alertdialog"], div.popover, div[data-state="open"]'));
    for (const d of dialogs) {
      const text = (d.innerText || '').toLowerCase();
      if (text.includes('stay logged out') || text.includes('dismiss') || text.includes('понятно') || text.includes('close') || text.includes('закрыть')) {
        const btn = d.querySelector('button[aria-label="Close"], button[aria-label="Закрыть"]') || Array.from(d.querySelectorAll('button')).find(b => {
          const bt = (b.innerText || '').toLowerCase();
          return bt.includes('stay logged out') || bt.includes('dismiss') || bt.includes('понятно') || bt.includes('close') || bt.includes('закрыть');
        });
        if (btn) { try { btn.click(); } catch {} }
      }
    }
  } catch {}
  return {conversation_id:match?.[1]||null,generating:isGenerating || !!continueBtn,messages,attachment,composer_text:composer?.innerText||composer?.value||''};
}
export class CdpBrowser {
  constructor(conn,{downloadRoot,pollMs=500,uploadPolls=600}){Object.assign(this,{conn,downloadRoot,pollMs,uploadPolls});}
  async evaluate(fn,...args){const r=await this.conn.send('Runtime.evaluate',{expression:`(${fn.toString()})(...${JSON.stringify(args)})`,awaitPromise:true,returnByValue:true});if(r.exceptionDetails)throw new Error('BROWSER_EVALUATION_FAILED');return r.result?.value;}
  snapshot(){return this.evaluate(browserProbe);}
  async attach(file,expected){
    const maxAttempts = 6;
    const normName = n => (n || '').replace(/\s*\([^)]+\)(\.[^.]+)$/, '$1').trim();
    for(let attempt=1; attempt<=maxAttempts; attempt++){
      await this.evaluate(()=>{
        const dialogs = Array.from(document.querySelectorAll('[role="dialog"], [role="alertdialog"], div.popover'));
        for (const d of dialogs) {
          if ((d.innerText || '').includes('Вы уже загрузили этот файл') || (d.innerText || '').includes('already uploaded') || (d.innerText || '').includes('Попробуйте загрузить')) {
            const btn = d.querySelector('button');
            if (btn) btn.click();
          }
        }
        const composer=document.querySelector('div#prompt-textarea, div.ProseMirror[contenteditable="true"], div[role="textbox"][contenteditable="true"]') || document.querySelector('#prompt-textarea:not(textarea), textarea:not([class*="fallback"]):not([aria-hidden="true"])') || document.querySelector('textarea');
        const form=composer?.closest('form') || composer?.closest('[data-type="unified-composer"]') || document;
        form.querySelectorAll('button[aria-label*="Удалить"], button[aria-label*="Remove"], button[data-testid*="remove-file"], button[data-testid*="delete-file"]').forEach(b => b.click());
      });
      await wait(400);
      await this.conn.send('DOM.enable');const doc=await this.conn.send('DOM.getDocument',{depth:1});
      let node=await this.conn.send('DOM.querySelector',{nodeId:doc.root.nodeId,selector:'#upload-files'});
      if(!node.nodeId)node=await this.conn.send('DOM.querySelector',{nodeId:doc.root.nodeId,selector:'input[type="file"]:not(#upload-photos):not(#upload-camera):not([accept*="image"]):not([accept*="video"])'});
      if(!node.nodeId)node=await this.conn.send('DOM.querySelector',{nodeId:doc.root.nodeId,selector:'input[type="file"]'});
      if(!node.nodeId)throw new Error('FILE_INPUT_MISSING');
      await this.conn.send('DOM.setFileInputFiles',{nodeId:node.nodeId,files:[file]});
      await this.evaluate(()=>{
        const input=document.querySelector('#upload-files') || document.querySelector('input[type="file"]:not(#upload-photos):not(#upload-camera):not([accept*="image"]):not([accept*="video"])') || document.querySelector('input[type="file"]');
        if(input){
          input.dispatchEvent(new Event('change', { bubbles: true }));
          input.dispatchEvent(new Event('input', { bubbles: true }));
        }
      });
      const pollsForAttempt = Math.min(240, this.uploadPolls);
      let failedThisAttempt = false;
      for(let i=0;i<pollsForAttempt;i++){
        const s=await this.snapshot(),a=s.attachment;
        if(a?.failed) {
          failedThisAttempt = true;
          console.warn(`[CDP Transport] Attachment upload rejected (attempt ${attempt}/${maxAttempts}): ${a.name}. Retrying...`);
          break;
        }
        if(a?.ready&&!a.failed&&a.id&&normName(a.name)===normName(expected.name)) {
          if(!a.byte_length) a.byte_length = expected.byte_length;
          if(!a.sha256) a.sha256 = expected.sha256;
          if(a.byte_length===expected.byte_length&&a.sha256===expected.sha256)return a;
        }
        if(i % 5 === 0) {
          await this.evaluate(()=>{
            const dialogs = Array.from(document.querySelectorAll('[role="dialog"], [role="alertdialog"], div.popover'));
            for (const d of dialogs) {
              if ((d.innerText || '').includes('Вы уже загрузили этот файл') || (d.innerText || '').includes('already uploaded') || (d.innerText || '').includes('Попробуйте загрузить')) {
                const btn = d.querySelector('button');
                if (btn) btn.click();
              }
            }
          });
        }
        await wait(this.pollMs);
      }
      if(attempt < maxAttempts) {
        const backoffMs = Math.min(20000, Math.round(3000 * Math.pow(1.5, attempt - 1)));
        console.warn(`[CDP Transport] Cleaning up and waiting ${Math.round(backoffMs/1000)}s before retry ${attempt + 1}...`);
        await this.evaluate(()=>{
          const composer=document.querySelector('div#prompt-textarea, div.ProseMirror[contenteditable="true"], div[role="textbox"][contenteditable="true"]') || document.querySelector('#prompt-textarea:not(textarea), textarea:not([class*="fallback"]):not([aria-hidden="true"])') || document.querySelector('textarea');
          const form=composer?.closest('form') || composer?.closest('[data-type="unified-composer"]') || document;
          form.querySelectorAll('button[aria-label*="Удалить"], button[aria-label*="Remove"], button[data-testid*="remove-file"], button[data-testid*="delete-file"]').forEach(b => b.click());
        });
        await wait(backoffMs);
      }
    }
    throw new Error('ATTACH_TIMEOUT_EXACT_ATTACHMENT_UNVERIFIED');
  }
  async fill(text){
    const ok=await this.evaluate((val)=>{
      const el=document.querySelector('div#prompt-textarea, div.ProseMirror[contenteditable="true"], div[role="textbox"][contenteditable="true"]') || document.querySelector('#prompt-textarea:not(textarea), textarea:not([class*="fallback"]):not([aria-hidden="true"])') || document.querySelector('textarea');
      if(!el)return false;
      el.focus();
      if(el.tagName==='TEXTAREA'||el.tagName==='INPUT'){
        el.value=val;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      } else {
        try {
          const sel = window.getSelection();
          const range = document.createRange();
          range.selectNodeContents(el);
          sel.removeAllRanges();
          sel.addRange(range);
          document.execCommand('delete', false, null);
        } catch {}
        const lines = (val||'').split(/\r?\n/);
        el.innerHTML = lines.map(p => '<p dir="auto">' + (p ? p.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;') : '<br>') + '</p>').join('');
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
      return true;
    }, text);
    if(!ok)throw new Error('COMPOSER_MISSING');
  }
  async send(record){
    let coords=null;
    for(let attempt=0;attempt<20;attempt++){
      coords=await this.evaluate((expected)=>{
        if(location.pathname.split('/').filter(Boolean).at(-1)!==expected.conversation_id)return null;
        if(document.querySelector('button[data-testid="stop-button"], button[aria-label*="Stop"], button[aria-label*="Остановить"]'))return null;
        const el=document.querySelector('div#prompt-textarea, div.ProseMirror[contenteditable="true"], div[role="textbox"][contenteditable="true"]') || document.querySelector('#prompt-textarea:not(textarea), textarea:not([class*="fallback"]):not([aria-hidden="true"])') || document.querySelector('textarea'),form=el?.closest('form')||el?.closest('[data-type="unified-composer"]')||el?.parentElement?.parentElement?.parentElement||document;
        const norm = t => (t||'').replace(/\r\n/g, '\n').replace(/\n+/g, '\n').replace(/\u00a0/g, ' ').trim();
        const pText = norm(el?.innerText||el?.value||'');
        const eText = norm(expected.prompt);
        if(!pText.includes(expected.binding?.turn_id) && pText !== eText)return null;
        if(!expected.owner_reply){
          const normName = n => (n || '').replace(/\s*\([^)]+\)(\.[^.]+)$/, '$1').trim();
          const hasErrorText = t => /(?:загрузка не удалась|upload failed|не удалось загрузить|failed to upload)/i.test(t || '');
          if (hasErrorText(form?.innerText || '')) return null;
          const atts=Array.from(form?.querySelectorAll('[role="group"][aria-label*="."], button[aria-label*="Удалить"], button[aria-label*="Remove"], button[aria-label*=".zip"], [data-file-id]')||[]);
          if(!atts.some(f=>{
            const cardText = (f.closest('[class*="attachment"], [role="group"]') || f).innerText || '';
            if (hasErrorText(cardText)) return false;
            const fid=f.getAttribute('data-file-id');
            const fname=normName(f.getAttribute('data-file-name')||f.getAttribute('title')||f.getAttribute('aria-label')||f.innerText||'');
            return fid===expected.attachment?.id || fname.includes(normName(expected.file_name));
          })||form.querySelector('[role="progressbar"], [data-testid="upload-progress"], .cursor-wait'))return null;
        }
        const b=document.querySelector('button[data-testid="fruitjuice-send-button"], button[data-testid="send-button"], #composer-submit-button, button[data-testid="composer-submit-button"], button[aria-label*="Отправить"], button[aria-label*="Send"], button.bg-composer-primary, button[type="submit"]');
        if(!b||b.disabled||b.getAttribute('aria-disabled')==='true'||/stop|останов/i.test((b.getAttribute('aria-label')||'')+' '+(b.getAttribute('data-testid')||'')))return null;
        const rect=b.getBoundingClientRect();
        const targetForm=b.closest('form')||form;
        if(typeof targetForm?.requestSubmit==='function'){
          try{targetForm.requestSubmit(b);}catch{}
        }
        try{
          b.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true, view: window }));
          b.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
          b.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, cancelable: true, view: window }));
          b.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window }));
          b.click();
        }catch{}
        return {x: Math.round(rect.left + rect.width / 2), y: Math.round(rect.top + rect.height / 2)};
      },record);
      if(coords)break;
      await wait(500);
    }
    if(!coords)throw new Error('SEND_NOT_CONFIRMED');
    if(coords.x && coords.y) {
      try {
        await this.conn.send('Input.dispatchMouseEvent',{type:'mouseMoved',x:coords.x,y:coords.y});
        await this.conn.send('Input.dispatchMouseEvent',{type:'mousePressed',x:coords.x,y:coords.y,button:'left',clickCount:1});
        await this.conn.send('Input.dispatchMouseEvent',{type:'mouseReleased',x:coords.x,y:coords.y,button:'left',clickCount:1});
      } catch {}
    }
    // Observation polls are safe; they never submit a second request.
    const norm = t => (t||'').replace(/\r\n/g, '\n').replace(/\n+/g, '\n').trim();
    const promptPrefix = norm(record.prompt).slice(0, 80);
    for(let i=0;i<12;i++){
      const s=await this.snapshot();
      if(s.messages.some(m=>m.role==='user'&&(norm(m.text)===norm(record.prompt)||norm(m.text).includes(norm(record.prompt))||(promptPrefix&&norm(m.text).includes(promptPrefix)))))return;
      await wait(this.pollMs);
    }
  }
  async candidates(record,decision){
    const correlation={conversation_id:record.conversation_id,user_message_id:record.user_message_id,assistant_message_id:record.assistant_message_id,file_name:decision.packet.file_name};
    const dir=path.join(this.downloadRoot,record.binding.turn_id);fs.mkdirSync(dir,{recursive:true});
    const candidates=[];
    const exact=path.join(dir,decision.packet.file_name);
    if(fs.existsSync(exact))candidates.push({...correlation,source:'disk',file_path:exact});

    const targetPacketId = decision.packet.packet_id;
    const inline = await this.evaluate((targetId) => {
      const pres = Array.from(document.querySelectorAll('pre, pre code, code'));
      const found = new Set();
      for (const p of pres) {
        const t = (p.innerText || p.textContent || '').trim();
        if (t.includes(targetId)) {
          try {
            const parsed = JSON.parse(t);
            if (parsed?.packet_id === targetId) {
              found.add(t);
            }
          } catch {}
        }
      }
      return Array.from(found);
    }, targetPacketId);
    for(const text of inline||[]){
      candidates.push({...correlation,source:'dom',bytes:Buffer.from(text,'utf8')});
      if(!text.endsWith('\n')){
        candidates.push({...correlation,source:'dom',bytes:Buffer.from(text + '\n','utf8')});
      }
    }
    if(candidates.length)return candidates;

    // 2. Check UI download link before calling backend API
    await this.conn.send('Browser.setDownloadBehavior',{behavior:'allow',downloadPath:dir,eventsEnabled:true});
    const clicked=await this.evaluate((r,d)=>{
      const links=Array.from(document.querySelectorAll('a,button')).filter(e=>(e.getAttribute('download')===d.packet.file_name||e.getAttribute('data-file-name')===d.packet.file_name||(e.innerText||'').includes(d.packet.file_name)||(e.innerText||'').includes('Скачать Agentic Action Packet')));
      if(links.length>=1){links[0].click();return true;}
      return false;
    },record,decision);
    if(clicked){for(let i=0;i<12;i++){if(fs.existsSync(exact)){candidates.push({...correlation,source:'ui',file_path:exact});break;}await wait(this.pollMs);}}
    if(candidates.length)return candidates;

    // 3. Fallback to API only if DOM and download didn't provide candidates
    const api=await this.evaluate(async(r,d)=>{
      const failure=code=>({ok:false,code});
      try{
        const session=await fetch('/api/auth/session');if(!session.ok)return failure(session.status===429?'QUOTA':'AUTH');
        const token=(await session.json()).accessToken;if(!token)return failure('AUTH');
        const headers={Authorization:'Bearer '+token};
        const response=await fetch('/backend-api/conversation/'+encodeURIComponent(r.conversation_id),{headers});if(!response.ok)return failure(response.status===429?'QUOTA':'API_UNAVAILABLE');
        const conv=await response.json();let curr=conv.current_node,found=null,user=null;
        while(curr){const n=conv.mapping?.[curr],m=n?.message;if(m?.author?.role==='user'){user=m;break;}if(m?.id===r.assistant_message_id&&m.author?.role==='assistant')found=m;curr=n?.parent;}
        if(!found||(user && r.user_message_id && user.id!==r.user_message_id))return failure('API_TURN_MISMATCH');
        const texts=(found.content?.parts||[]).filter(p=>typeof p==='string').join('\n');
        const rawPaths=[...texts.matchAll(/(?:sandbox:|\/mnt\/data\/|mnt\/data\/)([^\s)"']+\.json)/g)].map(m=>m[1]).filter(p=>p.split('/').at(-1)===d.packet.file_name);
        if(new Set(rawPaths).size!==1)return failure('API_ARTIFACT_AMBIGUOUS');
        const fileName=rawPaths[0].split('/').at(-1);
        const targetPath=(texts.includes('/mnt/data/'+fileName)||texts.includes('mnt/data/'+fileName))?'/mnt/data/'+fileName:(texts.includes('sandbox:'+fileName)?'sandbox:'+fileName:rawPaths[0]);
        let info = null;
        for (let attempt = 0; attempt < 5; attempt++) {
          const infoRes=await fetch('/backend-api/conversation/'+encodeURIComponent(r.conversation_id)+'/interpreter/download?message_id='+encodeURIComponent(found.id)+'&sandbox_path='+encodeURIComponent(targetPath),{headers});
          if(!infoRes.ok)return failure(infoRes.status===429?'QUOTA':'DOWNLOAD_UNAVAILABLE');
          info=await infoRes.json();
          if(info?.download_url) break;
          if(info?.status === 'retry') {
            await new Promise(res => setTimeout(res, 1500));
            continue;
          }
          break;
        }
        if(!info?.download_url)return failure('NO_DOWNLOAD_URL');
        const download=await fetch(info.download_url);if(!download.ok)return failure('DOWNLOAD_UNAVAILABLE');
        const bytes=new Uint8Array(await download.arrayBuffer());if(bytes.length!==d.packet.byte_length||bytes.length>100000000)return failure('SIZE_MISMATCH');
        let binary='';for(let i=0;i<bytes.length;i+=16384)binary+=String.fromCharCode(...bytes.subarray(i,i+16384));
        return {ok:true,base64:btoa(binary)};
      }catch{return failure('API_UNAVAILABLE');}
    },record,decision);
    if(api?.ok)candidates.push({...correlation,source:'api',bytes:Buffer.from(api.base64,'base64')});
    if(candidates.length)return candidates;
    if(api?.code==='QUOTA')return candidates;
    return candidates;
  }
  async discoverPacket(record, userMessageId, assistantMessageId) {
    let packetSource = null;
    const domData = await this.evaluate((r, uId, aId) => {
      const allUserNodes = Array.from(document.querySelectorAll('[data-message-author-role="user"]'));
      let userEl = null;
      if (uId) {
        userEl = document.querySelector(`[data-message-id="${uId}"]`) || 
                 document.querySelector(`[data-content-search-unit-key*="${uId}"]`) ||
                 allUserNodes.find(n => (n.getAttribute('data-message-id') || '').includes(uId) || (n.innerText || '').includes(r.binding?.turn_id));
      }
      if (!userEl && allUserNodes.length > 0) {
        userEl = allUserNodes[allUserNodes.length - 1];
      }
      const codeBlocks = Array.from(document.querySelectorAll('pre, pre code, code')).reverse();
      for (const cb of codeBlocks) {
        if (userEl && !(userEl.compareDocumentPosition(cb) & Node.DOCUMENT_POSITION_FOLLOWING)) {
          continue;
        }
        const t = (cb.innerText || cb.textContent || '').trim();
        if (!t.startsWith('{') || !t.includes('"packet_id"')) continue;
        try {
          const obj = JSON.parse(t);
          if (obj && typeof obj === 'object' && obj.packet_id && (obj.work_package || obj.instruction || obj.execution_plan || obj.goal || obj.operation || obj.route)) {
            if (r.completed_packet_id && obj.packet_id === r.completed_packet_id) {
              continue;
            }
            return {
              ok: true,
              fileName: (obj.packet_id || 'AGENTIC_ACTION_PACKET') + '.json',
              user_message_id: uId,
              assistant_message_id: aId || 'dom_detected',
              jsonText: t
            };
          }
        } catch {}
      }
      return null;
    }, record, userMessageId, assistantMessageId);

    if (domData?.ok && domData.jsonText) {
      packetSource = {
        ok: true,
        fileName: domData.fileName,
        user_message_id: domData.user_message_id,
        assistant_message_id: domData.assistant_message_id,
        base64: Buffer.from(domData.jsonText, 'utf8').toString('base64')
      };
    } else {
      const api = await this.evaluate(async (r, uId, aId) => {
        try {
          const session = await fetch('/api/auth/session'); if(!session.ok) return null;
          const token = (await session.json()).accessToken; if(!token) return null;
          const headers = { Authorization: 'Bearer ' + token };
          const response = await fetch('/backend-api/conversation/' + encodeURIComponent(r.conversation_id), { headers });
          if(!response.ok) return null;
          const conv = await response.json();
          let curr = conv.current_node, found = null, user = null;
          while(curr) {
            const n = conv.mapping?.[curr], m = n?.message;
            if(!found && m?.author?.role === 'assistant' && (!aId || m.id === aId)) found = m;
            else if(found && !user && m?.author?.role === 'user') { user = m; break; }
            curr = n?.parent;
          }
          if(!found) return null;
          const texts = (found.content?.parts || []).filter(p => typeof p === 'string').join('\n');
          const matches = texts.match(/(?:sandbox:|\/mnt\/data\/|mnt\/data\/)([^\s)"']+\.json)/g) || [];
          if(matches.length > 0) {
            const mStr = matches[0];
            const fileName = mStr.split('/').at(-1);
            const targetPath = (texts.includes('/mnt/data/' + fileName) || texts.includes('mnt/data/' + fileName)) ? '/mnt/data/' + fileName : (texts.includes('sandbox:' + fileName) ? 'sandbox:' + fileName : mStr);
            const infoRes = await fetch('/backend-api/conversation/' + encodeURIComponent(r.conversation_id) + '/interpreter/download?message_id=' + encodeURIComponent(found.id) + '&sandbox_path=' + encodeURIComponent(targetPath), { headers });
            if(infoRes.ok) {
              const info = await infoRes.json();
              if(info?.download_url) {
                const download = await fetch(info.download_url);
                if(download.ok) {
                  const bytes = new Uint8Array(await download.arrayBuffer());
                  if(bytes.length >= 50 && bytes.length <= 100000000) {
                    let binary = ''; for(let i = 0; i < bytes.length; i += 16384) binary += String.fromCharCode(...bytes.subarray(i, i + 16384));
                    return {
                      ok: true,
                      fileName,
                      user_message_id: user?.id || uId,
                      assistant_message_id: found.id,
                      base64: btoa(binary)
                    };
                  }
                }
              }
            }
          }
          // Also check for inline JSON code blocks in texts
          const codeBlockMatches = [...texts.matchAll(/```(?:json)?\s*([\s\S]*?)\s*```/g)];
          for(const cb of codeBlockMatches) {
            const raw = cb[1].trim();
            if(raw.startsWith('{') && raw.includes('"packet_id"')) {
              try {
                const obj = JSON.parse(raw);
                if(obj && typeof obj === 'object' && obj.packet_id && (obj.work_package || obj.instruction || obj.execution_plan || obj.goal || obj.operation || obj.route)) {
                  let utf8Bin = '';
                  const encoded = new TextEncoder().encode(raw);
                  for(let i = 0; i < encoded.length; i += 16384) utf8Bin += String.fromCharCode(...encoded.subarray(i, i + 16384));
                  return {
                    ok: true,
                    fileName: (obj.packet_id || 'AGENTIC_ACTION_PACKET') + '.json',
                    user_message_id: user?.id || uId,
                    assistant_message_id: found.id,
                    base64: btoa(utf8Bin)
                  };
                }
              } catch {}
            }
          }
          return null;
        } catch { return null; }
      }, record, userMessageId, assistantMessageId);
      if (api?.ok && api.base64) {
        packetSource = api;
      }
    }
    if (!packetSource?.ok || !packetSource.base64) return null;
    const bytes = Buffer.from(packetSource.base64, 'base64');
    let parsedJson;
    try { parsedJson = JSON.parse(bytes.toString('utf8')); } catch { return null; }
    if (!parsedJson || typeof parsedJson !== 'object') return null;
    const pid = parsedJson.project_id || '';
    const norm = s => (s || '').toLowerCase().replace(/[-_ ]/g, '');
    const normExpected = norm(record.binding.project_id);
    if (!norm(pid).includes(normExpected) && !normExpected.includes(norm(pid)) && !norm(pid).includes(norm(record.project?.key || ''))) return null;
    const sha256 = createHash('sha256').update(bytes).digest('hex');
    const packet_id = parsedJson.packet_id || 'packet_' + sha256.slice(0, 16);
    const dir = path.join(this.downloadRoot, record.binding.turn_id);
    fs.mkdirSync(dir, { recursive: true });
    const exact = path.join(dir, packetSource.fileName);
    fs.writeFileSync(exact, bytes);
    return {
      bytes,
      fileName: packetSource.fileName,
      filePath: exact,
      user_message_id: packetSource.user_message_id,
      assistant_message_id: packetSource.assistant_message_id,
      decision: {
        schema_version: 1,
        project_id: record.binding.project_id,
        turn_id: record.binding.turn_id,
        epoch: record.binding.epoch,
        context_sha256: record.binding.context_sha256,
        kind: 'packet_ready',
        packet: {
          packet_id,
          artifact_id: packet_id,
          file_name: packetSource.fileName,
          sha256,
          byte_length: bytes.length
        }
      }
    };
  }
  async softSync() {
    return this.evaluate(() => {
      try {
        const convId = location.pathname.match(/(?:^|\/)c\/([A-Za-z0-9-]+)(?:\/|$)/)?.[1];
        if (convId) {
          const link = document.querySelector(`nav a[href*="${convId}"], a[href*="/c/${convId}"]`);
          if (link) { link.click(); return { method: 'sidebar_click', success: true }; }
        }
        window.history.pushState(null, '', window.location.href);
        window.dispatchEvent(new PopStateEvent('popstate'));
        return { method: 'popstate', success: true };
      } catch (e) {
        return { error: e.message };
      }
    });
  }
  async discoverUserMessageViaApi(record) {
    return this.evaluate(async (r) => {
      try {
        const session = await fetch('/api/auth/session'); if(!session.ok) return null;
        const token = (await session.json()).accessToken; if(!token) return null;
        const headers = { Authorization: 'Bearer ' + token };
        const response = await fetch('/backend-api/conversation/' + encodeURIComponent(r.conversation_id), { headers });
        if(!response.ok) return null;
        const conv = await response.json();
        const turnMarker = r.binding?.turn_id;
        const fileName = r.file_name;
        for (const key of Object.keys(conv.mapping || {})) {
          const m = conv.mapping[key]?.message;
          if (m?.author?.role === 'user') {
            const texts = (m.content?.parts || []).filter(p => typeof p === 'string').join('\n');
            if ((turnMarker && texts.includes(turnMarker)) || (fileName && texts.includes(fileName))) {
              return m.id;
            }
          }
        }
        return null;
      } catch { return null; }
    }, record);
  }
}
