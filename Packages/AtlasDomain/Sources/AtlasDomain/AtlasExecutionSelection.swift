import Foundation

public enum AtlasExecutionLimits {
    public static let maximumScanEntries = 100_000
    public static let maximumMutationEntries = 1_000
}
public struct AtlasExecutionSelection: Codable, Hashable, Sendable {
    public let planID: UUID
    public let planDigest: String
    public let selectedEntryIDs: [UUID]
    public init(planID: UUID, planDigest: String, selectedEntryIDs: [UUID]) {
        self.planID = planID; self.planDigest = planDigest; self.selectedEntryIDs = selectedEntryIDs
    }
}
public struct AtlasRegisteredPlan: Codable, Hashable, Sendable {
    public let plan: ActionPlan
    public let policyRevision: Int
    public let digest: String
    public let operations: [AtlasFileOperationIntent]
    public init(plan: ActionPlan, policyRevision: Int, digest: String, operations: [AtlasFileOperationIntent]) {
        var presentation = plan
        presentation.executionDigest = digest
        presentation.executionEntryIDs = operations.map(\.entryID)
        self.plan = presentation; self.policyRevision = policyRevision; self.digest = digest; self.operations = operations
    }
}
extension ActionPlan {
    public var executionSelection: AtlasExecutionSelection? {
        guard let executionDigest, let executionEntryIDs else { return nil }
        return AtlasExecutionSelection(planID: id, planDigest: executionDigest, selectedEntryIDs: executionEntryIDs)
    }
}
