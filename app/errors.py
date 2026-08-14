from __future__ import annotations


class TransallError(ValueError):
    """Expected, user-facing task error base class."""


class PdfInputRequired(TransallError):
    pass


class OcrInputRequired(TransallError):
    pass


class NoUploadedFiles(TransallError):
    pass


class ProviderNotConfigured(TransallError):
    pass


class MissingDependency(RuntimeError):
    def __init__(self, message: str, install_hint: str) -> None:
        super().__init__(message)
        self.install_hint = install_hint
