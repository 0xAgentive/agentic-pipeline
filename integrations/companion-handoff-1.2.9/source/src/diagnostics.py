#!/usr/bin/env python3
"""
diagnostics.py - Error Codes and Diagnostics for Auto Context Handoff v4.3.4.

Provides structured error codes, diagnostic collection, and plain-language
owner-facing reason generation.
"""

import os
import json
import traceback
from datetime import datetime, timezone


# ============================================================
# Error code registry (spec section 38)
# ============================================================

ERROR_CODES = {
    "INPUT_CONTEXT_INVALID": "Входные данные контекста недействительны",
    "TRANSCRIPT_UNAVAILABLE": "Транскрипт недоступен",
    "EXTERNAL_EDIT_ROOT_NOT_CAPTURED": "Внешний корень редактирования не захвачен",
    "PROJECT_ROOT_AMBIGUOUS": "Корень проекта неоднозначен",
    "GIT_STATE_UNKNOWN": "Состояние Git неизвестно",
    "AUTHORITY_AMBIGUOUS": "Авторитетный файл неоднозначен",
    "PRIMARY_ARTIFACT_MISSING": "Основной артефакт отсутствует",
    "PRIMARY_ARTIFACT_UNVERIFIED": "Основной артефакт не верифицирован",
    "PRIMARY_ARTIFACT_AMBIGUOUS": "Несколько кандидатов на основной артефакт",
    "AUDIT_REQUIRED_MISSING": "Требуемый аудит отсутствует",
    "AUDIT_FAILED": "Аудит не пройден",
    "RESULT_HEAD_MISMATCH": "HEAD результата не совпадает",
    "RUNTIME_TARGET_UNKNOWN": "Целевая версия runtime неизвестна",
    "HANDSHAKE_STALE": "Handshake устарел",
    "RUNTIME_ALIGNMENT_REQUIRED": "Требуется выравнивание runtime",
    "ZIP_TRAVERSAL": "Обнаружен обход пути в ZIP",
    "ZIP_DUPLICATE_MEMBER": "Дублирование файлов в ZIP",
    "ZIP_BOMB_RISK": "Подозрение на ZIP-бомбу",
    "PRIVACY_BLOCK": "Файл заблокирован политикой приватности",
    "FINAL_ZIP_VALIDATION_FAILED": "Финальная валидация ZIP не пройдена",
    "ATOMIC_SWAP_FAILED": "Атомарная замена файла не удалась",
    "UX_DELIVERY_FAILED": "Доставка UX не удалась",
}


def get_owner_reason(error_code: str) -> str:
    """Return plain-language Russian reason for an error code."""
    return ERROR_CODES.get(error_code, error_code)


def get_owner_reasons(reason_codes: list) -> str:
    """Return combined plain-language reasons for multiple error codes."""
    reasons = [get_owner_reason(c) for c in reason_codes if c]
    return "; ".join(reasons) if reasons else "Нет ошибок"


class DiagnosticsCollector:
    """Collects diagnostics during export for internal troubleshooting.

    Owner never sees the full diagnostics. Only plain-language reasons
    are exposed via CONTEXT_READINESS.json.
    """

    def __init__(self):
        self.entries = []
        self.warnings = []
        self.errors = []
        self.timing = {}
        self._start_time = datetime.now(timezone.utc)

    def info(self, component: str, message: str, data: dict = None):
        """Record an informational diagnostic entry."""
        self.entries.append({
            "level": "INFO",
            "component": component,
            "message": message,
            "data": data,
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        })

    def warn(self, component: str, code: str, message: str, data: dict = None):
        """Record a warning diagnostic entry."""
        entry = {
            "level": "WARN",
            "component": component,
            "code": code,
            "message": message,
            "data": data,
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        }
        self.entries.append(entry)
        self.warnings.append(entry)

    def error(self, component: str, code: str, message: str, data: dict = None):
        """Record an error diagnostic entry."""
        entry = {
            "level": "ERROR",
            "component": component,
            "code": code,
            "message": message,
            "data": data,
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        }
        self.entries.append(entry)
        self.errors.append(entry)

    def exception(self, component: str, code: str, exc: Exception):
        """Record an exception as an error diagnostic."""
        self.error(component, code, str(exc), {
            "type": type(exc).__name__,
            "traceback": traceback.format_exc(),
        })

    def start_timer(self, label: str):
        """Start a named timer for performance measurement."""
        self.timing[label] = {
            "start_utc": datetime.now(timezone.utc).isoformat(),
            "end_utc": None,
            "duration_ms": None,
        }

    def stop_timer(self, label: str):
        """Stop a named timer and record duration."""
        if label in self.timing:
            now = datetime.now(timezone.utc)
            start_str = self.timing[label]["start_utc"]
            start = datetime.fromisoformat(start_str)
            duration_ms = int((now - start).total_seconds() * 1000)
            self.timing[label]["end_utc"] = now.isoformat()
            self.timing[label]["duration_ms"] = duration_ms

    def has_errors(self) -> bool:
        """Check if any error-level diagnostics were recorded."""
        return len(self.errors) > 0

    def get_error_codes(self) -> list:
        """Return list of unique error codes."""
        return list(set(e["code"] for e in self.errors if e.get("code")))

    def get_warning_codes(self) -> list:
        """Return list of unique warning codes."""
        return list(set(w["code"] for w in self.warnings if w.get("code")))

    def to_dict(self) -> dict:
        """Serialize diagnostics to dictionary for internal storage."""
        total_ms = int((datetime.now(timezone.utc) - self._start_time).total_seconds() * 1000)
        return {
            "version": "4.3.4",
            "total_duration_ms": total_ms,
            "entry_count": len(self.entries),
            "warning_count": len(self.warnings),
            "error_count": len(self.errors),
            "error_codes": self.get_error_codes(),
            "warning_codes": self.get_warning_codes(),
            "timing": self.timing,
            "entries": self.entries,
        }

    def to_json_bytes(self) -> bytes:
        """Serialize diagnostics to UTF-8 JSON bytes."""
        return json.dumps(self.to_dict(), indent=2, ensure_ascii=False).encode("utf-8")


def log_to_file(logs_dir: str, error_code: str, message: str, filename: str = "export_error.log"):
    """Append a timestamped error entry to a log file."""
    os.makedirs(logs_dir, exist_ok=True)
    log_path = os.path.join(logs_dir, filename)
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(f"[{timestamp}] [{error_code}] {message}\n")
    except Exception:
        pass
