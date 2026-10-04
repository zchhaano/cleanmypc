import AtlasDomain
import AtlasFileSafety
import Foundation
import Darwin

public enum AtlasRestoreStatus: String, Codable, Hashable, Sendable { case restored, alreadyRestored, sourceMissing, targetConflict, reconciliationRequired, rejected }
public struct AtlasRestoreResult: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let status: AtlasRestoreStatus
    public let sourcePath: String?
    public let destinationPath: String?
}
public final class AtlasRecoveryExecutor: @unchecked Sendable {
    private let journal: any AtlasOperationJournaling
    private let coordinator: AtlasMutationCoordinator
    private let home: URL
    private let storage: AtlasSecureDirectory
    public init(directoryURL: URL, homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        journal: (any AtlasOperationJournaling)? = nil) throws {
        storage = try AtlasSecureDirectory(directoryURL)
        self.journal = try journal ?? AtlasOperationJournal(directoryURL: directoryURL)
        coordinator = try AtlasMutationCoordinator(directoryURL: directoryURL); home = homeDirectoryURL
    }
    public func restore(operationID: UUID, requestID: UUID) async throws -> AtlasRestoreResult {
        try await restoreBatch(operationIDs: [operationID], requestID: requestID)[0]
    }
    public func restoreBatch(operationIDs: [UUID], requestID: UUID, commit: (@Sendable (AtlasMutationLease, [AtlasRestoreResult]) async throws -> Void)? = nil) async throws -> [AtlasRestoreResult] {
        guard !operationIDs.isEmpty, operationIDs.count <= AtlasExecutionLimits.maximumMutationEntries,
              Set(operationIDs).count == operationIDs.count else { throw AtlasJournalError.invalidRequest }
        let selected = operationIDs.sorted { $0.uuidString < $1.uuidString }
        return try await coordinator.withLease { lease in
            let data = try JSONEncoder().encode(selected)
            let name = "restore-request-\(requestID.uuidString).json"
            let retry: Bool
            if let previous = try self.storage.readFile(name) {
                guard previous == data else { throw AtlasJournalError.invalidRequest }
                retry = true
            } else {
                _ = try self.journal.replay()
                try self.storage.writeAtomic(name, data: data, replacing: false)
                retry = false
            }
            var results: [AtlasRestoreResult] = []
            for id in selected {
                if retry {
                    let record = try self.journal.replay().last { $0.operationID == id }
                    guard record?.restoreRequestID == requestID, record?.state == .restored else {
                        results.append(.init(operationID: id, status: .reconciliationRequired, sourcePath: nil, destinationPath: nil))
                        continue
                    }
                }
                let result = try self.restoreLocked(operationID: id, requestID: requestID)
                results.append(result)
                if ![.restored, .alreadyRestored].contains(result.status) { break }
            }
            try await commit?(lease, results)
            return results
        }
    }
    private func restoreLocked(operationID: UUID, requestID: UUID) throws -> AtlasRestoreResult {
        guard var record = try self.journal.replay().last(where: { $0.operationID == operationID }),
              let sourcePath = record.destinationPath, let sourceIdentity = record.destinationIdentity else {
            return .init(operationID: operationID, status: .reconciliationRequired, sourcePath: nil, destinationPath: nil)
        }
        func result(_ status: AtlasRestoreStatus) -> AtlasRestoreResult { .init(operationID: operationID, status: status, sourcePath: sourcePath, destinationPath: record.sourcePath) }
        let source = try AtlasFileSafetyPolicy.expanded(sourcePath, homeDirectoryURL: self.home)
        let target = try AtlasFileSafetyPolicy.expanded(record.sourcePath, homeDirectoryURL: self.home)
        let sourceActual: AtlasFileIdentity?, targetActual: AtlasFileIdentity?
        do { sourceActual = try Self.identityOrMissing(source); targetActual = try Self.identityOrMissing(target) }
        catch { return result(.reconciliationRequired) }
        if record.state == .restored {
            return result(sourceActual == nil && targetActual == record.sourceIdentity ? .alreadyRestored : .reconciliationRequired)
        }
        guard record.state == .moved else { return result(.reconciliationRequired) }
        guard let sourceActual else { return result(.sourceMissing) }
        if targetActual != nil || FileManager.default.fileExists(atPath: target.path) { return result(.targetConflict) }
        guard sourceActual == sourceIdentity else { return result(.reconciliationRequired) }
        let intent = AtlasFileOperationIntent(entryID: record.entryID, kind: .restore, sourcePath: source.path,
            destinationPath: target.path, expectedIdentity: sourceIdentity)
        let apps: Set<String> = record.kind == .uninstall ? [target.path] : []
        let context = AtlasFilePolicyContext(homeDirectoryURL: self.home, allowedApplicationPaths: apps, recoveryMappings: [source.path: target.path])
        let validated: AtlasValidatedFileOperation
        do { validated = try AtlasFileSafetyPolicy.validate(intent, context: context) }
        catch { return result(.rejected) }
        try Task.checkCancellation()
        record.state = .restorePlanned; record.restoreRequestID = requestID
        try self.journal.append(record)
        do {
            _ = try AtlasFileMover.moveWithoutReplacing(validated)
            guard try AtlasFileIdentityReader.read(target) == record.sourceIdentity else { throw AtlasFileSafetyError.identityChanged }
            record.state = .restored; record.errorCode = nil
            try self.journal.append(record)
            return result(.restored)
        } catch {
            record.state = .reconciliationRequired; record.errorCode = String(describing: error)
            try? self.journal.append(record)
            return result(.reconciliationRequired)
        }
    }
    static func identityOrMissing(_ url: URL) throws -> AtlasFileIdentity? {
        do { return try AtlasFileIdentityReader.read(url) }
        catch AtlasFileSafetyError.filesystemError(ENOENT) { return nil }
    }

}
