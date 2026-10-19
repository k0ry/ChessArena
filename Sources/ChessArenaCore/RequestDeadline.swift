import Foundation

/// A single monotonic budget shared by the engine, transport and countdown.
/// Task-local scope keeps simultaneous player/commentator requests independent.
public struct RequestTiming: Sendable {
    private static let origin = ContinuousClock.now
    public static func monotonicNow() -> TimeInterval {
        let value = origin.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    @TaskLocal public static var current: RequestTiming?
    public let budget: TimeInterval
    public let deadline: TimeInterval
    private let now: @Sendable () -> TimeInterval
    public init(seconds: TimeInterval, now: @escaping @Sendable () -> TimeInterval = { RequestTiming.monotonicNow() }) {
        budget = max(0, seconds)
        self.now = now
        deadline = now() + budget
    }
    public var remaining: TimeInterval { max(0, deadline - now()) }
    public var elapsed: TimeInterval { max(0, now() - (deadline - budget)) }
    public func check() throws {
        try Task.checkCancellation()
        if remaining <= 0 { throw ChatError.timeout }
    }
    public static func timeout(fallback: TimeInterval) throws -> TimeInterval {
        try Task.checkCancellation()
        guard let current else { return fallback }
        try current.check()
        return min(fallback, current.remaining)
    }
}

/// An absolute deadline, including a streaming response that never finishes.
/// Unlike a task group, this returns even if the cancelled operation ignores cancellation.
@MainActor
public enum RequestDeadline {
    public static func run<Value>(seconds: TimeInterval, operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try await run(timing: RequestTiming(seconds: seconds), operation: operation)
    }

    public static func run<Value>(timing: RequestTiming, operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try timing.check()
        let race = DeadlineRace<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                race.continuation = continuation
                race.work = Task { [weak race] in
                    do {
                        let value = try await RequestTiming.$current.withValue(timing) { try await operation() }
                        // A completed operation cannot win after the deadline, even if the timer's actor was busy.
                        try timing.check()
                        race?.finish(.success(value))
                    }
                    catch { race?.finish(.failure(error)) }
                }
                race.timer = Task { [weak race] in
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.001, timing.remaining) * 1_000_000_000)) }
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
