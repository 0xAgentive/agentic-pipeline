"""13-key portable configuration; no arbitrary profile search or shell expansion."""
import json
import os
from pathlib import Path, PureWindowsPath
import shutil
import sys

KEYS = {'AGENTIC_ACTION_BRIDGE_SCRIPT','AGENTIC_DOWNLOADS_DIR','AGENTIC_HANDOFF_ROOT','AGENTIC_NODE','AGENTIC_ORCHESTRATOR_SEARCH_ROOT','AGENTIC_PIPELINE_ROOT','AGENTIC_PROJECT_REGISTRY','AGENTIC_PYTHON','AGENTIC_PYTHONW','AGENTIC_RUNTIME_SCRIPTS_DIR','AGENTIC_STATE_ROOT','ANTIGRAVITY_DATA_ROOT','ANTIGRAVITY_INSTALL_ROOT'}


def configuration():
    source = os.environ.get('AGENTIC_RUNTIME_CONFIG')
    data = json.loads(Path(source).read_text(encoding='utf-8-sig')) if source else {}
    if not isinstance(data, dict) or data.get('schema_version',1) != 1 or set(data) - KEYS - {'schema_version'}:
        raise ValueError('INVALID_RUNTIME_CONFIG')
    return data


def runtime_path(key, suffix='', *, config=None, environ=None, home=None, runtime_root=None):
    if key not in KEYS:
        raise ValueError('UNKNOWN_RUNTIME_PATH_KEY')
    config = configuration() if config is None else config
    env = os.environ if environ is None else environ
    home = Path.home() if home is None else Path(home)
    adjacent = Path(__file__).resolve().parent
    inferred = adjacent.parent.parent if adjacent.name=='bridge' and adjacent.parent.name=='scripts' else adjacent.parent
    runtime = Path(runtime_root) if runtime_root is not None else inferred
    def root(name, default):
        value = env.get(name, config.get(name, str(default)))
        if not isinstance(value, str) or not value.strip() or '\x00' in value or not (Path(value).is_absolute() or PureWindowsPath(value).is_absolute()):
            raise ValueError('INVALID_RUNTIME_PATH:' + name)
        return value
    pipeline = root('AGENTIC_PIPELINE_ROOT', runtime)
    scripts_default = adjacent.parent if adjacent.name=='bridge' and adjacent.parent.name=='scripts' else adjacent
    scripts = root('AGENTIC_RUNTIME_SCRIPTS_DIR', scripts_default)
    defaults = {
        'AGENTIC_PIPELINE_ROOT': pipeline,
        'AGENTIC_RUNTIME_SCRIPTS_DIR': scripts,
        'AGENTIC_STATE_ROOT': home / '.agentic-pipeline' / 'action-bridge',
        'ANTIGRAVITY_DATA_ROOT': home / '.gemini' / 'antigravity',
        'ANTIGRAVITY_INSTALL_ROOT': Path(env.get('LOCALAPPDATA', str(home / 'AppData' / 'Local'))) / 'Programs' / 'Antigravity',
        'AGENTIC_DOWNLOADS_DIR': home / 'Downloads',
        'AGENTIC_HANDOFF_ROOT': Path(pipeline) / 'handoffs',
        'AGENTIC_ORCHESTRATOR_SEARCH_ROOT': pipeline,
        'AGENTIC_PROJECT_REGISTRY': home / '.agentic-pipeline' / 'project-registry.json',
        'AGENTIC_ACTION_BRIDGE_SCRIPT': Path(scripts) / 'bridge' / 'companion_action_bridge.py',
        'AGENTIC_PYTHON': sys.executable,
        'AGENTIC_PYTHONW': str(Path(sys.executable).with_name('pythonw.exe')) if os.name=='nt' else sys.executable,
        'AGENTIC_NODE': shutil.which('node') or str(Path(scripts) / 'MISSING_NODE_EXECUTABLE'),
    }
    value = root(key, defaults[key])
    if suffix and (Path(suffix).is_absolute() or PureWindowsPath(suffix).is_absolute() or '..' in suffix.replace('\\','/').split('/')):
        raise ValueError('INVALID_RUNTIME_PATH_SUFFIX')
    if PureWindowsPath(value).is_absolute() and not Path(value).is_absolute():
        return str(PureWindowsPath(value).joinpath(*suffix.replace('\\','/').split('/'))) if suffix else value
    return str(Path(value).joinpath(*suffix.replace('\\','/').split('/'))) if suffix else value


def discovery():
    """Existence is reported independently from running/healthy/native-capable."""
    return {key:{'path':runtime_path(key), 'exists':Path(runtime_path(key)).exists()} for key in sorted(KEYS)}


if __name__=='__main__':
    print(json.dumps(discovery(),ensure_ascii=False,indent=2))
