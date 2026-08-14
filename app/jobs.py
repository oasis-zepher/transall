from __future__ import annotations

import json
import os
import shutil
import threading
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


@dataclass
class Job:
    id: str
    kind: str
    status: str
    path: Path
    inputs: list[str]
    created_at: str
    updated_at: str
    options: dict[str, Any] = field(default_factory=dict)
    output: str | None = None
    error: str | None = None
    stage: str = "queued"
    message: str = "等待运行"
    error_code: str | None = None
    error_hint: str | None = None
    retryable: bool = False
    progress: int = 0
    cancel_requested: bool = False
    logs: list[str] = field(default_factory=list)

    def public(self) -> dict[str, Any]:
        data = asdict(self)
        data.pop("path", None)
        if self.output:
            data["output"] = Path(self.output).name
        return data

    def stored(self) -> dict[str, Any]:
        data = asdict(self)
        data["path"] = str(self.path)
        return data


class JobCancelled(RuntimeError):
    pass


class JobStore:
    def __init__(self, root: Path, ttl_hours: int) -> None:
        self.root = root
        self.ttl = timedelta(hours=ttl_hours)
        self._lock = threading.RLock()
        self.root.mkdir(parents=True, exist_ok=True)

    def create(self, kind: str, inputs: list[str], options: dict[str, Any] | None = None) -> Job:
        job_id = uuid.uuid4().hex[:12]
        path = self.root / job_id
        path.mkdir(parents=True, exist_ok=False)
        now = utc_now().isoformat()
        job = Job(
            id=job_id,
            kind=kind,
            status="queued",
            path=path,
            inputs=inputs,
            options=options or {},
            created_at=now,
            updated_at=now,
        )
        self.save(job)
        return job

    def save(self, job: Job) -> None:
        with self._lock:
            job.updated_at = utc_now().isoformat()
            target = job.path / "job.json"
            if target.exists():
                try:
                    stored = json.loads(target.read_text(encoding="utf-8"))
                    job.cancel_requested = job.cancel_requested or bool(stored.get("cancel_requested"))
                except Exception:
                    pass
            temporary = job.path / ".job.json.tmp"
            temporary.write_text(json.dumps(job.stored(), ensure_ascii=False, indent=2), encoding="utf-8")
            os.replace(temporary, target)

    def get(self, job_id: str) -> Job:
        with self._lock:
            path = self.root / job_id / "job.json"
            if not path.exists():
                raise KeyError(job_id)
            data = json.loads(path.read_text(encoding="utf-8"))
            data["path"] = Path(data.get("path") or path.parent)
            return Job(**data)

    def log(self, job: Job, message: str) -> None:
        job.logs.append(message)
        self.save(job)

    def set_status(
        self,
        job: Job,
        status: str,
        error: str | None = None,
        *,
        stage: str | None = None,
        message: str | None = None,
        error_code: str | None = None,
        error_hint: str | None = None,
        retryable: bool | None = None,
        progress: int | None = None,
    ) -> None:
        job.status = status
        job.error = error
        if stage is not None:
            job.stage = stage
        elif status in {"queued", "running", "done", "failed", "cancelled"}:
            job.stage = status
        if message is not None:
            job.message = message
        if error_code is not None:
            job.error_code = error_code
        if error_hint is not None:
            job.error_hint = error_hint
        if retryable is not None:
            job.retryable = retryable
        if progress is not None:
            job.progress = max(0, min(100, int(progress)))
        self.save(job)

    def set_progress(self, job: Job, progress: int, *, stage: str | None = None, message: str | None = None) -> None:
        job.progress = max(0, min(100, int(progress)))
        if stage is not None:
            job.stage = stage
        if message is not None:
            job.message = message
        self.save(job)

    def set_output(self, job: Job, output: Path) -> None:
        with self._lock:
            current = self.get(job.id)
            if current.cancel_requested or current.status == "cancelled":
                job.cancel_requested = True
                raise JobCancelled("Job cancelled")
            job.output = str(output)
            job.status = "done"
            job.stage = "done"
            job.message = "任务完成"
            job.error = None
            job.error_code = None
            job.error_hint = None
            job.retryable = False
            job.progress = 100
            self.save(job)

    def request_cancel(self, job_id: str) -> Job:
        job = self.get(job_id)
        if job.status in {"done", "failed", "cancelled"}:
            return job
        job.cancel_requested = True
        job.message = "正在取消任务"
        if job.status == "queued":
            job.status = "cancelled"
            job.stage = "cancelled"
            job.message = "任务已取消"
        self.save(job)
        return job

    def raise_if_cancelled(self, job: Job) -> None:
        current = self.get(job.id)
        if current.cancel_requested or current.status == "cancelled":
            job.cancel_requested = True
            raise JobCancelled("Job cancelled")

    def delete(self, job_id: str) -> None:
        shutil.rmtree(self.root / job_id, ignore_errors=True)

    def cleanup_expired(self) -> int:
        removed = 0
        cutoff = utc_now() - self.ttl
        for job_file in self.root.glob("*/job.json"):
            try:
                data = json.loads(job_file.read_text(encoding="utf-8"))
                created = datetime.fromisoformat(data["created_at"])
            except Exception:
                continue
            if created < cutoff:
                shutil.rmtree(job_file.parent, ignore_errors=True)
                removed += 1
        return removed

    def recover_interrupted(self) -> int:
        recovered = 0
        for job_file in self.root.glob("*/job.json"):
            try:
                job = self.get(job_file.parent.name)
            except Exception:
                continue
            if job.status not in {"queued", "running"}:
                continue
            job.status = "failed"
            job.stage = "failed"
            job.message = "应用重启，任务已中断"
            job.error = "Application restarted before the task completed"
            job.error_code = "interrupted"
            job.error_hint = "可重新提交该任务。"
            job.retryable = True
            self.save(job)
            recovered += 1
        return recovered
