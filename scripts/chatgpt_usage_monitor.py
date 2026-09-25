import json
import urllib.request
import struct
import socket
import base64
import time
import os
from pathlib import Path
from typing import Optional, Dict, Any

STATE_FILE = Path(r"C:\ChatGPT\usage_limit_state.json")
CDP_URL = "http://127.0.0.1:9222"

def load_saved_state() -> Dict[str, Any]:
    if STATE_FILE.is_file():
        try:
            return json.loads(STATE_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {
        "percent": 0,
        "remainingText": "Остается 0%",
        "resetText": "",
        "resetsAvailable": None,
        "lastCheckedAt": None,
        "lastAlertAt": None,
        "lastAlertReason": None
    }

def save_state(state: Dict[str, Any]) -> None:
    try:
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding="utf-8")
        tmp.replace(STATE_FILE)
    except Exception as e:
        print(f"[usage_monitor] Error saving state: {e}")

def _eval_in_target(ws_url: str, js_code: str) -> Optional[Any]:
    path = "/" + ws_url.split("/", 3)[3]
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5.0)
    try:
        s.connect(("127.0.0.1", 9222))
        ws_key = base64.b64encode(b"0123456789abcdef").decode()
        handshake = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: 127.0.0.1:9222\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {ws_key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n"
        )
        s.sendall(handshake.encode())
        resp = s.recv(4096)
        if b"101" not in resp:
            return None

        def send_frame(msg):
            data = msg.encode("utf-8")
            length = len(data)
            mask = b"\x12\x34\x56\x78"
            masked = bytes([b ^ mask[i % 4] for i, b in enumerate(data)])
            header = bytearray([0x81])
            if length <= 125: header.append(0x80 | length)
            elif length <= 65535:
                header.append(0x80 | 126)
                header.extend(struct.pack("!H", length))
            else:
                header.append(0x80 | 127)
                header.extend(struct.pack("!Q", length))
            header.extend(mask)
            header.extend(masked)
            s.sendall(header)

        def recv_frame():
            hdr = s.recv(2)
            if not hdr: return None
            b1, b2 = hdr[0], hdr[1]
            length = b2 & 0x7F
            if length == 126: length = struct.unpack("!H", s.recv(2))[0]
            elif length == 127: length = struct.unpack("!Q", s.recv(8))[0]
            is_masked = bool(b2 & 0x80)
            if is_masked: mask = s.recv(4)
            data = bytearray()
            while len(data) < length:
                chunk = s.recv(length - len(data))
                if not chunk: break
                data.extend(chunk)
            if is_masked: data = bytes([b ^ mask[i % 4] for i, b in enumerate(data)])
            return data.decode("utf-8", errors="replace")

        msg = json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": js_code, "returnByValue": True}})
        send_frame(msg)

        for _ in range(5):
            res = recv_frame()
            if res:
                parsed = json.loads(res)
                if parsed.get("id") == 1:
                    return parsed.get("result", {}).get("result", {}).get("value")
    except Exception as e:
        print(f"[usage_monitor] WS Error: {e}")
    finally:
        s.close()
    return None

EXTRACTOR_JS = """
(() => {
  let percent = null;
  let remainingText = '';
  let resetText = '';
  let resetsAvailable = null;

  const progress = document.querySelector('progress');
  if (progress) {
    const val = progress.getAttribute('value');
    if (val !== null) percent = parseFloat(val);
  }

  const bodyText = document.body ? document.body.innerText : '';
  const matchRemaining = bodyText.match(/Остается\\s+(\\d+)\\s*%/i) || bodyText.match(/(\\d+)\\s*%\\s*remaining/i) || bodyText.match(/(\\d+)\\s*%\\s*left/i);
  if (matchRemaining) {
    percent = parseInt(matchRemaining[1], 10);
    remainingText = matchRemaining[0];
  }

  const matchReset = bodyText.match(/Resets\\s+in\\s+[^\\n]+/i) || bodyText.match(/Сброс\\s+через\\s+[^\\n]+/i);
  if (matchReset) {
    resetText = matchReset[0];
  }

  const resetSection = bodyText.match(/Сброс лимита использования[\\s\\S]*?Доступно\\s*\\n*\\s*(\\d+)/i);
  if (resetSection) {
    resetsAvailable = parseInt(resetSection[1], 10);
  }

  return {
    percent,
    remainingText: remainingText || (percent !== null ? `Остается ${percent}%` : ''),
    resetText,
    resetsAvailable
  };
})()
"""

def extract_live_usage() -> Optional[Dict[str, Any]]:
    """Extracts live usage from open tab or opens temporary background tab via CDP."""
    try:
        req = urllib.request.urlopen(f"{CDP_URL}/json/list", timeout=3)
        targets = json.loads(req.read().decode("utf-8"))
    except Exception:
        return None # Browser is closed or CDP unreachable

    # 1. Check if a settings/usage tab is already open
    usage_target = next((t for t in targets if "settings/usage" in t.get("url", "")), None)
    
    if usage_target:
        res = _eval_in_target(usage_target["webSocketDebuggerUrl"], EXTRACTOR_JS)
        if res and res.get("percent") is not None:
            return res

    # 2. If no tab is open, open a quiet background tab via CDP, extract and close
    created_id = None
    try:
        new_req = urllib.request.Request(f"{CDP_URL}/json/new?https://chatgpt.com/settings/usage?tab=overview", method="PUT")
        new_target = json.loads(urllib.request.urlopen(new_req, timeout=5).read().decode())
        created_id = new_target["id"]
        ws_url = new_target["webSocketDebuggerUrl"]

        # Wait 3.5 seconds for React to mount and populate DOM
        time.sleep(3.5)

        res = _eval_in_target(ws_url, EXTRACTOR_JS)
        return res
    except Exception as e:
        print(f"[usage_monitor] Background check error: {e}")
        return None
    finally:
        if created_id:
            try:
                urllib.request.urlopen(f"{CDP_URL}/json/close/{created_id}", timeout=3)
            except Exception:
                pass

def check_and_notify_if_needed(send_tg_fn=None, chat_id=None) -> Dict[str, Any]:
    """
    Checks usage, compares against saved state, and sends notification if:
    1. A manual reset was consumed by someone (resetsAvailable decreased, e.g. 1 -> 0) [CRITICAL ALERT]
    2. Limit recovered from 0 to >0% or increased (cur_percent > prev_percent)
    3. New resets were granted (resetsAvailable increased)
    """
    state = load_saved_state()
    prev_percent = state.get("percent", 0)
    prev_resets = state.get("resetsAvailable")
    
    live = extract_live_usage()
    if not live or live.get("percent") is None:
        return {"status": "unavailable", "state": state}

    cur_percent = live["percent"]
    cur_resets = live.get("resetsAvailable")
    cur_reset_text = live.get("resetText", "")
    cur_remaining_text = live.get("remainingText", f"Остается {cur_percent}%")
    now_iso = time.strftime("%Y-%m-%d %H:%M:%S MSK")

    # Determine event triggers
    is_manual_reset = False
    is_natural_recovery = False
    is_resets_granted = False

    if prev_resets is not None and cur_resets is not None and cur_resets < prev_resets:
        # Indisputable: A manual reset was consumed by someone!
        is_manual_reset = True
    elif (prev_percent == 0 and cur_percent > 0) or (cur_percent > prev_percent):
        # Limit increased while resets were not consumed
        is_natural_recovery = True
    elif prev_resets is not None and cur_resets is not None and cur_resets > prev_resets:
        is_resets_granted = True

    # Update state
    state["percent"] = cur_percent
    state["remainingText"] = cur_remaining_text
    state["resetText"] = cur_reset_text
    state["resetsAvailable"] = cur_resets
    state["lastCheckedAt"] = now_iso

    if is_manual_reset:
        state["lastAlertAt"] = now_iso
        state["lastAlertReason"] = "manual_reset_consumed"
        save_state(state)

        msg = (
            f"🚨⚡️ <b>ВНИМАНИЕ! КТО-ТО СБРОСИЛ ЛИМИТ CHATGPT!</b> ⚡️🚨\n\n"
            f"👤 <b>Событие:</b> Другой участник аккаунта использовал ручной сброс лимита!\n"
            f"📉 <b>Счётчик сбросов:</b> было <code>{prev_resets}</code> ➔ стало <code>{cur_resets}</code> <i>(сброс потрачен!)</i>\n"
            f"📈 <b>Восстановленный лимит:</b> <code>{cur_percent}%</code> ({cur_remaining_text})\n"
            f"⏳ <b>Следующий сброс через:</b> <code>{cur_reset_text or '—'}</code>\n"
            f"🕒 <b>Время фиксации:</b> {now_iso}\n\n"
            f"⚠️ <b>Срочно используйте квоту:</b> Другие пользователи могут быстро израсходовать восстановленный лимит своими запросами!"
        )
        if send_tg_fn and chat_id:
            send_tg_fn(chat_id, msg)
        return {
            "status": "alert_triggered",
            "reason": "manual_reset",
            "previous_percent": prev_percent,
            "current_percent": cur_percent,
            "previous_resets": prev_resets,
            "current_resets": cur_resets,
            "state": state,
            "message": msg
        }

    elif is_natural_recovery:
        state["lastAlertAt"] = now_iso
        state["lastAlertReason"] = "natural_recovery"
        save_state(state)

        msg = (
            f"🎉 <b>ЛИМИТ CHATGPT ВОССТАНОВЛЕН ПО РАСПИСАНИЮ</b>\n\n"
            f"📈 <b>Доступно:</b> <code>{cur_percent}%</code> <i>(было: {prev_percent}%)</i>\n"
            f"🔄 <b>Ручные сбросы не тронуты:</b> доступно <code>{cur_resets if cur_resets is not None else '—'}</code>\n"
            f"⏳ <b>Следующий сброс через:</b> <code>{cur_reset_text or '—'}</code>\n"
            f"🕒 <b>Время фиксации:</b> {now_iso}\n\n"
            f"🚀 <i>Квота восстановлена по таймеру OpenAI, можно продолжать работу!</i>"
        )
        if send_tg_fn and chat_id:
            send_tg_fn(chat_id, msg)
        return {
            "status": "alert_triggered",
            "reason": "natural_recovery",
            "previous_percent": prev_percent,
            "current_percent": cur_percent,
            "state": state,
            "message": msg
        }

    elif is_resets_granted:
        state["lastAlertAt"] = now_iso
        state["lastAlertReason"] = "resets_granted"
        save_state(state)

        msg = (
            f"🎁 <b>НАЧИСЛЕН НОВЫЙ РУЧНОЙ СБРОС ЛИМИТА!</b>\n\n"
            f"🔄 <b>Доступно сбросов:</b> было <code>{prev_resets}</code> ➔ стало <code>{cur_resets}</code>\n"
            f"📈 <b>Текущий лимит:</b> <code>{cur_percent}%</code>\n"
            f"🕒 <b>Время:</b> {now_iso}"
        )
        if send_tg_fn and chat_id:
            send_tg_fn(chat_id, msg)
        return {
            "status": "alert_triggered",
            "reason": "resets_granted",
            "state": state,
            "message": msg
        }

    else:
        save_state(state)
        return {"status": "no_change", "current": cur_percent, "state": state}

if __name__ == "__main__":
    print("Testing extract_live_usage()...")
    res = extract_live_usage()
    print("Result:", json.dumps(res, indent=2, ensure_ascii=False))
