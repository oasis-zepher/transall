from __future__ import annotations

import os
import signal
import subprocess
import threading
from typing import Any


_registry: dict[int, list[subprocess.Popen]] = {}
_lock = threading.Lock()


def run_tracked(command: list[str], timeout: float, *, check: bool = False, **popen_kwargs: Any) -> subprocess.CompletedProcess:
    """Run a subprocess registered under the current thread so cancellation can kill it."""
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
        **popen_kwargs,
    )
    thread_id = threading.get_ident()
    with _lock:
        _registry.setdefault(thread_id, []).append(process)
    try:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            _terminate(process)
            process.communicate()
            raise subprocess.TimeoutExpired(exc.cmd, exc.timeout) from exc
    finally:
        with _lock:
            processes = _registry.get(thread_id)
            if processes and process in processes:
                processes.remove(process)
    if check and process.returncode != 0:
        raise subprocess.CalledProcessError(process.returncode, command, output=stdout, stderr=stderr)
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def kill_thread_processes(thread_id: int) -> None:
    with _lock:
        processes = _registry.pop(thread_id, [])
    for process in processes:
        _terminate(process)


def _terminate(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except Exception:
        try:
            process.terminate()
        except Exception:
            pass
