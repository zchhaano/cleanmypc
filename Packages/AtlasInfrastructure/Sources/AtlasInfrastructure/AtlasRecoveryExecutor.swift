import AtlasDomain
import AtlasFileSafety
import Foundation

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
    public init(directoryURL: URL, homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        journal: (any AtlasOperationJournaling)? = nil) throws {
        self.journal = try journal ?? AtlasOperationJournal(directoryURL: directoryURL)
        coordinator = try AtlasMutationCoordinator(directoryURL: directoryURL); home = homeDirectoryURL
    }
    public func restore(operationID: UUID, requestID: UUID) async throws -> AtlasRestoreResult {
        try await coordinator.withLease { _ in
            guard var record = try self.journal.replay().last(where: { $0.operationID == operationID }),
                  let sourcePath = record.destinationPath, let sourceIdentity = record.destinationIdentity else {
                return .init(operationID: operationID, status: .reconciliationRequired, sourcePath: nil, destinationPath: nil)
            }
            func result(_ status: AtlasRestoreStatus) -> AtlasRestoreResult { .init(operationID: operationID, status: status, sourcePath: sourcePath, destinationPath: record.sourcePath) }
            let source = try AtlasFileSafetyPolicy.expanded(sourcePath, homeDirectoryURL: self.home)
            let target = try AtlasFileSafetyPolicy.expanded(record.sourcePath, homeDirectoryURL: self.home)
            let sourceActual = try? AtlasFileIdentityReader.read(source)
            let targetActual = try? AtlasFileIdentityReader.read(target)
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
            record.state = .restorePlanned; record.errorCode = "restoreRequest:\(requestID.uuidString)"
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
    }
}
