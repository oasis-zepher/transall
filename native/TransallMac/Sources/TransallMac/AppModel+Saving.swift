import SwiftUI

extension AppModel {
  func startSavingResult() {
    guard resultSaveTask == nil, canStartSavingResult,
      let job = currentJob, job.status == "done", let output = job.output
    else { return }
    isSaving = true
    errorMessage = nil
    if let resultDestinationPicker {
      saveResult(to: resultDestinationPicker(output), job: job)
    } else {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = output
      panel.canCreateDirectories = true
      panel.message = ResultSavePolicy.panelMessage
      resultSavePanel = panel
      // Keep SwiftUI's main event loop free while the system file service validates destinations.
      panel.begin { [weak self] response in
        guard let self, resultSavePanel === panel else { return }
        resultSavePanel = nil
        saveResult(to: response == .OK ? panel.url : nil, job: job)
      }
    }
  }

  private func saveResult(to destination: URL?, job: JobResponse) {
    guard let destination else {
      isSaving = false
      return
    }
    let originalDocuments = resultOriginalDocuments
    let allowReplacingExistingDestination = originalDocuments != nil
    do {
      try ResultSavePolicy.validate(
        destination: destination, originalDocuments: originalDocuments)
    } catch {
      errorMessage = error.localizedDescription
      isSaving = false
      return
    }

    errorMessage = nil
    isSaving = true
    resultSaveTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isSaving = false
        resultSaveTask = nil
      }
      do {
        try await resultDownloader(
          job.id, destination, allowReplacingExistingDestination)
        try Task.checkCancellation()
        resultRevealer(destination)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        errorMessage = error.localizedDescription
      }
    }
  }

  func cancelResultSaving() async {
    if let panel = resultSavePanel {
      resultSavePanel = nil
      panel.cancel(nil)
      isSaving = false
    }
    guard let resultSaveTask else { return }
    resultSaveTask.cancel()
    await resultSaveTask.value
  }
}
