from __future__ import annotations

import json
import asyncio
import shutil
import threading
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated
from urllib.parse import urlparse

from fastapi import BackgroundTasks, Body, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles

from .artifacts import single_or_zip
from .capabilities import capabilities_payload, preflight as run_preflight
from .config import APP_ROOT, DATA_DIR, JOB_TTL_HOURS, MAX_CONCURRENT_JOBS, MAX_UPLOAD_BYTES
from .conversion import convert_to_pdf, extract_markdown
from .diagnostics import collect_diagnostics
from .errors import MissingDependency, NoUploadedFiles, OcrInputRequired, PdfInputRequired, ProviderNotConfigured
from .jobs import Job, JobCancelled, JobStore
from .ocr import ocr_document
from .pdf_ops import apply_pdf_edits, edit_options_from_request, merge_pdfs, pdf_page_count, render_preview_pages
from .translation import load_provider_configs, translate_pdf


LOCAL_ORIGIN_HOSTS = {"127.0.0.1", "localhost", "::1"}
STATE_CHANGING_METHODS = {"POST", "PUT", "PATCH", "DELETE"}
_JOB_SLOTS = threading.BoundedSemaphore(MAX_CONCURRENT_JOBS)


def create_app(data_dir: Path = DATA_DIR, run_background_inline: bool = False) -> FastAPI:
    store = JobStore(data_dir, ttl_hours=JOB_TTL_HOURS)
    store.recover_interrupted()
    store.cleanup_expired()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        async def cleanup_loop() -> None:
            while True:
                await asyncio.sleep(3600)
                await asyncio.to_thread(store.cleanup_expired)

        task = asyncio.create_task(cleanup_loop())
        try:
            yield
        finally:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    app = FastAPI(title="transall", lifespan=lifespan)
    static_dir = APP_ROOT / "app" / "static"

    @app.middleware("http")
    async def reject_cross_origin_state_changes(request: Request, call_next):
        if request.method in STATE_CHANGING_METHODS:
            origin = request.headers.get("origin")
            if origin and urlparse(origin).hostname not in LOCAL_ORIGIN_HOSTS:
                return Response(status_code=403, content='{"detail":"Cross-origin request rejected"}', media_type="application/json")
        return await call_next(request)

    if static_dir.exists():
        app.mount("/static", StaticFiles(directory=static_dir), name="static")

    @app.get("/")
    def index() -> FileResponse:
        return FileResponse(static_dir / "index.html")

    @app.get("/favicon.ico", status_code=204)
    def favicon() -> Response:
        return Response(status_code=204)

    @app.get("/api/config/providers")
    def providers() -> dict[str, object]:
        return {"providers": load_provider_configs(include_secrets=False)}

    @app.get("/api/diagnostics")
    def diagnostics() -> dict[str, object]:
        return collect_diagnostics()

    @app.get("/api/capabilities")
    def capabilities() -> dict[str, object]:
        return capabilities_payload()

    @app.post("/api/preflight")
    def preflight(payload: Annotated[dict[str, object], Body()]) -> dict[str, object]:
        return run_preflight(payload)

    @app.post("/api/jobs")
    async def create_job(
        background_tasks: BackgroundTasks,
        kind: Annotated[str, Form()],
        files: Annotated[list[UploadFile], File()],
        options: Annotated[str, Form()] = "{}",
    ) -> dict[str, object]:
        if kind not in {"convert", "extract_markdown", "pdf_edit", "pdf_translate", "ocr"}:
            raise HTTPException(status_code=400, detail=f"Unsupported job kind: {kind}")
        try:
            parsed_options = json.loads(options or "{}")
        except json.JSONDecodeError as exc:
            raise HTTPException(status_code=400, detail="options must be valid JSON") from exc

        job = store.create(kind, [], parsed_options)
        store.set_status(job, "queued", stage="uploading", message="正在上传文件")
        upload_dir = job.path / "uploads"
        upload_dir.mkdir(exist_ok=True)
        total = 0
        try:
            used_names: set[str] = set()
            stored_names: list[str] = []
            for file in files:
                safe_name = _unique_upload_name(Path(file.filename or "upload").name, used_names)
                stored_names.append(safe_name)
                target = upload_dir / safe_name
                with target.open("wb") as handle:
                    while chunk := await file.read(1024 * 1024):
                        total += len(chunk)
                        if total > MAX_UPLOAD_BYTES:
                            raise HTTPException(status_code=413, detail="Upload exceeds 200 MB limit")
                        handle.write(chunk)
            job.inputs = stored_names
            store.set_status(job, "queued", stage="queued", message="等待运行", progress=5)
        except Exception:
            store.delete(job.id)
            raise

        if run_background_inline:
            run_job(store, job.id)
        else:
            background_tasks.add_task(run_job, store, job.id)
        return store.get(job.id).public()

    @app.get("/api/jobs/{job_id}")
    def get_job(job_id: str) -> dict[str, object]:
        return _get_job_or_404(store, job_id).public()

    @app.get("/api/jobs/{job_id}/download")
    def download(job_id: str) -> FileResponse:
        job = _get_job_or_404(store, job_id)
        if not job.output:
            raise HTTPException(status_code=404, detail="Job has no output")
        output = Path(job.output)
        if not output.exists():
            raise HTTPException(status_code=404, detail="Output file is missing")
        return FileResponse(output, filename=output.name)

    @app.get("/api/jobs/{job_id}/preview/pages")
    def preview_pages(job_id: str) -> dict[str, object]:
        job = _get_job_or_404(store, job_id)
        source = _job_pdf_for_preview(job)
        if source is None:
            raise HTTPException(status_code=400, detail="No PDF available for preview")
        preview_dir = job.path / "preview"
        pages = sorted(preview_dir.glob("page-*.png"), key=_preview_page_number)
        if not pages:
            pages = render_preview_pages(source, preview_dir)
        return {
            "pages": [
                {"page": index + 1, "url": f"/api/jobs/{job.id}/preview/{path.name}"}
                for index, path in enumerate(pages)
            ]
        }

    @app.get("/api/jobs/{job_id}/preview/{filename}")
    def preview_file(job_id: str, filename: str) -> FileResponse:
        job = _get_job_or_404(store, job_id)
        path = job.path / "preview" / Path(filename).name
        if not path.exists():
            raise HTTPException(status_code=404, detail="Preview not found")
        return FileResponse(path)

    @app.delete("/api/jobs/{job_id}")
    def delete_job(job_id: str) -> dict[str, object]:
        job = _get_job_or_404(store, job_id)
        if job.status in {"queued", "running"}:
            raise HTTPException(status_code=409, detail="Job is still running; cancel it before deleting")
        store.delete(job_id)
        return {"deleted": True}

    @app.post("/api/jobs/{job_id}/cancel")
    def cancel_job(job_id: str) -> dict[str, object]:
        _get_job_or_404(store, job_id)
        return store.request_cancel(job_id).public()

    @app.post("/api/cleanup")
    def cleanup() -> dict[str, object]:
        return {"removed": store.cleanup_expired()}

    return app


def run_job(store: JobStore, job_id: str) -> None:
    while not _JOB_SLOTS.acquire(timeout=1):
        try:
            if store.get(job_id).cancel_requested:
                return
        except KeyError:
            return
    try:
        job = store.get(job_id)
        if job.status == "cancelled":
            return
        job.thread_id = threading.get_ident()
        store.set_status(job, "running", stage="starting", message="任务启动中", progress=10)
        _run_job_body(store, job)
    finally:
        _JOB_SLOTS.release()


def _run_job_body(store: JobStore, job: Job) -> None:
    try:
        store.raise_if_cancelled(job)
        upload_dir = job.path / "uploads"
        output_dir = job.path / "outputs"
        output_dir.mkdir(exist_ok=True)
        order = {name.casefold(): index for index, name in enumerate(job.inputs)}
        inputs = sorted(
            (path for path in upload_dir.iterdir() if path.is_file()),
            key=lambda path: (order.get(path.name.casefold(), len(job.inputs)), path.name),
        )
        if not inputs:
            raise NoUploadedFiles("No uploaded files")
        store.log(job, f"Task: {job.kind}")
        store.log(job, f"Inputs: {', '.join(path.name for path in inputs)}")

        if job.kind == "convert":
            store.set_progress(job, 20, stage="converting", message="正在转换文件")
            output = _run_many_with_progress(store, job, inputs, lambda path: convert_to_pdf(path, output_dir), output_dir / "converted-files.zip")
        elif job.kind == "extract_markdown":
            store.set_progress(job, 20, stage="extracting", message="正在提取 Markdown")
            output = _run_extract_markdown(store, job, inputs, output_dir)
        elif job.kind == "pdf_edit":
            store.set_progress(job, 25, stage="editing", message="正在修改 PDF")
            output = _run_pdf_edit(job, inputs, output_dir)
        elif job.kind == "pdf_translate":
            store.set_progress(job, 20, stage="translating", message="正在翻译 PDF")
            output = _run_pdf_translate(store, job, inputs, output_dir)
        elif job.kind == "ocr":
            store.set_progress(job, 20, stage="ocr", message="正在执行 OCR")
            output = _run_ocr(store, job, inputs, output_dir)
        else:
            raise ValueError(f"Unsupported job kind: {job.kind}")

        store.raise_if_cancelled(job)
        store.set_progress(job, 95, stage="finalizing", message="正在整理结果")
        store.set_output(job, output)
        store.log(job, f"Output written: {output.name}")
    except JobCancelled:
        shutil.rmtree(job.path / "outputs", ignore_errors=True)
        store.set_status(job, "cancelled", stage="cancelled", message="任务已取消", progress=job.progress)
    except Exception as exc:
        try:
            store.raise_if_cancelled(job)
        except JobCancelled:
            shutil.rmtree(job.path / "outputs", ignore_errors=True)
            store.set_status(job, "cancelled", stage="cancelled", message="任务已取消", progress=job.progress)
            return
        store.log(job, f"Failed stage: {job.kind}")
        store.log(job, f"Failure detail: {exc}")
        error = classify_error(exc)
        store.set_status(
            job,
            "failed",
            str(exc),
            stage="failed",
            message=error["message"],
            error_code=error["code"],
            error_hint=error["hint"],
            retryable=error["retryable"],
        )


def classify_error(exc: Exception) -> dict[str, object]:
    if isinstance(exc, PdfInputRequired):
        return {
            "code": "pdf_input_required",
            "message": "需要 PDF 输入文件",
            "hint": "请选择 PDF 文件，或切换到适合该文件类型的转换路径。",
            "retryable": False,
        }
    if isinstance(exc, OcrInputRequired):
        return {
            "code": "ocr_input_required",
            "message": "OCR 只支持 PDF 或图片",
            "hint": "请选择 PDF、PNG、JPG、WEBP 或 TIFF 文件。",
            "retryable": False,
        }
    if isinstance(exc, NoUploadedFiles):
        return {
            "code": "file_required",
            "message": "没有可处理的上传文件",
            "hint": "重新选择文件后再提交。",
            "retryable": False,
        }
    if isinstance(exc, ProviderNotConfigured):
        return {
            "code": "missing_provider",
            "message": "翻译服务未配置",
            "hint": "在 .env 中配置对应 API key 后重启服务。",
            "retryable": True,
        }
    if isinstance(exc, MissingDependency):
        return {
            "code": "missing_dependency",
            "message": "OCR 依赖不可用",
            "hint": exc.install_hint,
            "retryable": True,
        }
    return {
        "code": "task_failed",
        "message": "任务执行失败",
        "hint": "查看运行日志中的失败细节。",
        "retryable": True,
    }


def _run_extract_markdown(store: JobStore, job: Job, inputs: list[Path], output_dir: Path) -> Path:
    options = job.options
    return _run_many_with_progress(
        store,
        job,
        inputs,
        lambda path: extract_markdown(
            path,
            output_dir / f"{path.stem}.md",
            ocr_fallback=bool(options.get("ocr_fallback", False)),
            ocr_language=str(options.get("ocr_language") or "chi_sim+eng"),
        ),
        output_dir / "markdown-files.zip",
    )


def _run_pdf_edit(job: Job, inputs: list[Path], output_dir: Path) -> Path:
    options = job.options
    pdfs = [path for path in inputs if path.suffix.lower() == ".pdf"]
    if not pdfs:
        raise PdfInputRequired("PDF edit requires PDF input")
    action = options.get("action", "edit")
    if action == "merge" or len(pdfs) > 1:
        return merge_pdfs(pdfs, output_dir / "merged.pdf")

    source = pdfs[0]
    edit_options = edit_options_from_request(options, pdf_page_count(source))
    return apply_pdf_edits(source, output_dir / f"{source.stem}-edited.pdf", edit_options)


def _run_pdf_translate(store: JobStore, job: Job, inputs: list[Path], output_dir: Path) -> Path:
    source = next((path for path in inputs if path.suffix.lower() == ".pdf"), None)
    if source is None:
        raise PdfInputRequired("PDF translation requires PDF input")
    options = job.options

    def log_layout_fallback(detail: str) -> None:
        store.log(job, f"版式引擎不可用，回退到文本重建: {detail}")
        store.raise_if_cancelled(job)

    return translate_pdf(
        source,
        output_dir / f"{source.stem}-translated.pdf",
        provider_name=options.get("provider", "deepseek"),
        source_lang=options.get("source_lang", "en"),
        target_lang=options.get("target_lang", "zh"),
        pages_spec=options.get("pages", ""),
        output_mode=options.get("output_mode", "translated"),
        glossary=options.get("glossary", ""),
        on_layout_fallback=log_layout_fallback,
        on_progress=lambda done, total: _track_translation_progress(store, job, done, total),
    )


def _track_translation_progress(store: JobStore, job: Job, done: int, total: int) -> None:
    store.set_progress(job, 20 + round(70 * done / total), message=f"已翻译 {done}/{total} 页")
    store.raise_if_cancelled(job)


def _run_ocr(store: JobStore, job: Job, inputs: list[Path], output_dir: Path) -> Path:
    options = job.options
    return _run_many_with_progress(
        store,
        job,
        inputs,
        lambda path: ocr_document(
            path,
            output_dir,
            language=options.get("language", "chi_sim+eng"),
            output_format=options.get("output_format", "searchable_pdf"),
            cancel_check=lambda: store.raise_if_cancelled(job),
        ),
        output_dir / "ocr-files.zip",
    )


def _get_job_or_404(store: JobStore, job_id: str) -> Job:
    try:
        return store.get(job_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Job not found") from exc


def _job_pdf_for_preview(job: Job) -> Path | None:
    candidates: list[Path] = []
    if job.output:
        candidates.append(Path(job.output))
    candidates.extend((job.path / "uploads").glob("*.pdf"))
    for path in candidates:
        if path.exists() and path.suffix.lower() == ".pdf":
            return path
    return None


def _unique_upload_name(name: str, used: set[str]) -> str:
    safe = Path(name).name or "upload"
    candidate = safe
    index = 2
    while candidate.casefold() in used:
        path = Path(safe)
        candidate = f"{path.stem}-{index}{path.suffix}"
        index += 1
    used.add(candidate.casefold())
    return candidate


def _preview_page_number(path: Path) -> int:
    try:
        return int(path.stem.split("-")[-1])
    except ValueError:
        return 0


def _run_many_with_progress(store: JobStore, job: Job, inputs: list[Path], processor, zip_path: Path) -> Path:
    outputs: list[Path] = []
    total = len(inputs)
    for index, path in enumerate(inputs, start=1):
        store.raise_if_cancelled(job)
        outputs.append(processor(path))
        store.set_progress(job, 20 + round(70 * index / total), message=f"已处理 {index}/{total} 个文件")
    return single_or_zip(outputs, zip_path)


app = create_app()
