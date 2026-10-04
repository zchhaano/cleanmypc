import AtlasApplication
import AtlasDomain
import AtlasProtocol
import Foundation

public enum AtlasXPCWorkerConstants {
    public static let serviceName = "com.atlasformac.app.worker"
}

@objc public protocol AtlasXPCWorkerServiceProtocol: NSObjectProtocol {
    func sendRequestData(_ requestData: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
}

public struct AtlasXPCRequestConfiguration: Sendable {
    public var timeout: TimeInterval
    public var retryCount: Int
    public var retryDelay: TimeInterval

    public init(timeout: TimeInterval = 30, retryCount: Int = 1, retryDelay: TimeInterval = 0.25) {
        self.timeout = timeout
        self.retryCount = retryCount
        self.retryDelay = retryDelay
    }
}

public enum AtlasXPCTransportError: LocalizedError, Sendable, Equatable {
    case encodingFailed(String)
    case decodingFailed(String)
    case invalidResponse
    case connectionUnavailable(String)
    case timedOut(TimeInterval)
    case resultUnknown(requestID: UUID)

    public var errorDescription: String? {
        switch self {
        case let .encodingFailed(reason):
            return AtlasL10n.string("xpc.error.encodingFailed", reason)
        case let .decodingFailed(reason):
            return AtlasL10n.string("xpc.error.decodingFailed", reason)
        case .invalidResponse:
            return AtlasL10n.string("xpc.error.invalidResponse")
        case let .connectionUnavailable(reason):
            return AtlasL10n.string("xpc.error.connectionUnavailable", reason)
        case let .resultUnknown(requestID):
            return AtlasL10n.string("security.execution.unknown", requestID.uuidString)
        case let .timedOut(seconds):
            return AtlasL10n.string("xpc.error.timedOut", seconds)
        }
    }
}

/// XPC reply callback is transferred to one request task and invoked exactly once there.
private final class AtlasXPCReply: @unchecked Sendable {
    let callback: (Data?, NSError?) -> Void
    init(_ callback: @escaping (Data?, NSError?) -> Void) { self.callback = callback }
}

public final class AtlasXPCWorkerServiceHost: NSObject, AtlasXPCWorkerServiceProtocol {
    private let worker: AtlasScaffoldWorkerService

    public init(worker: AtlasScaffoldWorkerService = AtlasScaffoldWorkerService()) {
        self.worker = worker
        super.init()
    }

    public func sendRequestData(_ requestData: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        let worker = self.worker, response = AtlasXPCReply(reply)
        Task {
            do {
                let request = try JSONDecoder().decode(AtlasRequestEnvelope.self, from: requestData)
                let result = try await worker.submit(request)
                let payload = try JSONEncoder().encode(result)
                response.callback(payload, nil)
            } catch {
                response.callback(nil, error as NSError)
            }
        }
    }
}

public final class AtlasXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let host: AtlasXPCWorkerServiceHost

    public init(host: AtlasXPCWorkerServiceHost = AtlasXPCWorkerServiceHost()) {
        self.host = host
        super.init()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: AtlasXPCWorkerServiceProtocol.self)
        newConnection.exportedObject = host
        newConnection.resume()
        return true
    }
}

public typealias AtlasXPCCallbackRequestExecutor = @Sendable (Data, @escaping @Sendable (Result<Data, Error>) -> Void) -> @Sendable () -> Void

public typealias AtlasXPCDataRequestExecutor = @Sendable (Data) async throws -> Data

/// DispatchWorkItem.cancel is thread safe; immutable ownership permits cleanup from any completion path.
private final class AtlasXPCDeadline: @unchecked Sendable {
    let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}

private final class AtlasXPCConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }
}

public actor AtlasXPCWorkerClient: AtlasWorkerServing {
    private let serviceName: String
    private let requestConfiguration: AtlasXPCRequestConfiguration
    private let callbackExecutor: AtlasXPCCallbackRequestExecutor?
    private let requestExecutor: AtlasXPCDataRequestExecutor?
    private var connection: NSXPCConnection?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        serviceName: String = AtlasXPCWorkerConstants.serviceName,
        requestConfiguration: AtlasXPCRequestConfiguration = AtlasXPCRequestConfiguration(),
        requestExecutor: AtlasXPCDataRequestExecutor? = nil,
        callbackExecutor: AtlasXPCCallbackRequestExecutor? = nil
    ) {
        self.callbackExecutor = callbackExecutor
        self.serviceName = serviceName
        self.requestConfiguration = requestConfiguration
        self.requestExecutor = requestExecutor
    }

    public func submit(_ request: AtlasRequestEnvelope) async throws -> AtlasWorkerCommandResult {
        guard requestConfiguration.timeout.isFinite, requestConfiguration.timeout > 0,
              (0...3).contains(requestConfiguration.retryCount), requestConfiguration.retryDelay.isFinite,
              (0...5).contains(requestConfiguration.retryDelay) else { throw AtlasXPCTransportError.invalidResponse }
        let requestData: Data

        do {
            requestData = try encoder.encode(request)
        } catch {
            throw AtlasXPCTransportError.encodingFailed(error.localizedDescription)
        }

        let responseData: Data
        do { responseData = try await submitRequestDataWithRetry(requestData, mayRetry: request.command.isReadOnlyForRetry) }
        catch {
            if !request.command.isReadOnlyForRetry { throw AtlasXPCTransportError.resultUnknown(requestID: request.id) }
            throw error
        }

        do {
            let result = try decoder.decode(AtlasWorkerCommandResult.self, from: responseData)
            guard result.response.requestID == request.id, result.request.id == request.id else { throw AtlasXPCTransportError.invalidResponse }
            return result
        } catch {
            if !request.command.isReadOnlyForRetry { throw AtlasXPCTransportError.resultUnknown(requestID: request.id) }
            throw AtlasXPCTransportError.decodingFailed(error.localizedDescription)
        }
    }

    private func submitRequestDataWithRetry(_ requestData: Data, mayRetry: Bool) async throws -> Data {
        var attempt = 0
        var lastError: Error = AtlasXPCTransportError.invalidResponse

        while attempt <= requestConfiguration.retryCount {
            do {
                return try await submitRequestDataOnce(requestData)
            } catch {
                lastError = error

                guard mayRetry, !Task.isCancelled, attempt < requestConfiguration.retryCount,
                      shouldRetry(after: error) else {
                    throw error
                }

                resetConnection()

                if requestConfiguration.retryDelay > 0 {
                    let delay = UInt64(requestConfiguration.retryDelay * 1_000_000_000)
                    try await Task.sleep(nanoseconds: delay)
                }

                attempt += 1
            }
        }

        throw lastError
    }

    private func submitRequestDataOnce(_ requestData: Data) async throws -> Data {
        let completion = AtlasXPCRequestCompletion()
        let timeout = requestConfiguration.timeout
        let executor = requestExecutor
        let callback = callbackExecutor
        let connectionBox = executor == nil && callback == nil ? AtlasXPCConnectionBox(newConnection()) : nil
        return try await withTaskCancellationHandler {
            if Task.isCancelled { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                if timeout > 0 {
                    let item = DispatchWorkItem { [weak completion] in completion?.finish(.failure(AtlasXPCTransportError.timedOut(timeout))) }
                    let deadline = AtlasXPCDeadline(item)
                    completion.onFinish { deadline.cancel() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
                }
                if let callback {
                    let cancel = callback(requestData) { completion.finish($0) }
                    completion.onFinish(cancel)
                } else if let executor {
                    let task = Task {
                        do { completion.finish(.success(try await executor(requestData))) }
                        catch { completion.finish(.failure(error)) }
                    }
                    completion.onFinish { task.cancel() }
                } else if let connectionBox {
                    completion.onFinish { connectionBox.connection.invalidate() }
                    guard let proxy = connectionBox.connection.remoteObjectProxyWithErrorHandler({ error in
                        completion.finish(.failure(AtlasXPCTransportError.connectionUnavailable(error.localizedDescription)))
                    }) as? AtlasXPCWorkerServiceProtocol else {
                        completion.finish(.failure(AtlasXPCTransportError.invalidResponse)); return
                    }
                    proxy.sendRequestData(requestData) { data, error in
                        if let error { completion.finish(.failure(AtlasXPCTransportError.connectionUnavailable(error.localizedDescription))) }
                        else if let data { completion.finish(.success(data)) }
                        else { completion.finish(.failure(AtlasXPCTransportError.invalidResponse)) }
                    }
                }
            }
        } onCancel: { completion.finish(.failure(CancellationError())) }
    }

    private func shouldRetry(after error: Error) -> Bool {
        guard let transportError = error as? AtlasXPCTransportError else {
            return false
        }

        switch transportError {
        case .connectionUnavailable, .invalidResponse, .timedOut:
            return true
        case .encodingFailed, .decodingFailed, .resultUnknown:
            return false
        }
    }

    private func newConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: AtlasXPCWorkerServiceProtocol.self)
        connection.resume()
        return connection
    }

    private func clearConnection(ifMatching disconnectedConnection: NSXPCConnection?) {
        guard let disconnectedConnection else {
            connection = nil
            return
        }

        if connection === disconnectedConnection {
            connection = nil
        }
    }

    private func resetConnection() {
        connection?.invalidate()
        connection = nil
    }
}

public actor AtlasPreferredWorkerService: AtlasWorkerServing {
    private let xpcClient: AtlasXPCWorkerClient
    private let fallbackWorker: AtlasScaffoldWorkerService
    private let allowFallback: Bool

    public init(
        serviceName: String = AtlasXPCWorkerConstants.serviceName,
        requestConfiguration: AtlasXPCRequestConfiguration = AtlasXPCRequestConfiguration(),
        requestExecutor: AtlasXPCDataRequestExecutor? = nil,
        fallbackWorker: AtlasScaffoldWorkerService = AtlasScaffoldWorkerService(),
        allowFallback: Bool = ProcessInfo.processInfo.environment["ATLAS_ALLOW_SCAFFOLD_FALLBACK"] == "1"
    ) {
        self.xpcClient = AtlasXPCWorkerClient(
            serviceName: serviceName,
            requestConfiguration: requestConfiguration,
            requestExecutor: requestExecutor
        )
        self.fallbackWorker = fallbackWorker
        self.allowFallback = allowFallback
    }

    public func submit(_ request: AtlasRequestEnvelope) async throws -> AtlasWorkerCommandResult {
        do {
            let result = try await xpcClient.submit(request)
            if request.command.isReadOnlyForRetry, shouldFallback(from: result) {
                guard allowFallback else {
                    return result
                }
                return try await fallbackWorker.submit(request)
            }
            return result
        } catch {
            guard request.command.isReadOnlyForRetry, allowFallback else {
                throw error
            }
            return try await fallbackWorker.submit(request)
        }
    }

    private func shouldFallback(from result: AtlasWorkerCommandResult) -> Bool {
        guard case let .rejected(code, _) = result.response.response else {
            return false
        }

        switch code {
        case .executionUnavailable, .helperUnavailable:
            return true
        default:
            return false
        }
    }
}
