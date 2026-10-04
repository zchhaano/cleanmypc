import AtlasApplication
import AtlasDomain
import Foundation

public enum AtlasWorkspaceRepositoryError: LocalizedError, Sendable, Equatable {
    case readFailed(String)
    case decodeFailed(String)
    case createDirectoryFailed(String)
    case encodeFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .readFailed(reason):
            return "Failed to read workspace state: \(reason)"
        case let .decodeFailed(reason):
            return "Failed to decode workspace state: \(reason)"
        case let .createDirectoryFailed(reason):
            return "Failed to prepare workspace state directory: \(reason)"
        case let .encodeFailed(reason):
            return "Failed to encode workspace state: \(reason)"
        case let .writeFailed(reason):
            return "Failed to write workspace state: \(reason)"
        }
    }
}

public struct AtlasWorkspaceRepository: Sendable {
    private let stateFileURL: URL
    private let nowProvider: @Sendable () -> Date

    public init(
        stateFileURL: URL? = nil,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.stateFileURL = stateFileURL ?? Self.defaultStateFileURL
        self.nowProvider = nowProvider
    }

    public var directoryURL: URL { stateFileURL.deletingLastPathComponent() }
    public func loadState() throws -> AtlasWorkspaceState {
        let directory = try AtlasSecureDirectory(directoryURL)
        let coordinator = try AtlasMutationCoordinator(directoryURL: directoryURL)
        return try coordinator.withSynchronousLease {
            guard let data = try directory.readFile(stateFileURL.lastPathComponent) else {
                let state = AtlasWorkspaceState.empty
                try writeState(state, directory: directory)
                return state
            }
            let decoded = try decode(data)
            if decoded.migrate {
                let backup = stateFileURL.lastPathComponent + ".schema1.backup"
                if let existing = try directory.readFile(backup) { guard existing == data else { throw AtlasJournalError.corrupt } }
                else { try directory.writeAtomic(backup, data: data, replacing: false) }
                try writeState(decoded.state, directory: directory)
            }
            return decoded.state
        }
    }
    @discardableResult
    public func saveState(_ state: AtlasWorkspaceState, expectedState: AtlasWorkspaceState? = nil, lease: AtlasMutationLease? = nil) throws -> AtlasWorkspaceState {
        let directory = try AtlasSecureDirectory(directoryURL)
        let coordinator = try AtlasMutationCoordinator(directoryURL: directoryURL)
        let write: () throws -> AtlasWorkspaceState = {
            if let data = try directory.readFile(stateFileURL.lastPathComponent) {
                let current = try decode(data).state
                if let expectedState, current != expectedState { throw AtlasWorkspaceRepositoryError.writeFailed("Saved state changed in another worker; reload before writing.") }
            } else if expectedState != nil { throw AtlasWorkspaceRepositoryError.writeFailed("Saved state disappeared; reload before writing.") }
            try writeState(state, directory: directory)
            return state
        }
        if let lease {
            guard lease.validates(directory) else { throw AtlasJournalError.unsafeStorage }
            return try write()
        }
        return try coordinator.withSynchronousLease(write)

    }
    public func loadScaffoldSnapshot() throws -> AtlasWorkspaceSnapshot { try loadState().snapshot }
    public func loadCurrentPlan() throws -> ActionPlan { try loadState().currentPlan }
    public func loadSettings() throws -> AtlasSettings { try loadState().settings }
    private func writeState(_ state: AtlasWorkspaceState, directory: AtlasSecureDirectory) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try directory.writeAtomic(stateFileURL.lastPathComponent, data: encoder.encode(AtlasPersistedWorkspaceState(savedAt: nowProvider(), state: state)))
    }
    private func decode(_ data: Data) throws -> (state: AtlasWorkspaceState, migrate: Bool) {
        let decoder = JSONDecoder()
        do {
            // An envelope with a future/invalid version must never fall back to legacy decoding.
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["schemaVersion"] != nil {
                let envelope = try decoder.decode(AtlasPersistedWorkspaceState.self, from: data)
                guard [1, AtlasWorkspaceStateSchemaVersion.current].contains(envelope.schemaVersion) else { throw AtlasJournalError.corrupt }
                return (envelope.workspaceState, envelope.schemaVersion == 1)
            }
            return (try decoder.decode(AtlasWorkspaceState.self, from: data), true)
        } catch { throw AtlasWorkspaceRepositoryError.decodeFailed(String(describing: error)) }
    }

    private static var defaultStateFileURL: URL {
        #if DEBUG
        if let explicit = ProcessInfo.processInfo.environment["ATLAS_STATE_FILE"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }

        #endif
        #if DEBUG
        if let explicitDirectory = ProcessInfo.processInfo.environment["ATLAS_STATE_DIR"], !explicitDirectory.isEmpty {
            return URL(fileURLWithPath: explicitDirectory, isDirectory: true).appendingPathComponent("workspace-state.json")
        }
        #endif
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent("AtlasForMac", isDirectory: true).appendingPathComponent("workspace-state.json")
    }
}
