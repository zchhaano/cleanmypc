import AtlasApplication
import AtlasDomain
import Foundation
import AtlasProcessSupport

public struct MoleHealthAdapter: AtlasHealthSnapshotProviding {
    private let scriptURL: URL
    private let decoder = JSONDecoder()

    public init(scriptURL: URL? = nil) {
        self.scriptURL = scriptURL ?? Self.defaultScriptURL
    }

    public func collectHealthSnapshot() async throws -> AtlasHealthSnapshot {
        let output = try await runHealthScript()
        let payload = try decoder.decode(HealthJSONPayload.self, from: output)
        return payload.atlasSnapshot
    }

    private func runHealthScript() async throws -> Data {
        let result = try await AtlasProcessRunner().run(.init(executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptURL.path], timeout: .seconds(15)))
        guard result.exitStatus == 0 else {
            throw MoleHealthAdapterError.commandFailed(String(data: result.stderr, encoding: .utf8) ?? "unknown error")
        }
        return result.stdout
    }

    private static var defaultScriptURL: URL {
        MoleRuntimeLocator.url(for: "lib/check/health_json.sh")
    }
}

private enum MoleHealthAdapterError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message):
            return "Mole health adapter failed: \(message)"
        }
    }
}

private struct HealthJSONPayload: Decodable {
    let memoryUsedGB: Double
    let memoryTotalGB: Double
    let diskUsedGB: Double
    let diskTotalGB: Double
    let diskUsedPercent: Double
    let uptimeDays: Double
    let optimizations: [OptimizationPayload]

    enum CodingKeys: String, CodingKey {
        case memoryUsedGB = "memory_used_gb"
        case memoryTotalGB = "memory_total_gb"
        case diskUsedGB = "disk_used_gb"
        case diskTotalGB = "disk_total_gb"
        case diskUsedPercent = "disk_used_percent"
        case uptimeDays = "uptime_days"
        case optimizations
    }

    var atlasSnapshot: AtlasHealthSnapshot {
        let fallbackMemoryTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        let normalizedMemoryTotalGB = memoryTotalGB > 0 ? memoryTotalGB : fallbackMemoryTotalGB
        let normalizedUptimeDays = uptimeDays > 0 ? uptimeDays : (ProcessInfo.processInfo.systemUptime / 86_400)

        return AtlasHealthSnapshot(
            memoryUsedGB: memoryUsedGB,
            memoryTotalGB: normalizedMemoryTotalGB,
            diskUsedGB: diskUsedGB,
            diskTotalGB: diskTotalGB,
            diskUsedPercent: diskUsedPercent,
            uptimeDays: normalizedUptimeDays,
            optimizations: optimizations.map(\.atlasOptimization)
        )
    }
}

private struct OptimizationPayload: Decodable {
    let category: String
    let name: String
    let description: String
    let action: String
    let safe: Bool

    var atlasOptimization: AtlasOptimizationRecommendation {
        AtlasOptimizationRecommendation(
            category: category,
            name: name,
            detail: description,
            action: action,
            isSafe: safe
        )
    }
}
