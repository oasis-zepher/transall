from __future__ import annotations

import logging
import os
import signal

# Local converters run through the shell-free, cancellable wrapper below.
import subprocess  # nosec B404
import threading
from collections.abc import Iterable
from typing import Any

_registry: dict[int, list[subprocess.Popen]] = {}
_lock = threading.Lock()
logger = logging.getLogger(__name__)


def run_tracked(
    command: list[str],
    timeout: float,
    *,
    check: bool = False,
    stdin_text: str | None = None,
    sensitive_values: Iterable[str] = (),
    **popen_kwargs: Any,
) -> subprocess.CompletedProcess:
    """Run a subprocess registered under the current thread so cancellation can kill it."""
    if not isinstance(command, list) or not command or not all(isinstance(part, str) for part in command):
        raise ValueError("command must be a non-empty argument list")
    if popen_kwargs.pop("shell", False) is not False:
        raise ValueError("tracked converters cannot run through a shell")
    if stdin_text is not None and "stdin" in popen_kwargs:
        raise ValueError("stdin_text cannot be combined with an explicit stdin")
    if stdin_text is not None:
        popen_kwargs["stdin"] = subprocess.PIPE
    # Executables are selected by local converter adapters; document paths are separate argv items.
    # Validated argv, explicit shell=False; literal-argument regression tested.
    process = subprocess.Popen(  # nosec B603
        command,
        shell=False,
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
            stdout, stderr = process.communicate(input=stdin_text, timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            _terminate(process)
            process.communicate()
            raise subprocess.TimeoutExpired(_redact_command(command, sensitive_values), exc.timeout) from exc
    finally:
        with _lock:
            processes = _registry.get(thread_id)
            if processes and process in processes:
                processes.remove(process)
    redacted_command = _redact_command(command, sensitive_values)
    redacted_stdout = _redact_text(stdout, sensitive_values)
    redacted_stderr = _redact_text(stderr, sensitive_values)
    if check and process.returncode != 0:
        raise subprocess.CalledProcessError(
            process.returncode,
            redacted_command,
            output=redacted_stdout,
            stderr=redacted_stderr,
        )
    return subprocess.CompletedProcess(redacted_command, process.returncode, redacted_stdout, redacted_stderr)


def kill_thread_processes(thread_id: int) -> None:
    with _lock:
        processes = _registry.pop(thread_id, [])
    for process in processes:
        _terminate(process)


def _terminate(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except OSError:
        try:
            process.terminate()
        except OSError as exc:
            logger.debug("Unable to terminate subprocess %s: %s", process.pid, exc)


def _redact_command(command: list[str], sensitive_values: Iterable[str]) -> list[str]:
    return [_redact_text(part, sensitive_values) for part in command]


def _redact_text(value: str | None, sensitive_values: Iterable[str]) -> str:
    redacted = value or ""
    for secret in sensitive_values:
        if secret:
            redacted = redacted.replace(secret, "[REDACTED]")
    return redacted
