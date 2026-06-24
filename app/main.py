from __future__ import annotations

import json
import shutil
import zipfile
from pathlib import Path
from typing import Annotated

from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from .config import APP_ROOT, DATA_DIR, JOB_TTL_HOURS, MAX_UPLOAD_BYTES
from .conversion import convert_to_pdf, extract_markdown
from .diagnostics import collect_diagnostics
from .jobs import Job, JobStore
from .ocr import ocr_document
from .pdf_ops import PdfEditOptions, apply_pdf_edits, merge_pdfs, parse_page_spec, render_preview_pages
from .translation import load_provider_configs, translate_pdf


def create_app(data_dir: Path = DATA_DIR, run_background_inline: bool = False) -> FastAPI:
    store = JobStore(data_dir, ttl_hours=JOB_TTL_HOURS)
    app = FastAPI(title="Proteuswitch")
    static_dir = APP_ROOT / "app" / "static"

    if static_dir.exists():
        app.mount("/static", StaticFiles(directory=static_dir), name="static")

    @app.get("/")
    def index() -> FileResponse:
        return FileResponse(static_dir / "index.html")

    @app.get("/api/config/providers")
    def providers() -> dict[str, object]:
        return {"providers": load_provider_configs(include_secrets=False)}

    @app.get("/api/diagnostics")
    def diagnostics() -> dict[str, object]:
        return collect_diagnostics()

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

        job = store.create(kind, [file.filename or "upload" for file in files], parsed_options)
        upload_dir = job.path / "uploads"
        upload_dir.mkdir(exist_ok=True)
        total = 0
        for file in files:
            safe_name = Path(file.filename or "upload").name
            target = upload_dir / safe_name
            with target.open("wb") as handle:
                while chunk := await file.read(1024 * 1024):
                    total += len(chunk)
                    if total > MAX_UPLOAD_BYTES:
                        store.set_status(job, "failed", "Upload exceeds 200 MB limit")
                        raise HTTPException(status_code=413, detail="Upload exceeds 200 MB limit")
                    handle.write(chunk)

        if run_background_inline:
            run_job(store, job.id)
        else:
            background_tasks.add_task(run_job, store, job.id)
        return store.get(job.id).public()

    @app.get("/api/jobs/{job_id}")
    def get_job(job_id: str) -> dict[str, object]:
        try:
            return store.get(job_id).public()
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Job not found") from exc

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
        store.delete(job_id)
        return {"deleted": True}

    @app.post("/api/cleanup")
    def cleanup() -> dict[str, object]:
        return {"removed": store.cleanup_expired()}

    return app


def run_job(store: JobStore, job_id: str) -> None:
    job = store.get(job_id)
    store.set_status(job, "running")
    try:
        upload_dir = job.path / "uploads"
        output_dir = job.path / "outputs"
        output_dir.mkdir(exist_ok=True)
        inputs = sorted(path for path in upload_dir.iterdir() if path.is_file())
        if not inputs:
            raise ValueError("No uploaded files")
        store.log(job, f"Task: {job.kind}")
        store.log(job, f"Inputs: {', '.join(path.name for path in inputs)}")

        if job.kind == "convert":
            outputs = [convert_to_pdf(path, output_dir) for path in inputs]
            output = _single_or_zip(outputs, output_dir / "converted-files.zip")
        elif job.kind == "extract_markdown":
            output = _run_extract_markdown(job, inputs, output_dir)
        elif job.kind == "pdf_edit":
            output = _run_pdf_edit(job, inputs, output_dir)
        elif job.kind == "pdf_translate":
            output = _run_pdf_translate(job, inputs, output_dir)
        elif job.kind == "ocr":
            output = _run_ocr(job, inputs, output_dir)
        else:
            raise ValueError(f"Unsupported job kind: {job.kind}")

        store.set_output(job, output)
        store.log(job, f"Output written: {output.name}")
    except Exception as exc:
        store.log(job, f"Failed stage: {job.kind}")
        store.log(job, f"Failure detail: {exc}")
        store.set_status(job, "failed", str(exc))


def _run_extract_markdown(job: Job, inputs: list[Path], output_dir: Path) -> Path:
    options = job.options
    outputs = [
        extract_markdown(
            path,
            output_dir / f"{path.stem}.md",
            ocr_fallback=bool(options.get("ocr_fallback", False)),
            ocr_language=str(options.get("ocr_language") or "chi_sim+eng"),
        )
        for path in inputs
    ]
    return _single_or_zip(outputs, output_dir / "markdown-files.zip")


def _run_pdf_edit(job: Job, inputs: list[Path], output_dir: Path) -> Path:
    options = job.options
    pdfs = [path for path in inputs if path.suffix.lower() == ".pdf"]
    if not pdfs:
        raise ValueError("PDF edit requires PDF input")
    action = options.get("action", "edit")
    if action == "merge" or len(pdfs) > 1:
        return merge_pdfs(pdfs, output_dir / "merged.pdf")

    source = pdfs[0]
    with_source = __import__("fitz").open(source)
    page_count = with_source.page_count
    with_source.close()

    delete_pages = parse_page_spec(options.get("delete_pages", ""), page_count) if options.get("delete_pages") else []
    rotate_pages = {
        page: int(options.get("rotate_degrees", 90))
        for page in parse_page_spec(options.get("rotate_pages", ""), page_count)
    }
    reorder_pages = parse_page_spec(options.get("reorder_pages", ""), page_count) if options.get("reorder_pages") else []
    replace_text = {}
    if options.get("replace_find"):
        replace_text[str(options["replace_find"])] = str(options.get("replace_with", ""))
    edit_options = PdfEditOptions(
        delete_pages=delete_pages,
        rotate_pages=rotate_pages,
        reorder_pages=reorder_pages,
        replace_text=replace_text,
        watermark=options.get("watermark") or None,
    )
    return apply_pdf_edits(source, output_dir / f"{source.stem}-edited.pdf", edit_options)


def _run_pdf_translate(job: Job, inputs: list[Path], output_dir: Path) -> Path:
    source = next((path for path in inputs if path.suffix.lower() == ".pdf"), None)
    if source is None:
        raise ValueError("PDF translation requires PDF input")
    options = job.options
    return translate_pdf(
        source,
        output_dir / f"{source.stem}-translated.pdf",
        provider_name=options.get("provider", "deepseek"),
        source_lang=options.get("source_lang", "en"),
        target_lang=options.get("target_lang", "zh"),
        pages_spec=options.get("pages", ""),
        output_mode=options.get("output_mode", "translated"),
        glossary=options.get("glossary", ""),
    )


def _run_ocr(job: Job, inputs: list[Path], output_dir: Path) -> Path:
    options = job.options
    outputs = [
        ocr_document(
            path,
            output_dir,
            language=options.get("language", "chi_sim+eng"),
            output_format=options.get("output_format", "searchable_pdf"),
        )
        for path in inputs
    ]
    return _single_or_zip(outputs, output_dir / "ocr-files.zip")


def _single_or_zip(paths: list[Path], zip_path: Path) -> Path:
    if len(paths) == 1:
        return paths[0]
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in paths:
            archive.write(path, arcname=path.name)
    return zip_path


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


app = create_app()
