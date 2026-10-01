import Darwin
import Foundation

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// One dedicated queue owns descriptors and waitpid. No blocking pipe operation runs on an actor.
public struct AtlasProcessRunner: AtlasProcessRunning {
    public init() {}
    public func run(_ request: AtlasProcessRequest) async throws -> AtlasProcessResult {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { throw AtlasProcessError.cancelled }
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try execute(request, cancellation: cancellation) })
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func execute(_ r: AtlasProcessRequest, cancellation: CancellationFlag) throws -> AtlasProcessResult {
        guard r.timeout > .zero, r.terminationGrace >= .zero, r.stdoutLimit >= 0, r.stderrLimit >= 0,
              !([r.executableURL.path] + r.arguments + r.environment.map { "\($0.key)=\($0.value)" }).contains(where: { $0.contains("\0") }) else { throw AtlasProcessError.invalidRequest }
        if cancellation.cancelled { throw AtlasProcessError.cancelled }
        var input = [Int32](repeating: -1, count: 2)
        var output = input, diagnostic = input
        var owned = Set<Int32>()
        func closeOwned(_ fd: Int32) { if owned.remove(fd) != nil { Darwin.close(fd) } }
        defer { for fd in owned { Darwin.close(fd) } }
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &input) == 0 else { throw AtlasProcessError.ioFailed(errno) }
        owned.formUnion(input)
        guard pipe(&output) == 0 else { throw AtlasProcessError.ioFailed(errno) }
        owned.formUnion(output)
        guard pipe(&diagnostic) == 0 else { throw AtlasProcessError.ioFailed(errno) }
        owned.formUnion(diagnostic)
        var one: Int32 = 1
        guard setsockopt(input[0], SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw AtlasProcessError.ioFailed(errno) }
        for fd in owned { guard fcntl(fd, F_SETFD, FD_CLOEXEC) >= 0 else { throw AtlasProcessError.ioFailed(errno) } }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw AtlasProcessError.ioFailed(errno) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw AtlasProcessError.ioFailed(errno) }
        defer { posix_spawnattr_destroy(&attributes) }
        for (source, dest) in [(input[1], STDIN_FILENO), (output[1], STDOUT_FILENO), (diagnostic[1], STDERR_FILENO)] {
            guard posix_spawn_file_actions_adddup2(&actions, source, dest) == 0 else { throw AtlasProcessError.ioFailed(errno) }
        }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw AtlasProcessError.ioFailed(errno) }
        let argv = ([r.executableURL.path] + r.arguments).map { strdup($0) } + [nil]
        let env = r.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.compactMap { $0 }.forEach { free($0) }; env.compactMap { $0 }.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnError = argv.withUnsafeBufferPointer { args in env.withUnsafeBufferPointer { vars in
            posix_spawn(&pid, r.executableURL.path, &actions, &attributes, UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: vars.baseAddress!))
        } }
        guard spawnError == 0 else { throw AtlasProcessError.launchFailed(spawnError) }
        closeOwned(input[1]); closeOwned(output[1]); closeOwned(diagnostic[1])
        for fd in [input[0], output[0], diagnostic[0]] {
            if fcntl(fd, F_SETFL, O_NONBLOCK) < 0 { kill(-pid, SIGKILL); throw AtlasProcessError.ioFailed(errno) }
        }
        let deadline = ContinuousClock.now.advanced(by: r.timeout)
        var failure: AtlasProcessError?
        var killDeadline: ContinuousClock.Instant?
        var stdout = Data(), stderr = Data(), written = 0
        var outputOpen = true, diagnosticOpen = true, inputOpen = true
        var status: Int32 = 0, exited = false
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let now = ContinuousClock.now
            if !exited {
                let wait = waitpid(pid, &status, WNOHANG)
                if wait == pid { exited = true }
                else if wait < 0 && errno != EINTR { failure = failure ?? .ioFailed(errno); exited = errno == ECHILD }
            }
            if failure == nil {
                if cancellation.cancelled { failure = .cancelled }
                else if now >= deadline { failure = .timedOut }
            }
            if failure != nil, killDeadline == nil {
                kill(-pid, SIGTERM)
                killDeadline = now.advanced(by: r.terminationGrace)
                if inputOpen { closeOwned(input[0]); inputOpen = false }
            }
            if let end = killDeadline, now >= end {
                kill(-pid, SIGKILL)
                // Reap only the owned direct child; pipes no longer control completion.
                for _ in 0..<100 where !exited {
                    if waitpid(pid, &status, WNOHANG) == pid { exited = true; break }
                    usleep(1000)
                }
                throw failure!
            }
            if inputOpen, written == r.stdin.count || exited { closeOwned(input[0]); inputOpen = false }
            if exited && !outputOpen && !diagnosticOpen && failure == nil {
                let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                return AtlasProcessResult(exitStatus: code, stdout: stdout, stderr: stderr)
            }
            var events: [pollfd] = []
            if outputOpen { events.append(pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)) }
            if diagnosticOpen { events.append(pollfd(fd: diagnostic[0], events: Int16(POLLIN), revents: 0)) }
            if inputOpen { events.append(pollfd(fd: input[0], events: Int16(POLLOUT), revents: 0)) }
            let count = poll(&events, nfds_t(events.count), 5)
            if count < 0 { if errno != EINTR { failure = failure ?? .ioFailed(errno) }; continue }
            for event in events where event.revents != 0 {
                if event.fd == input[0] {
                    let n = r.stdin.withUnsafeBytes { bytes in Darwin.write(event.fd, bytes.baseAddress!.advanced(by: written), min(16384, r.stdin.count - written)) }
                    if n > 0 { written += n }
                    else if n < 0 && errno != EINTR && errno != EAGAIN {
                        if errno != EPIPE { failure = failure ?? .ioFailed(errno) }
                        closeOwned(event.fd); inputOpen = false
                    }
                } else {
                    let n = Darwin.read(event.fd, &buffer, buffer.count)
                    if n > 0 {
                        let isOutput = event.fd == output[0]
                        let limit = isOutput ? r.stdoutLimit : r.stderrLimit
                        let used = isOutput ? stdout.count : stderr.count
                        if n > limit - used { failure = failure ?? .outputLimitExceeded(isOutput ? "stdout" : "stderr") }
                        else if isOutput { stdout.append(contentsOf: buffer.prefix(n)) }
                        else { stderr.append(contentsOf: buffer.prefix(n)) }
                    } else if n == 0 {
                        closeOwned(event.fd)
                        if event.fd == output[0] { outputOpen = false } else { diagnosticOpen = false }
                    } else if errno != EINTR && errno != EAGAIN { failure = failure ?? .ioFailed(errno) }
                }
            }
        }
    }
}
