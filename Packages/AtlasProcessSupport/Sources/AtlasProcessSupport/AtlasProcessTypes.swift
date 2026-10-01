import Foundation

public struct AtlasProcessRequest: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let stdin: Data
    public let timeout: Duration
    public let terminationGrace: Duration
    public let stdoutLimit: Int
    public let stderrLimit: Int
    public init(executableURL: URL, arguments: [String] = [], environment: [String: String] = ProcessInfo.processInfo.environment, stdin: Data = Data(), timeout: Duration = .seconds(30), terminationGrace: Duration = .seconds(1), stdoutLimit: Int = 8*1024*1024, stderrLimit: Int = 1024*1024) {
        self.executableURL = executableURL; self.arguments = arguments; self.environment = environment; self.stdin = stdin
        self.timeout = timeout; self.terminationGrace = terminationGrace; self.stdoutLimit = stdoutLimit; self.stderrLimit = stderrLimit
    }
}
public struct AtlasProcessResult: Sendable { public let exitStatus: Int32; public let stdout: Data; public let stderr: Data }
public enum AtlasProcessError: Error, Equatable, Sendable { case launchFailed(Int32), timedOut, cancelled, outputLimitExceeded(String), ioFailed(Int32), invalidRequest }
public protocol AtlasProcessRunning: Sendable { func run(_ request: AtlasProcessRequest) async throws -> AtlasProcessResult }
