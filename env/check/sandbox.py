#!/usr/bin/env python3
"""Probes of the Linux sandbox that the checkers rely on, and the runner of their commands.

Both comparators run what they compile under `landrun --best-effort`. When the kernel does not enforce Landlock,
--best-effort runs the command with no restriction at all, and says nothing. So rocq_check.py and lean_check.py
judge nothing on Linux unless this probe passes (with LRB_ALLOW_UNSANDBOXED=1 they check without a sandbox instead,
and say so in the verdict):

  landlock_enforced() -> (bool, detail)
      landrun (on PATH) runs a command, and a write its rules do not allow (a file in a fresh directory under
      the home directory, with only --rox / --rw /dev granted) fails with 'Permission denied'. Run once per
      process.
  landlock_abi() -> int or None
      the kernel's Landlock ABI version, None without Landlock. Below 4 (Linux < 6.7) landrun cannot restrict
      TCP connections; below 6 (Linux < 6.12) it does not scope signals, so a sandboxed process may signal the
      user's other processes.
  systemd_guard_ok(env=None) -> (bool, detail)
      `systemd-run --user` accepts the properties of the transient unit in which lean_check.py runs each Lean
      check (GUARD_PROPERTIES; this needs lingering for the user, `loginctl enable-linger`, and the user's D-Bus
      session bus, $XDG_RUNTIME_DIR/bus, which `systemd-run --wait --pipe` connects to).

On other systems the probes return (False, 'not Linux') and None: Rocq checks on macOS use sandbox-exec, and Lean
checks on macOS have no sandbox (they run only with LRB_ALLOW_UNSANDBOXED=1).

The checkers run the comparators with run(): each command in its own process group, killed with everything it
started on a timeout. stop() kills every command still running and refuses new ones; run_all() runs a batch, hands
on each result as its job ends, and calls stop() on Ctrl-C; after stop_on_sigterm(), SIGTERM (kill, timeout(1)) does
what Ctrl-C does.

Usage: python3 env/check/sandbox.py     prints the probes' results; exit 0 iff Landlock is enforced.
"""
import concurrent.futures as cf, os, platform, shlex, shutil, signal, subprocess, sys, tempfile, threading

# Socket families the Lean check's processes may not create (seccomp, enforced by systemd): UNIX sockets (Landlock
# below ABI 9, i.e. Linux < 7.1, does not restrict connect() on them, so the user's systemd manager could be
# asked to start a process outside the sandbox) and every network family (Landlock only restricts TCP, so UDP
# would otherwise leave the machine). systemd 255 rejects RestrictAddressFamilies=none for transient units, hence
# the explicit list. SystemCallArchitectures=native: on x86-64 the filter does not cover the i386 ABI's
# socketcall(), so 32-bit binaries are refused instead.
GUARD_PROPERTIES = ['-p', 'RestrictAddressFamilies=~AF_UNIX AF_INET AF_INET6 AF_NETLINK AF_PACKET AF_VSOCK',
                    '-p', 'SystemCallArchitectures=native']

# What a check that judges nothing for want of a sandbox tells the user.
OPT_IN = 'LRB_ALLOW_UNSANDBOXED=1 checks without a sandbox, for trusted files only'

_lock = threading.Lock()
_landlock = None
_procs, _procs_lock, _stopping = {}, threading.Lock(), False   # running commands: Popen -> systemd unit or None


def _tail(text, n=200):
    text = (text or '').strip().replace('\n', ' | ')
    return text[-n:]


def _probe_landlock():
    if platform.system() != 'Linux':
        return False, 'not Linux'
    landrun = shutil.which('landrun')
    if not landrun:
        return False, 'landrun not found on PATH (env/linux/install_landrun.sh installs it)'
    try:
        d = tempfile.mkdtemp(prefix='.landlock-probe-', dir=os.path.expanduser('~'))
    except OSError as e:
        return False, f'cannot create a probe directory in the home directory: {e}'
    probe = os.path.join(d, 'probe')
    base = [landrun, '--best-effort', '--rox', '/', '--rw', '/dev', '--']
    try:
        control = subprocess.run(base + ['sh', '-c', 'exit 0'], capture_output=True, encoding='utf-8',
                                 errors='replace', timeout=60)
        if control.returncode != 0:
            return False, (f'landrun ({landrun}) does not run commands (exit {control.returncode}): '
                           f'{_tail(control.stderr)}')
        r = subprocess.run(base + ['sh', '-c', f'echo x > {shlex.quote(probe)}'],
                           capture_output=True, encoding='utf-8', errors='replace', timeout=60)
        if os.path.exists(probe):
            return False, (f'NOT enforced: under landrun ({landrun}) a command wrote outside its rules, so this '
                           'kernel does not enforce Landlock and landrun --best-effort runs without a sandbox')
        # landrun starts sh with an empty environment, so in the C locale: a denied write says 'Permission denied'
        if r.returncode == 0 or 'Permission denied' not in r.stderr:
            return False, (f'inconclusive: the probe write did not happen, but was not denied either '
                           f'(exit {r.returncode}: {_tail(r.stderr) or "no message"})')
        return True, f'enforced: landrun ({landrun}) blocked a write outside its rules'
    except (OSError, subprocess.SubprocessError) as e:
        return False, f'probe failed: {e}'
    finally:
        shutil.rmtree(d, ignore_errors=True)


def landlock_enforced():
    """(True, detail) iff landrun on PATH really restricts what a command may write (cached per process)."""
    global _landlock
    with _lock:
        if _landlock is None:
            _landlock = _probe_landlock()
        return _landlock


def landlock_abi():
    """The kernel's Landlock ABI version: landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION), system
    call 444 on x86_64 and arm64. None when Landlock is unavailable, on another machine or system, or on any error."""
    if not sys.platform.startswith('linux') or platform.machine() not in ('x86_64', 'aarch64', 'arm64'):
        return None
    try:
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        libc.syscall.restype = ctypes.c_long
        abi = libc.syscall(ctypes.c_long(444), ctypes.c_long(0), ctypes.c_long(0), ctypes.c_long(1))
        return abi if isinstance(abi, int) and abi > 0 else None
    except Exception:
        return None


def systemd_guard_ok(env=None):
    """(True, detail) iff `systemd-run --user` starts a transient unit with GUARD_PROPERTIES."""
    if platform.system() != 'Linux':
        return False, 'not Linux'
    if not shutil.which('systemd-run'):
        return False, 'systemd-run not found'
    env = dict(os.environ if env is None else env)
    env.setdefault('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')
    try:
        r = subprocess.run(['systemd-run', '--user', '--quiet', '--wait', '--pipe', *GUARD_PROPERTIES, '/bin/true'],
                           env=env, capture_output=True, encoding='utf-8', errors='replace', timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        return False, f'systemd-run --user failed: {e}'
    if r.returncode != 0:
        bus = os.path.join(env['XDG_RUNTIME_DIR'], 'bus')
        state = 'present' if os.path.exists(bus) else 'missing (on Debian and Ubuntu, install dbus-user-session)'
        return False, (f'systemd-run --user unavailable (exit {r.returncode}: {_tail(r.stderr)}); enable lingering '
                       f'for this user (loginctl enable-linger) and set XDG_RUNTIME_DIR; the D-Bus session bus {bus} '
                       f'is {state}')
    return True, 'systemd-run --user accepts the guard properties'


def _tree(root):
    """root and every process descended from it, from one listing of ps ([root] if ps fails)."""
    try:
        out = subprocess.run(['ps', '-A', '-o', 'pid=', '-o', 'ppid='], capture_output=True, encoding='utf-8',
                             errors='replace', timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return [root]
    children = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    tree, todo = [root], [root]
    while todo:
        for c in children.get(todo.pop(), []):
            if c not in tree:
                tree.append(c)
                todo.append(c)
    return tree


def _signal(pids, sig):
    for pid in pids:
        try:
            os.kill(pid, sig)
        except OSError:
            pass


def kill(p, unit=None):
    """SIGKILL the process group of p, every process descended from p (rocq-comparator runs its sandboxed process
    in a session of its own, which a signal to the group does not reach) and the systemd unit `unit`. The group
    is stopped first, so that nothing in it starts a process in between."""
    try:
        os.killpg(p.pid, signal.SIGSTOP)
    except OSError:
        pass
    stopped = _tree(p.pid)
    _signal(stopped, signal.SIGSTOP)
    _signal(set(stopped) | set(_tree(p.pid)), signal.SIGKILL)
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except OSError:
        pass
    if unit:
        env = dict(os.environ)
        env.setdefault('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')
        try:
            subprocess.run(['systemctl', '--user', 'kill', '--signal=SIGKILL', unit], env=env, capture_output=True,
                           timeout=30)
        except (OSError, subprocess.SubprocessError):
            pass


def run(cmd, timeout, unit=None, **kw):
    """(returncode, stdout, stderr) of cmd, run in its own process group; its output is decoded as UTF-8, any byte
    that is not becomes U+FFFD. On a timeout (subprocess.TimeoutExpired is then raised) or an interrupt, kill() ends
    it, with the systemd unit `unit` that it starts, if any. After stop(), raises KeyboardInterrupt instead."""
    with _procs_lock:
        if _stopping:
            raise KeyboardInterrupt
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding='utf-8', errors='replace',
                             start_new_session=True, **kw)
        _procs[p] = unit
    try:
        out, err = p.communicate(timeout=timeout)
    except BaseException:
        kill(p, unit)
        try:
            p.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        raise
    finally:
        with _procs_lock:
            _procs.pop(p, None)
    return p.returncode, out, err


def stop():
    """Kill every command that run() is running, with everything it started, and make run() refuse new ones."""
    global _stopping
    with _procs_lock:
        _stopping = True
        running = list(_procs.items())
    for p, unit in running:
        kill(p, unit)


def stop_on_sigterm():
    """Make SIGTERM raise KeyboardInterrupt in the main thread, as Ctrl-C does: the commands that run() started
    are in sessions of their own, so a plain SIGTERM would leave them running."""
    def interrupt(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupt)


def run_all(fn, jobs, workers, done):
    """fn(job) for every job, `workers` at a time, and done(job, result) as each job ends. True when every job is
    done; False after Ctrl-C: then no other job starts, done() still gets the jobs that had ended (in the order of
    jobs), and the running ones are killed (stop()), their results dropped. Any other exception, from fn or done,
    stops the jobs in the same way and is raised."""
    ex = cf.ThreadPoolExecutor(max(1, workers))
    futures = {ex.submit(fn, job): job for job in jobs}
    passed = set()   # the futures given to done()
    try:
        for fut in cf.as_completed(futures):
            passed.add(fut)
            done(futures[fut], fut.result())
    except BaseException as e:
        for sig in (signal.SIGINT, signal.SIGTERM):   # a second one would leave the running checks behind
            signal.signal(sig, signal.SIG_IGN)
        for fut in futures:
            fut.cancel()
        # taken before stop(): what ended until now is a real result, what stop() kills is not
        ended = [fut for fut in futures if fut not in passed and fut.done() and not fut.cancelled()]
        stop()
        try:
            if isinstance(e, KeyboardInterrupt):
                for fut in ended:
                    if fut.exception() is None:
                        done(futures[fut], fut.result())
        finally:
            cf.wait(futures, timeout=15)   # the killed checks remove their work directories
            ex.shutdown(wait=False)
        if isinstance(e, KeyboardInterrupt):
            return False
        raise
    ex.shutdown()
    return True


def main():
    ok, detail = landlock_enforced()
    print(f"Landlock (landrun): {'enforced' if ok else 'NOT ENFORCED'}: {detail}")
    abi = landlock_abi()
    print(f"Landlock ABI: {abi if abi else 'unavailable'}")
    guard, gdetail = systemd_guard_ok()
    print(f"systemd guard (Lean checks): {'ok' if guard else 'unavailable'}: {gdetail}")
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
