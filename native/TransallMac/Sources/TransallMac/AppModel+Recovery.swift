import SwiftUI

extension AppModel {
  func refreshTranslationRecovery(jobID: String) async {
    guard let job = currentJob, job.id == jobID, job.kind == "pdf_translate",
      ["failed", "cancelled"].contains(job.status), !isDeletingJob, !isSubmitting
    else { return }
    let requestID = UUID()
    recoveryLoadID = requestID
    isLoadingTranslationRecovery = true
    translationRecovery = nil
    translationRecoveryError = nil
    defer {
      if recoveryLoadID == requestID { isLoadingTranslationRecovery = false }
    }
    do {
      let recovery = try await backend.translationRecovery(jobID: jobID, allowingIncomplete: true)
      try Task.checkCancellation()
      guard recoveryLoadID == requestID, currentJob?.id == jobID,
        currentJob?.status == job.status, !isDeletingJob, !isSubmitting
      else { return }
      translationRecovery = TranslationRecoverySummary(
        jobID: jobID, regionCount: recovery.regions.count,
        issueCount: recovery.overflowRegionIDs.count,
        issuePages: Array(Set(recovery.issues.map { $0.pageIndex + 1 })).sorted(),
        completedRegionCount: recovery.translations.count)

    } catch is CancellationError {
      return
    } catch {
      guard recoveryLoadID == requestID, currentJob?.id == jobID,
        currentJob?.status == job.status
      else { return }
      if job.errorCode == "translation_layout_overflow" {
        translationRecoveryError = "无法复用已保存的译文：\(error.localizedDescription)"
      }
    }
  }

  func recoverTranslationAsPlainPDF(jobID: String) {
    guard canRecoverTranslation, currentJob?.id == jobID else { return }
    do {
      let queued = try backend.recoverTranslationAsPlainPDF(jobID: jobID)
      pollingTask?.cancel()
      currentJob = queued
      previewPages = []
      previewError = nil
      isLoadingPreview = false
      errorMessage = nil
      options.outputMode = "translated"
      preferences.set(jobID, forKey: lastJobKey)
      beginPolling(jobID: jobID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func rebuildTranslationPDF(outputMode: String) {
    guard let job = currentJob, job.kind == "pdf_translate", job.isFinished,
      !isImporting && !isSubmitting && !isSaving && !isDeletingJob
    else { return }
    do {
      let queued = try backend.rebuildTranslationPDF(jobID: job.id, outputMode: outputMode)
      pollingTask?.cancel()
      currentJob = queued
      previewPages = []
      previewError = nil
      isLoadingPreview = false
      errorMessage = nil
      options.outputMode = outputMode
      beginPolling(jobID: job.id)
    } catch { errorMessage = error.localizedDescription }
  }

  func clearTranslationRecovery() {
    recoveryLoadID = UUID()
    translationRecovery = nil
    translationRecoveryError = nil
    isLoadingTranslationRecovery = false
  }
}
