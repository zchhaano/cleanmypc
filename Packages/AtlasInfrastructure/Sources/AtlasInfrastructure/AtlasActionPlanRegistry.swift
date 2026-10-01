import AtlasDomain
import CryptoKit
import Foundation

public enum AtlasPlanRegistryError: Error, Sendable { case invalidSelection, stalePlan, tooManyEntries, duplicateObject }
public final class AtlasActionPlanRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [UUID: AtlasRegisteredPlan] = [:]
    public init() {}
    public func register(plan: ActionPlan, operations: [AtlasFileOperationIntent], policyRevision: Int) throws -> AtlasRegisteredPlan {
        guard operations.count <= AtlasExecutionLimits.maximumScanEntries else { throw AtlasPlanRegistryError.tooManyEntries }
        guard Set(operations.map(\.entryID)).count == operations.count, Set(operations.map(\.sourcePath)).count == operations.count else { throw AtlasPlanRegistryError.duplicateObject }
        let registered = AtlasRegisteredPlan(plan: plan, policyRevision: policyRevision, digest: Self.digest(operations, policyRevision: policyRevision), operations: operations)
        lock.lock(); defer { lock.unlock() }
        plans[plan.id] = registered
        return registered
    }
    public func resolve(_ selection: AtlasExecutionSelection) throws -> [AtlasFileOperationIntent] {
        guard !selection.selectedEntryIDs.isEmpty, selection.selectedEntryIDs.count <= AtlasExecutionLimits.maximumMutationEntries, Set(selection.selectedEntryIDs).count == selection.selectedEntryIDs.count else { throw AtlasPlanRegistryError.invalidSelection }
        lock.lock(); defer { lock.unlock() }
        guard let plan = plans[selection.planID], plan.digest == selection.planDigest else { throw AtlasPlanRegistryError.stalePlan }
        let selected = Set(selection.selectedEntryIDs)
        let operations = plan.operations.filter { selected.contains($0.entryID) }
        guard operations.count == selected.count else { throw AtlasPlanRegistryError.invalidSelection }
        return operations
    }
    public func registeredPlan(id: UUID) -> AtlasRegisteredPlan? {
        lock.lock(); defer { lock.unlock() }; return plans[id]
    }
    public static func digest(_ operations: [AtlasFileOperationIntent], policyRevision: Int) -> String {
        var hash = SHA256()
        func field(_ text: String) {
            let data = Data(text.utf8)
            var count = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &count) { hash.update(data: Data($0)) }
            hash.update(data: data)
        }
        field("atlas-plan-v1"); field(String(policyRevision)); field(String(operations.count))
        for op in operations.sorted(by: { $0.entryID.uuidString < $1.entryID.uuidString }) {
            field(op.entryID.uuidString); field(op.kind.rawValue); field(op.sourcePath); field(op.destinationPath ?? "")
            field(String(op.expectedIdentity.device)); field(String(op.expectedIdentity.inode)); field(String(op.expectedIdentity.birthTimeNanoseconds)); field(op.expectedIdentity.kind.rawValue)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
