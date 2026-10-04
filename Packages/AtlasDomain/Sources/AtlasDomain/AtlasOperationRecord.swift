import Foundation

public enum AtlasOperationState: String, Codable, Hashable, Sendable {
    case planned, moved, restorePlanned, restored, failed, reconciliationRequired
}
public struct AtlasOperationRecord: Codable, Hashable, Sendable {
    public var journalVersion: Int = 1
    public var sequence: UInt64 = 0
    public let operationID: UUID
    public let requestID: UUID
    public let planID: UUID
    public let planDigest: String
    public let policyRevision: Int
    public let entryID: UUID
    public let findingID: UUID?
    public let kind: AtlasFileOperationKind
    public let sourcePath: String
    public var destinationPath: String?
    public let sourceIdentity: AtlasFileIdentity
    public var destinationIdentity: AtlasFileIdentity?
    public var timestamp: Date
    public var state: AtlasOperationState
    public var errorCode: String?
    public var restoreRequestID: UUID?
    public init(operationID: UUID = UUID(), requestID: UUID, planID: UUID, planDigest: String, policyRevision: Int = 1,
        entryID: UUID, findingID: UUID? = nil, kind: AtlasFileOperationKind, sourcePath: String, destinationPath: String? = nil,
        sourceIdentity: AtlasFileIdentity, state: AtlasOperationState = .planned) {
        self.operationID = operationID; self.requestID = requestID; self.planID = planID; self.planDigest = planDigest
        self.policyRevision = policyRevision; self.entryID = entryID; self.findingID = findingID; self.kind = kind
        self.sourcePath = sourcePath; self.destinationPath = destinationPath; self.sourceIdentity = sourceIdentity
        self.timestamp = Date(); self.state = state
    }
}
public struct AtlasRequestStatus: Codable, Hashable, Sendable {
    public let requestID: UUID
    public let operations: [AtlasOperationRecord]
    public let selection: AtlasExecutionSelection?
    public let selectedOperationIDs: [UUID]?
    public var unstartedOperationIDs: [UUID] {
        let started = Set(operations.map(\.operationID))
        return selectedOperationIDs?.filter { !started.contains($0) } ?? []
    }
    public var unstartedEntryIDs: [UUID] {
        let started = Set(operations.map(\.entryID))
        return selection?.selectedEntryIDs.filter { !started.contains($0) } ?? []
    }
    public var requiresReconciliation: Bool { operations.isEmpty || !unstartedEntryIDs.isEmpty || !unstartedOperationIDs.isEmpty || operations.contains { [.planned, .restorePlanned, .reconciliationRequired].contains($0.state) } }
    public init(requestID: UUID, operations: [AtlasOperationRecord], selection: AtlasExecutionSelection? = nil, selectedOperationIDs: [UUID]? = nil) { self.requestID = requestID; self.operations = operations; self.selection = selection; self.selectedOperationIDs = selectedOperationIDs }
}

public enum AtlasSafetyCapabilities {
    // Reopening requires the candidate commit's VM, Helper and UI acceptance evidence.
    public static let fileMutationsEnabled = false
    public static let pamMutationsEnabled = false
    public static let cliCacheMutationsEnabled = false
}
public enum AtlasRecoveryAvailability: String, Codable, Hashable, Sendable {
    case ready, unverified, sourceMissing, targetConflict, reconciliationRequired, restored
    public var explanationKey: String { "security.recovery." + rawValue }
}
