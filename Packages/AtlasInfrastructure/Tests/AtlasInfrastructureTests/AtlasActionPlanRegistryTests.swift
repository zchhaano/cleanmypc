import AtlasDomain
import Foundation
import XCTest
@testable import AtlasInfrastructure

final class AtlasActionPlanRegistryTests: XCTestCase {
    private func operation(_ id: UUID = UUID(), destination: String = "/Users/fixture/Organized/a.txt", inode: UInt64 = 1) -> AtlasFileOperationIntent {
        AtlasFileOperationIntent(entryID: id, kind: .organize, sourcePath: "/Users/fixture/Documents/\(id).txt", destinationPath: destination, expectedIdentity: AtlasFileIdentity(device: 1, inode: inode, birthTimeNanoseconds: 1, kind: .regularFile))
    }
    func testPlanAccepts65536EntriesWithoutTrap() throws {
        let operations = (0..<65536).map { _ in operation() }
        let registry = AtlasActionPlanRegistry()
        let plan = ActionPlan(title: "large", items: [], estimatedBytes: 0)
        let registered = try registry.register(plan: plan, operations: operations, policyRevision: 1)
        XCTAssertEqual(registered.operations.count, 65536)
        XCTAssertEqual(registered.digest.count, 64)
        XCTAssertEqual(registered.plan.id, plan.id)
    }
    func testDigestChangesForDestinationIdentityAndPolicy() throws {
        let id = UUID(), registry = AtlasActionPlanRegistry()
        let plan = ActionPlan(title: "test", items: [], estimatedBytes: 0)
        let original = try registry.register(plan: plan, operations: [operation(id)], policyRevision: 1)
        for (op, revision) in [(operation(id, destination: "/Users/fixture/Other/a.txt"), 1), (operation(id, inode: 2), 1), (operation(id), 2)] {
            let changed = try registry.register(plan: plan, operations: [op], policyRevision: revision)
            XCTAssertNotEqual(changed.digest, original.digest)
        }
    }
    func testSelectionRejectsUnknownDuplicateEmptyAndStaleIDs() throws {
        let op = operation(), registry = AtlasActionPlanRegistry()
        let registered = try registry.register(plan: ActionPlan(title: "test", items: [], estimatedBytes: 0), operations: [op], policyRevision: 1)
        let valid = AtlasExecutionSelection(planID: registered.plan.id, planDigest: registered.digest, selectedEntryIDs: [op.entryID])
        XCTAssertEqual(try registry.resolve(valid), [op])
        for ids in [[], [UUID()], [op.entryID, op.entryID]] {
            XCTAssertThrowsError(try registry.resolve(AtlasExecutionSelection(planID: valid.planID, planDigest: valid.planDigest, selectedEntryIDs: ids)))
        }
        XCTAssertThrowsError(try registry.resolve(AtlasExecutionSelection(planID: valid.planID, planDigest: "stale", selectedEntryIDs: valid.selectedEntryIDs)))
    }
    func testExecutionRejects1001SelectionsAndDuplicateObjects() throws {
        let registry = AtlasActionPlanRegistry(), ops = (0..<1001).map { _ in operation() }
        let plan = try registry.register(plan: ActionPlan(title: "large", items: [], estimatedBytes: 0), operations: ops, policyRevision: 1)
        XCTAssertThrowsError(try registry.resolve(AtlasExecutionSelection(planID: plan.plan.id, planDigest: plan.digest, selectedEntryIDs: ops.map(\.entryID))))
        XCTAssertThrowsError(try registry.register(plan: plan.plan, operations: [ops[0], ops[0]], policyRevision: 1))
    }
}
