"""Wiring for the prepared Telegram bot. Existing command/menu bodies stay intact."""
import functools
import hashlib
import json
import math
import os
from pathlib import Path
import re
import time
import uuid
from telegram_durable import Service, EffectBlocked, ReconcileRequired, encode

_AUTO_OWNER = object()


def install(bot, *, database=None, effect_owner_factory=_AUTO_OWNER):
    if bot.get("_DURABLE_TELEGRAM_SERVICE") is not None:
        return bot["_DURABLE_TELEGRAM_SERVICE"]
    if effect_owner_factory is _AUTO_OWNER:
        try:
            from effect_owner import EffectOwner
            effect_owner_factory = EffectOwner
        except ImportError:
            effect_owner_factory = None
    from pipeline_runtime_state import database_path
    original_api = bot["api_request"]
    original_log = bot["log_event"]
    instance = "telegram:" + str(uuid.uuid4())

    def config():
        return bot["load_config"]().get("telegram", {})

    def log_event(message):
        # Legacy subprocess/HTTP diagnostics may contain prompt text or a token.
        # Durable records supply operation/update identity and stable reason codes.
        original_log("Telegram event; consult durable queue diagnostics")

    def handler(update):
        if "callback_query" in update:
            bot["handle_callback"](update["callback_query"])
        else:
            msg = update.get("message", {})
            text = msg.get("text", "")
            if isinstance(text, str) and text:
                # Telegram group commands commonly include @botname. The server
                # routes updates to this bot; preserve arguments and route body.
                text = re.sub(r"^(/[A-Za-z_]+)@[A-Za-z0-9_]+(?=\s|$)", r"\1", text)
                bot["handle_command"](str(msg["chat"]["id"]), text, msg.get("message_id"))

    def transport(method, payload):
        return original_api(method, redact(payload), timeout=5 if method == "answerCallbackQuery" else 15)

    def redact(payload):
        secrets = []
        def collect(value):
            if isinstance(value, dict):
                for key, item in value.items():
                    if isinstance(item, str) and item and re.search(r"token|secret|password|api.?key|credential|csrf", str(key), re.I):
                        secrets.append(item)
                    else:
                        collect(item)
            elif isinstance(value, list):
                for item in value:
                    collect(item)
        collect(bot["load_config"]())
        collect(bot.get("_CACHED_LS_ENV"))
        def scrub(value):
            if isinstance(value, str):
                for secret in secrets:
                    value = value.replace(secret, "[REDACTED]")
                return value
            if isinstance(value, dict):
                return {key: scrub(item) for key, item in value.items()}
            if isinstance(value, list):
                return [scrub(item) for item in value]
            return value
        return scrub(payload)

    def capture_context():
        return {"epoch": bot["runtime_snapshot"]().get("epoch")}

    service = Service(database or Path(bot["STATE_ROOT"]) / "TELEGRAM_QUEUE.sqlite3", config, handler, transport, context_provider=capture_context)
    bot["_DURABLE_TELEGRAM_SERVICE"] = service
    bot["log_event"] = log_event

    def api_request(method, payload=None, timeout=30):
        if method in {"sendMessage", "editMessageText"}:
            return service.notify(method, redact(payload))
        if method == "answerCallbackQuery" and service.context is not None:
            # Intake has already enqueued one ACK on a dedicated lane. Keep a
            # later handler's specific feedback as a normal durable message.
            if payload and payload.get("text"):
                update = service.context["update"]
                cb = update.get("callback_query", {})
                chat = cb.get("message", {}).get("chat", {}).get("id")
                if chat is not None:
                    service.notify("sendMessage", redact({"chat_id": str(chat), "text": payload["text"]}))
            return {"ok": True, "queued": True, "delivery_verified": False}
        return original_api(method, payload, timeout=timeout)

    bot["api_request"] = api_request

    original_pending = bot["get_pending_input"]
    def pending(chat_id):
        if service.context and service.context["lane"] in {"pause", "status"}:
            return None
        return original_pending(chat_id)
    bot["get_pending_input"] = pending

    original_dashboard = bot["build_dashboard_text"]
    def dashboard():
        stats = service.store.diagnostics()
        return original_dashboard() + "\n\n📬 <b>Очередь команд и доставки:</b>\n<code>" + encode(stats) + "</code>\nUNCERTAIN требует проверки получателя; автоматического повтора нет."
    bot["build_dashboard_text"] = dashboard

    original_owner_set = bot["runtime_owner_set"]
    def owner_set(enabled, *args, **kwargs):
        if service.context is None:
            raise EffectBlocked("AUTHENTICATED_JOB_REQUIRED")
        if enabled is False and kwargs.get("expected_epoch") is None:
            epoch = service.context["binding"].get("epoch")
            if type(epoch) is not int:
                raise EffectBlocked("EPOCH_REQUIRED")
            kwargs["expected_epoch"] = epoch
        return service.effect("owner_pause" if enabled else "owner_resume", {"enabled": enabled, "args": args, "kwargs": kwargs}, lambda: original_owner_set(enabled, *args, **kwargs))
    bot["runtime_owner_set"] = owner_set

    def make_gate(name, args, kwargs):
        def gate(operation_id, effect):
            if effect_owner_factory is None:
                raise EffectBlocked("EFFECT_OWNER_UNAVAILABLE")
            context = service.context
            epoch = context["binding"].get("epoch")
            if type(epoch) is not int:
                raise EffectBlocked("EPOCH_REQUIRED")
            is_message = name in {"send_to_companion", "send_to_orchestrator"}
            if name == "send_to_companion":
                raw_project = args[0] if args else kwargs.get("project_key")
                project = bot["normalize_project_key"](raw_project)
                if not project:
                    raise EffectBlocked("UNKNOWN_PROJECT")
            else:
                project = "orchestrator" if name == "send_to_orchestrator" else "runtime"
            if name == "send_to_companion":
                # The child browser dispatcher owns the final shared lease. An
                # outer DISPATCHED lease would block that child forever. Preserve
                # durable Telegram journaling and pass immutable intake identity.
                if bot["runtime_snapshot"]().get("epoch") != epoch:
                    raise EffectBlocked("STALE_EPOCH")
                delegation = {"operation_id": operation_id, "epoch": epoch, "project": project}
                context["delegated_companion"] = delegation
                try:
                    result = effect()
                    receipt = result.get("receipt") if isinstance(result, dict) else None
                    if (not isinstance(result, dict) or result.get("ok") is not True or not isinstance(receipt, dict)
                            or receipt.get("operation_id") != operation_id or type(receipt.get("epoch")) is not int or receipt["epoch"] != epoch
                            or receipt.get("state") != "SENT" or not isinstance(receipt.get("user_message_id"), str) or not receipt["user_message_id"]
                            or not isinstance(receipt.get("conversation_id"), str) or not receipt["conversation_id"]):
                        raise ReconcileRequired("CHILD_RECEIPT_UNVERIFIED")
                    return result
                finally:
                    context.pop("delegated_companion", None)
            if name == "execute_supervisor_ensure":
                state = bot["runtime_snapshot"]()
                if state.get("epoch") != epoch or state.get("is_standby") is not False:
                    raise EffectBlocked("STALE_EPOCH_OR_PAUSED")
                delegation = {"operation_id": operation_id, "epoch": epoch}
                context["delegated_supervisor"] = delegation
                try:
                    result = effect()
                    if not isinstance(result, dict) or result.get("success") is not True or not verified_services(result.get("report"), delegation):
                        raise ReconcileRequired("CHILD_HEALTH_UNVERIFIED")
                    return result
                finally:
                    context.pop("delegated_supervisor", None)
            try:
                owner = effect_owner_factory(database_path())
                lease = owner.acquire(owner=instance, project=project, turn="telegram:" + str(context["update_id"]), epoch=epoch,
                    context_hash=hashlib.sha256(encode({"name": name, "args": args, "kwargs": kwargs}).encode()).hexdigest(),
                    effect_kind="owner_message" if is_message else "owner_command", operation_id=operation_id, lease_seconds=150)
                owner.begin_effect(lease)
            except Exception as error:
                raise EffectBlocked("EFFECT_FENCED") from error
            try:
                result = effect()
                success_field = "success" if name == "execute_supervisor_ensure" else "ok"
                successful = isinstance(result, dict) and result.get(success_field) is True
                receipt={"update_id": context["update_id"], "meaning": "delivery acknowledgement only"}
                if name == "send_to_orchestrator":
                    native_receipt=result.get("receipt") if isinstance(result,dict) else None
                    expected_text=args[0] if args else kwargs.get("text")
                    from native_ack import ADAPTER
                    verified=(isinstance(native_receipt,dict) and native_receipt.get("ack_adapter")==ADAPTER
                        and native_receipt.get("api_accepted") is True and native_receipt.get("execution_observed") is False
                        and native_receipt.get("exactly_once_proven") is False and isinstance(expected_text,str)
                        and native_receipt.get("request_sha256")==hashlib.sha256(expected_text.strip().encode()).hexdigest()
                        and isinstance(native_receipt.get("response_sha256"),str) and re.fullmatch("[0-9a-f]{64}",native_receipt["response_sha256"]))
                    successful=successful and bool(verified)
                    if verified:receipt={**native_receipt,"update_id":context["update_id"],"meaning":"native_api_acceptance_only"}
                owner.ack(lease, outcome="SUCCEEDED" if successful else "UNCERTAIN", receipt=receipt)
                if not successful:
                    raise ReconcileRequired("EFFECT_RESULT_UNCERTAIN")
                return result
            except BaseException:
                try:
                    owner.ack(lease, outcome="UNCERTAIN")
                except Exception:
                    pass  # DISPATCHED remains in shared owner state after stale ACK.
                raise
        return gate

    def wrap_effect(name, shared):
        original = bot[name]
        @functools.wraps(original)
        def wrapped(*args, **kwargs):
            return service.effect(name, {"args": args, "kwargs": kwargs}, lambda: original(*args, **kwargs), gate=make_gate(name, args, kwargs) if shared else None)
        bot[name] = wrapped

    for name in ("send_to_companion", "send_to_orchestrator", "execute_supervisor_ensure", "execute_safe_sleep"):
        wrap_effect(name, True)
    for name in ("set_directive", "clear_directive", "set_orchestrator_config"):
        wrap_effect(name, False)
    return service


def send_companion(bot, project_key, message_text):
    """Known delegated browser command; shell-free argv and exact child receipt."""
    service = bot.get("_DURABLE_TELEGRAM_SERVICE")
    binding = service.context.get("delegated_companion") if service and service.context else None
    project = bot["normalize_project_key"](project_key)
    if not binding or project != binding["project"] or not isinstance(message_text, str) or not message_text.strip():
        raise EffectBlocked("DURABLE_DELEGATED_OWNER_COMMAND_REQUIRED")
    prompt = Path(bot["STATE_ROOT"]) / ("telegram-owner-" + uuid.uuid4().hex + ".txt")
    try:
        prompt.parent.mkdir(parents=True, exist_ok=True)
        with prompt.open("x", encoding="utf-8") as stream:
            stream.write(message_text.strip())
        args = [str(bot["NODE_EXE"]), str(bot["COMPANION_BRIDGE_JS"]), "send", project, "--file", str(prompt),
                "--expected-epoch", str(binding["epoch"]), "--operation-id", binding["operation_id"]]
        result = bot["subprocess"].run(args, capture_output=True, text=True, timeout=40, creationflags=bot["CREATE_NO_WINDOW"])
        if result.returncode != 0:
            raise ReconcileRequired("CHILD_SEND_RESULT_UNCERTAIN")
        try:
            # Bridge diagnostics may precede the final machine result.
            response = json.loads(result.stdout.strip().splitlines()[-1])
            record = response["record"]
            native_binding = record["binding"]
            if response.get("ok") is not True or response.get("state") != "SENT" or response.get("projectKey") != project:
                raise ValueError("unverified child")
            receipt = {"operation_id": record.get("owner_operation_id"), "epoch": native_binding.get("epoch"),
                       "state": record.get("state"), "user_message_id": record.get("user_message_id"), "conversation_id": record.get("conversation_id")}
            return {"ok": True, "project": project, "receipt": receipt}
        except (ValueError, TypeError, KeyError, IndexError) as error:
            raise ReconcileRequired("CHILD_RECEIPT_UNVERIFIED") from error
    finally:
        prompt.unlink(missing_ok=True)


def verified_services(report, binding):
    required = ["companion_bridge", "process_guard", "telegram_bot", "ide"]
    if (not isinstance(report, dict) or type(report.get("schema_version")) is not int or report["schema_version"] != 1
            or report.get("operation_id") != binding["operation_id"] or type(report.get("epoch")) is not int or report["epoch"] != binding["epoch"]
            or report.get("success") is not True or report.get("required_services") != required or not isinstance(report.get("services"), dict)):
        return False
    retired = report["services"].get("action_bridge")
    if not isinstance(retired, dict) or retired.get("managed") is not False:
        return False
    for name in required:
        service = report["services"].get(name)
        if not isinstance(service, dict) or any(service.get(field) is not True for field in ("identity_verified", "alive", "healthy")):
            return False
        identity = service.get("process_identity")
        if (not isinstance(identity, dict) or type(identity.get("pid")) is not int or identity["pid"] < 1
                or type(identity.get("create_time")) not in (int, float) or not math.isfinite(identity["create_time"]) or identity["create_time"] <= 0
                or not isinstance(identity.get("executable"), str) or not identity["executable"]
                or not isinstance(identity.get("command_sha256"), str) or not re.fullmatch("[a-f0-9]{64}", identity["command_sha256"])):
            return False
    return True


def ensure_supervisor(bot):
    """Supervisor children own service-start effects; report must prove health."""
    service = bot.get("_DURABLE_TELEGRAM_SERVICE")
    binding = service.context.get("delegated_supervisor") if service and service.context else None
    if not binding:
        raise EffectBlocked("DURABLE_DELEGATED_OWNER_COMMAND_REQUIRED")
    args = [str(bot["PYTHON_EXE"]), str(bot["SUPERVISOR_PY"]), "--ensure", "--expected-epoch", str(binding["epoch"]), "--operation-id", binding["operation_id"]]
    result = bot["subprocess"].run(args, capture_output=True, text=True, timeout=60, creationflags=bot["CREATE_NO_WINDOW"])
    if result.returncode != 0:
        raise ReconcileRequired("SUPERVISOR_RESULT_UNCERTAIN")
    try:
        report = json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError, TypeError, IndexError) as error:
        raise ReconcileRequired("CHILD_HEALTH_UNVERIFIED") from error
    if not verified_services(report, binding):
        raise ReconcileRequired("CHILD_HEALTH_UNVERIFIED")
    return {"success": True, "report": report, "output": "Подтверждены идентичность, работа и health всех обязательных служб."}


def run_polling(bot):
    token, chat_id = bot["get_telegram_creds"]()
    if not token or not chat_id:
        raise SystemExit("telegram.botToken and telegram.chatId are required")
    service = install(bot)
    bot["api_request"]("deleteWebhook", {"drop_pending_updates": False})
    bot["register_bot_commands"]()
    service.start()
    backoff = 2.0
    try:
        while True:
            bot["write_heartbeat"]()
            try:
                result = bot["api_request"]("getUpdates", {"offset": service.offset, "timeout": 5, "allowed_updates": ["message", "callback_query"]}, timeout=15)
                if result.get("ok") is not True:
                    time.sleep(backoff)
                    backoff = min(20.0, backoff * 1.5)
                    continue
                updates = result.get("result")
                if not isinstance(updates, list):
                    raise ValueError("INVALID_UPDATES")
                for update in updates:
                    service.submit(update)  # commit before next getUpdates offset
                backoff = 2.0
            except (ValueError, OSError):
                bot["log_event"]("POLL_INTAKE_FAILED")
                time.sleep(2)
    finally:
        service.close()
