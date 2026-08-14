from __future__ import annotations

import zipfile
from pathlib import Path


def single_or_zip(paths: list[Path], zip_path: Path) -> Path:
    if len(paths) == 1:
        return paths[0]
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in paths:
            archive.write(path, arcname=path.name)
    return zip_path
