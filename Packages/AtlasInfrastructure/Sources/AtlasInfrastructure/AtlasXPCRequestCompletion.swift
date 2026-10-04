import Foundation

/// Both completion before registration and late duplicate callbacks are safe.
public final class AtlasXPCRequestCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?
    private var continuation: CheckedContinuation<Data, Error>?
    private var cleanup: [@Sendable () -> Void] = []
    public init() {}
    func install(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func onFinish(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        if result != nil { lock.unlock(); callback() }
        else { cleanup.append(callback); lock.unlock() }
    }
    @discardableResult public func finish(_ result: Result<Data, Error>) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result
        let continuation = self.continuation, callbacks = cleanup
        self.continuation = nil; cleanup = []
        lock.unlock()
        continuation?.resume(with: result)
        callbacks.forEach { $0() }
        return true
    }
}
