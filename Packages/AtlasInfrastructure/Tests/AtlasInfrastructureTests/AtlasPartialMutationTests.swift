import XCTest
import AtlasApplication
import AtlasDomain
import AtlasFileSafety
@testable import AtlasInfrastructure

final class AtlasPartialMutationTests: XCTestCase {
    func testPartialResultsAndDuplicateRequestsDoNotMoveRemainingFiles() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("input"), output = home.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = AtlasActionPlanRegistry()
        let intents = try ["a", "b", "c"].map { name -> AtlasFileOperationIntent in
            let source = root.appendingPathComponent(name)
            try Data(name.utf8).write(to: source)
            return .init(entryID: UUID(), kind: .organize, sourcePath: source.path, destinationPath: output.appendingPathComponent(name).path, expectedIdentity: try AtlasFileIdentityReader.read(source))
        }
        let plan = try registry.register(plan: ActionPlan(title: "plan", items: [], estimatedBytes: 3), operations: intents, policyRevision: 1)
        let service = try AtlasNativeMutationService(directoryURL: home.appendingPathComponent("state"), registry: registry,
            context: .init(homeDirectoryURL: home, organizerRoots: [root]), mutator: ConflictAfterFirst(output: output))
        let requestID = UUID(), selection = plan.plan.executionSelection!
        let result = try await service.execute(selection: selection, requestID: requestID)
        XCTAssertEqual(result.operations.map(\.state), [.moved, .failed])
        XCTAssertEqual(result.unstartedEntryIDs, [intents[2].entryID])
        XCTAssertEqual(result.operations.first?.destinationPath, output.appendingPathComponent("a").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("c").path))
        let repeated = try await service.execute(selection: selection, requestID: requestID)
        XCTAssertEqual(repeated, result)
        let changed = AtlasExecutionSelection(planID: selection.planID, planDigest: selection.planDigest, selectedEntryIDs: [intents[2].entryID])
        do { _ = try await service.execute(selection: changed, requestID: requestID); XCTFail("request ID substitution") } catch {}
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("b")), Data("sentinel".utf8))
        let restarted = try AtlasNativeMutationService(directoryURL: home.appendingPathComponent("state"), registry: AtlasActionPlanRegistry(),
            context: .init(homeDirectoryURL: home, organizerRoots: [root]))
        XCTAssertEqual(try restarted.status(requestID: requestID), result)
        let persisted = try AtlasActionPlanRegistry.readPersistedPlan(directoryURL: home.appendingPathComponent("state"), id: plan.plan.id)
        XCTAssertEqual(persisted, plan)
    }
}
private struct ConflictAfterFirst: AtlasNativeFileMutating {
    let output: URL
    func perform(_ intent: AtlasFileOperationIntent, validated: AtlasValidatedFileOperation) throws -> URL {
        _ = try AtlasFileMover.moveWithoutReplacing(validated)
        try Data("sentinel".utf8).write(to: output.appendingPathComponent("b"))
        return URL(fileURLWithPath: intent.destinationPath!)
    }
}
