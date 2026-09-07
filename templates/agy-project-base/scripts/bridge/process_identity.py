"""Read-only process identity and health. No PID-only acceptance; no termination."""
import hashlib
import json
import os
from pathlib import Path
import time


def fingerprint(process):
    """psutil.Process-compatible input, injectable in tests. Never expose argv secrets."""
    with process.oneshot():
        pid=process.pid;created=process.create_time();argv=process.cmdline();executable=process.exe()
        alive=process.is_running()
    if type(pid) is not int or not isinstance(created,(int,float)) or created<=0 or not argv or not executable or not alive:
        raise ValueError('PROCESS_IDENTITY_UNAVAILABLE')
    return {'pid':pid,'create_time':created,'executable':executable,'command_sha256':hashlib.sha256(json.dumps(argv,ensure_ascii=False,separators=(',',':')).encode()).hexdigest()}


def identity_matches(expected,observed):
    return isinstance(expected,dict) and isinstance(observed,dict) and all(expected.get(k)==observed.get(k) for k in ('pid','create_time','executable','command_sha256')) and bool(expected.get('command_sha256'))


def runtime_instance(process):
    item=fingerprint(process)
    return str(item['pid'])+':'+str(item['create_time'])+':'+item['command_sha256']


def health(expected,observed,heartbeat=None,*,now=None,max_age=60):
    now=time.time() if now is None else now
    matched=identity_matches(expected,observed)
    if not matched:return {'alive':False,'identity_verified':False,'healthy':False,'reason':'PROCESS_IDENTITY_MISMATCH'}
    if not isinstance(heartbeat,dict):return {'alive':True,'identity_verified':True,'healthy':None,'reason':'HEARTBEAT_UNAVAILABLE'}
    if not identity_matches(observed,heartbeat.get('process_identity')):return {'alive':True,'identity_verified':True,'healthy':None,'reason':'HEARTBEAT_IDENTITY_MISMATCH'}
    age=now-heartbeat.get('epoch',0)
    return {'alive':True,'identity_verified':True,'healthy':0<=age<=max_age,'reason':'HEARTBEAT_FRESH' if 0<=age<=max_age else 'HEARTBEAT_STALE','heartbeat_age_sec':age}


def command_matches(argv,script,required=()):
    normalize=lambda p:str(p).replace('\\','/').casefold() if os.name=='nt' or ':' in str(p) else str(Path(p).resolve())
    return any(normalize(arg)==normalize(script) for arg in argv[1:]) and all(arg in argv for arg in required)


def current_identity():
    import psutil
    return fingerprint(psutil.Process(os.getpid()))


def _namespace_pid(root):
    if os.readlink(root/'ns/pid')!=os.readlink('/proc/self/ns/pid'):raise ValueError('PROCESS_NAMESPACE_MISMATCH')
    status=(root/'status').read_text()
    values=next(line.split()[1:] for line in status.splitlines() if line.startswith('NSpid:'))
    return int(values[-1])


def _proc_root(pid):
    direct=Path('/proc')/str(pid)
    try:
        if _namespace_pid(direct)==pid:return direct
    except (OSError,ValueError,StopIteration):pass
    matches=[]
    for root in Path('/proc').iterdir():
        if root.name.isdigit():
            try:
                if _namespace_pid(root)==pid:matches.append(root)
            except (OSError,ValueError,StopIteration):pass
    if len(matches)!=1:raise ProcessLookupError('PROCESS_NAMESPACE_IDENTITY_UNAVAILABLE')
    return matches[0]


def _linux_details(pid):
    """Observe kernel procfs. Raw argv is internal and never returned by observe_pid."""
    if type(pid) is not int or pid <= 0:raise ValueError('PROCESS_IDENTITY_UNAVAILABLE')
    root=_proc_root(pid)
    def stat():
        text=(root/'stat').read_text();return text[text.rfind(')')+2:].split()
    before=stat()
    argv=[os.fsdecode(x) for x in (root/'cmdline').read_bytes().split(b'\0') if x]
    executable=os.readlink(root/'exe')
    after=stat()
    if before[19]!=after[19] or after[0] in {'Z','X'} or not argv or not executable:
        raise ValueError('PROCESS_IDENTITY_UNAVAILABLE')
    boot=next(int(line.split()[1]) for line in Path('/proc/stat').read_text().splitlines() if line.startswith('btime '))
    created=boot+int(after[19])/os.sysconf('SC_CLK_TCK')
    identity={'pid':pid,'create_time':created,'executable':executable,'command_sha256':hashlib.sha256(json.dumps(argv,ensure_ascii=False,separators=(',',':')).encode()).hexdigest()}
    parent_root=Path('/proc')/after[1]
    try:parent=_namespace_pid(parent_root)
    except (OSError,ValueError):parent=0
    return identity,argv,parent


def process_details(pid):
    try:
        import psutil
    except ImportError:
        if os.name=='posix' and Path('/proc/self/stat').is_file():return _linux_details(pid)
        raise ValueError('PROCESS_PROVIDER_UNAVAILABLE')
    process=psutil.Process(pid)
    first=fingerprint(process);argv=process.cmdline();parent=process.ppid();second=fingerprint(process)
    if not identity_matches(first,second):raise ValueError('PROCESS_CHANGED_DURING_OBSERVATION')
    return second,argv,parent


def observe_pid(pid):
    return process_details(pid)[0]


def instance_from_identity(item):
    if not identity_matches(item,item):raise ValueError('PROCESS_IDENTITY_UNAVAILABLE')
    return str(item['pid'])+':'+str(item['create_time'])+':'+item['command_sha256']


def observed_processes():
    try:
        import psutil
        pids=psutil.pids()
    except ImportError:
        if os.name!='posix' or not Path('/proc/self/stat').is_file():raise ValueError('PROCESS_PROVIDER_UNAVAILABLE')
        pids=[]
        for root in Path('/proc').iterdir():
            if root.name.isdigit():
                try:pids.append(_namespace_pid(root))
                except (OSError,ValueError,StopIteration):pass
    for pid in pids:
        try:yield process_details(pid)
        except Exception:continue
