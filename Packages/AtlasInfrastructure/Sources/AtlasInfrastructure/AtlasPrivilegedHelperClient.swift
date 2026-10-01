import AtlasProtocol
import Foundation
import AtlasProcessSupport

public protocol AtlasPrivilegedActionExecuting: Sendable {
    func perform(_ action: AtlasHelperAction) async throws -> AtlasHelperActionResult
}

public enum AtlasHelperClientError: LocalizedError, Sendable {
    case helperUnavailable(attemptedPaths: [String])
    case encodingFailed(String)
    case decodingFailed(String)
    case invocationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .helperUnavailable(attemptedPaths):
            let joined = attemptedPaths.isEmpty ? "<no candidate paths recorded>" : attemptedPaths.joined(separator: ", ")
            return "Bundled privileged helper is unavailable. Attempted: \(joined)"
        case let .encodingFailed(reason):
            return "Failed to encode helper action: \(reason)"
        case let .decodingFailed(reason):
            return "Failed to decode helper response: \(reason)"
        case let .invocationFailed(reason):
            return "Privileged helper failed: \(reason)"
        }
    }
}

public actor AtlasPrivilegedHelperClient: AtlasPrivilegedActionExecuting {
    private let explicitExecutableURL: URL?
    private let timeoutSeconds: TimeInterval
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(executableURL: URL? = nil, timeoutSeconds: TimeInterval = 30) {
        self.explicitExecutableURL = executableURL
        self.timeoutSeconds = timeoutSeconds
    }

    public func perform(_ action: AtlasHelperAction) async throws -> AtlasHelperActionResult {
        let resolution = resolveExecutableURL()
        guard let executableURL = resolution.url else {
            throw AtlasHelperClientError.helperUnavailable(attemptedPaths: resolution.attemptedPaths)
        }

        let requestData: Data
        do {
            requestData = try encoder.encode(action)
        } catch {
            throw AtlasHelperClientError.encodingFailed(error.localizedDescription)
        }

        let result: AtlasProcessResult
        do {
            result = try await AtlasProcessRunner().run(.init(executableURL: executableURL, arguments: ["--action-json"],
                stdin: requestData, timeout: .seconds(timeoutSeconds)))
        } catch { throw AtlasHelperClientError.invocationFailed(String(describing: error)) }
        let outputData = result.stdout
        guard result.exitStatus == 0 else {
            throw AtlasHelperClientError.invocationFailed(String(data: result.stderr, encoding: .utf8) ?? "unknown helper error")
        }

        do {
            let response = try decoder.decode(AtlasHelperActionResult.self, from: outputData)
            guard response.action == action else { throw AtlasHelperClientError.decodingFailed("Helper response does not match request evidence") }
            return response
        } catch {
            let raw = String(data: outputData, encoding: .utf8) ?? "<empty>"
            throw AtlasHelperClientError.decodingFailed("\(error.localizedDescription). Output: \(raw)")
        }
    }

    private func resolveExecutableURL() -> (url: URL?, attemptedPaths: [String]) {
        var attemptedPaths: [String] = []

        if let explicitExecutableURL {
            attemptedPaths.append(explicitExecutableURL.path)
            if FileManager.default.isExecutableFile(atPath: explicitExecutableURL.path) {
                return (explicitExecutableURL, attemptedPaths)
            }
        }

        #if DEBUG
        if let environmentPath = ProcessInfo.processInfo.environment["ATLAS_HELPER_EXECUTABLE"] {
            attemptedPaths.append(environmentPath)
            if FileManager.default.isExecutableFile(atPath: environmentPath) {
                return (URL(fileURLWithPath: environmentPath), attemptedPaths)
            }
        }

        #endif
        let bundleCandidates = bundledHelperCandidates()
        attemptedPaths.append(contentsOf: bundleCandidates.map(\.path))
        for candidate in bundleCandidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return (candidate, attemptedPaths)
        }

        #if DEBUG
        let devCandidates: [URL] = {
            guard let repoRoot = ProcessInfo.processInfo.environment["ATLAS_REPO_ROOT"] else {
                return []
            }
            let root = URL(fileURLWithPath: repoRoot, isDirectory: true)
            return [
                root.appendingPathComponent("Helpers/.build/debug/AtlasPrivilegedHelper"),
                root.appendingPathComponent("Helpers/.build/release/AtlasPrivilegedHelper"),
            ]
        }()
        attemptedPaths.append(contentsOf: devCandidates.map(\.path))

        for candidate in devCandidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return (candidate, attemptedPaths)
        }

        #endif
        return (nil, attemptedPaths)
    }

    private func bundledHelperCandidates() -> [URL] {
        let mainBundleURL = Bundle.main.bundleURL
        let appHelper = mainBundleURL.appendingPathComponent("Contents/Helpers/AtlasPrivilegedHelper")
        let xpcHelper = mainBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers/AtlasPrivilegedHelper")
        return [appHelper, xpcHelper]
    }
}
