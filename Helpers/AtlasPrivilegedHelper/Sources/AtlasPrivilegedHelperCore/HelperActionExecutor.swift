import AtlasDomain
import AtlasFileSafety
import AtlasInfrastructure
import AtlasProtocol
import Foundation
import Darwin

public struct AtlasPrivilegedHelperActionExecutor {
    private let homeDirectoryURL: URL
    private let evidenceDirectoryURL: URL
    public init(fileManager: FileManager = .default, allowedRoots: [String]? = nil,
        currentUserID: UInt32 = getuid(), currentGroupID: UInt32 = getgid(),
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser, evidenceDirectoryURL: URL? = nil) {
        self.homeDirectoryURL = homeDirectoryURL
        self.evidenceDirectoryURL = evidenceDirectoryURL ?? homeDirectoryURL.appendingPathComponent("Library/Application Support/AtlasForMac")
    }
    public func validateEvidence(_ action: AtlasHelperAction) throws -> AtlasValidatedFileOperation {
        guard getuid() != 0, action.kind == .trashItems || action.kind == .restoreItem,
              let operationID = action.operationID, let planID = action.planID,
              let digest = action.planDigest, action.policyRevision == 1, let expected = action.expectedIdentity else {
            throw HelperValidationError.pathNotAllowed(action.targetPath)
        }
        let plan = try AtlasActionPlanRegistry.readPersistedPlan(directoryURL: evidenceDirectoryURL, id: planID)
        guard plan.digest == digest,
              let record = try AtlasOperationJournal(directoryURL: evidenceDirectoryURL).replay().last(where: { $0.operationID == operationID }),
              record.planID == planID, record.planDigest == digest,
              let intent = plan.operations.first(where: { $0.entryID == record.entryID }),
              intent.sourcePath == record.sourcePath, intent.expectedIdentity == record.sourceIdentity else {
            throw HelperValidationError.pathNotAllowed(action.targetPath)
        }
        let operation: AtlasFileOperationIntent
        let context: AtlasFilePolicyContext
        if action.kind == .trashItems {
            guard record.state == .planned, action.targetPath == intent.sourcePath,
                  action.destinationPath == nil, expected == intent.expectedIdentity,
                  intent.kind == .uninstall || intent.kind == .smartClean else { throw HelperValidationError.pathNotAllowed(action.targetPath) }
            operation = intent
            context = .init(homeDirectoryURL: homeDirectoryURL,
                allowedApplicationPaths: intent.kind == .uninstall ? [intent.sourcePath] : [])
        } else {
            guard record.state == .restorePlanned, action.targetPath == record.destinationPath,
                  action.destinationPath == record.sourcePath, expected == record.destinationIdentity else { throw HelperValidationError.pathNotAllowed(action.targetPath) }
            operation = .init(entryID: record.entryID, kind: .restore, sourcePath: action.targetPath,
                destinationPath: record.sourcePath, expectedIdentity: expected)
            context = .init(homeDirectoryURL: homeDirectoryURL, allowedApplicationPaths: record.kind == .uninstall ? [record.sourcePath] : [],
                recoveryMappings: [action.targetPath: record.sourcePath])
        }
        return try AtlasFileSafetyPolicy.validate(operation, context: context)
    }
    public func perform(_ action: AtlasHelperAction) throws -> AtlasHelperActionResult {
        let validated = try validateEvidence(action)
        guard AtlasSafetyCapabilities.fileMutationsEnabled else { throw HelperValidationError.pathNotAllowed(action.targetPath) }
        if action.kind == .restoreItem {
            _ = try AtlasFileMover.moveWithoutReplacing(validated)
            return AtlasHelperActionResult(action: action, success: true, message: "Restored verified object.", resolvedPath: action.destinationPath)
        }
        guard try AtlasFileIdentityReader.read(URL(fileURLWithPath: action.targetPath)) == action.expectedIdentity else { throw HelperValidationError.pathNotAllowed(action.targetPath) }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: action.targetPath), resultingItemURL: &trashed)
        guard let destination = trashed as URL?, try AtlasFileIdentityReader.read(destination) == action.expectedIdentity else { throw HelperValidationError.pathNotAllowed(action.targetPath) }
        return AtlasHelperActionResult(action: action, success: true, message: "Moved verified object to Trash.", resolvedPath: destination.path)
    }
}

enum HelperValidationError: LocalizedError {
    case pathNotFound(String)
    case pathNotAllowed(String)
    case invalidLaunchServicePath(String)
    case invalidRestoreDestination(String?)
    case restoreDestinationExists(String)
    case repairOwnershipFailed([String])

    var errorDescription: String? {
        switch self {
        case let .pathNotFound(path):
            return "Target path not found: \(path)"
        case let .pathNotAllowed(path):
            return "Target path is outside the helper allowlist: \(path)"
        case let .invalidLaunchServicePath(path):
            return "Launch service removal requires a plist path: \(path)"
        case let .invalidRestoreDestination(path):
            return "Restore destination is invalid: \(path ?? "<missing>")"
        case let .restoreDestinationExists(path):
            return "Restore destination already exists: \(path)"
        case let .repairOwnershipFailed(paths):
            return "Failed to repair ownership for: \(paths.joined(separator: ", "))"
        }
    }
}
