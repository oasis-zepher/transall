import Foundation
import Testing

@testable import TransallMac

/// Checks `condition` repeatedly until it is true or `timeout` passes.
///
/// Returns as soon as the condition holds, so the long default timeout does not slow passing
/// tests. It only gives slow machines time to finish real conversions. Returns false on timeout;
/// the caller asserts the outcome.
@discardableResult
func eventually(
  timeout: Duration = .seconds(30), interval: Duration = .milliseconds(10),
  isolation: isolated (any Actor)? = #isolation,
  _ condition: () async throws -> Bool
) async throws -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if try await condition() { return true }
    try await Task.sleep(for: interval)
  }
  return try await condition()
}

/// Waits for an engine job to finish and returns its final state.
@MainActor
func finishedJob(_ id: String, in engine: NativeDocumentEngine) async throws -> JobResponse {
  let finished = try await eventually { try engine.job(id: id).isFinished }
  let job = try engine.job(id: id)
  #expect(finished, "Job \(id) did not finish; last status: \(job.status)")
  return job
}
