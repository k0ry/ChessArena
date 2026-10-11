import Foundation
import Darwin

struct CLIOutput {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

/// Each invocation owns a process group. Cancellation also kills children holding pipes open.
final class LocalCLIProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var pid: pid_t = 0
    private static let registryLock = NSLock()
    private static var active: [UUID: LocalCLIProcess] = [:]

    static func cancelAll() {
        registryLock.lock(); let processes = Array(active.values); registryLock.unlock()
        processes.forEach { $0.cancel() }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if pid > 0 { kill(-pid, SIGKILL) }
    }

    func run(binary: String, arguments: [String], directory: URL,
             environment: [String: String], timeout: TimeInterval, limit: Int = 1_048_576) async throws -> CLIOutput {
        let id = UUID()
        Self.registryLock.withLock { Self.active[id] = self }
        defer { _ = Self.registryLock.withLock { Self.active.removeValue(forKey: id) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try self.execute(binary: binary, arguments: arguments, directory: directory,
                                         environment: environment, timeout: timeout, limit: limit)
                    })
                }
            }
        } onCancel: { self.cancel() }
    }

    private func execute(binary: String, arguments: [String], directory: URL,
                         environment: [String: String], timeout: TimeInterval, limit: Int) throws -> CLIOutput {
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw ChatError.cli(.execution) }
        defer { out.forEach { close($0) } }
        guard pipe(&err) == 0 else { throw ChatError.cli(.execution) }
        defer { err.forEach { close($0) } }
        var actions: posix_spawn_file_actions_t?
        var attrs: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attrs)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attrs) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
        guard posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0 else { throw ChatError.cli(.execution) }
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attrs, 0)
        let args = ([binary] + arguments).map { strdup($0) } + [nil]
        let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { args.forEach { free($0) }; env.forEach { free($0) } }
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        var child: pid_t = 0
        let result = args.withUnsafeBufferPointer { argv in env.withUnsafeBufferPointer { envp in
            posix_spawn(&child, binary, &actions, &attrs,
                        UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: envp.baseAddress!))
        } }
        if result == 0 { pid = child }
        lock.unlock()
        guard result == 0 else { throw ChatError.cli(.missing) }
        // Parent never writes these descriptors. Mark closed slots so defer cannot close reused fds.
        close(out[1]); out[1] = -1; close(err[1]); err[1] = -1
        var reaped = false
        defer {
            lock.lock()
            kill(-child, SIGKILL)
            pid = 0
            lock.unlock()
            if !reaped { var status: Int32 = 0; while waitpid(child, &status, 0) < 0 && errno == EINTR {} }
        }
        _ = fcntl(out[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(err[0], F_SETFL, O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stdout = Data(), stderr = Data(), status: Int32 = 0
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain(_ fd: Int32, into data: inout Data) throws {
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { return }
                guard data.count + count <= limit else { throw ChatError.cli(.outputLimit) }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        while true {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { throw CancellationError() }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw ChatError.cli(.timeout) }
            try drain(out[0], into: &stdout); try drain(err[0], into: &stderr)
            let waited = waitpid(child, &status, WNOHANG)
            if waited == child {
                reaped = true
                try drain(out[0], into: &stdout); try drain(err[0], into: &stderr)
                return CLIOutput(stdout: stdout, stderr: stderr, status: status)
            }
            if waited < 0 && errno != EINTR { throw ChatError.cli(.execution) }
            var fds = [pollfd(fd: out[0], events: Int16(POLLIN), revents: 0), pollfd(fd: err[0], events: Int16(POLLIN), revents: 0)]
            _ = poll(&fds, nfds_t(fds.count), 25)
            if fds.allSatisfy({ $0.revents & Int16(POLLHUP) != 0 }) { usleep(10_000) }
        }
    }
}
