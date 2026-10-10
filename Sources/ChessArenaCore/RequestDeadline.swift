import Foundation

/// An absolute deadline, including a streaming response that never finishes.
/// Unlike a task group, this returns even if the cancelled operation ignores cancellation.
@MainActor
public enum RequestDeadline {
    public static func run<Value>(seconds: TimeInterval, operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let race = DeadlineRace<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                race.continuation = continuation
                race.work = Task { [weak race] in
                    do { let value = try await operation(); race?.finish(.success(value)) }
                    catch { race?.finish(.failure(error)) }
                }
                race.timer = Task { [weak race] in
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.001, seconds) * 1_000_000_000)) }
                    catch { return }
                    race?.finish(.failure(ChatError.timeout))
                }
            }
        } onCancel: {
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }
}

@MainActor
private final class DeadlineRace<Value> {
    var continuation: CheckedContinuation<Value, Error>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?
    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        work?.cancel(); timer?.cancel()
        work = nil; timer = nil
        continuation.resume(with: result)
    }
}
