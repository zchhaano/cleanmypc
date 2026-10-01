import XCTest
import AtlasDomain
import AtlasProtocol
@testable import AtlasInfrastructure

final class AtlasMutationAuthorizationTests: XCTestCase {
    func testLegacyWritesAndRestoreCannotBypassDefaultClosedCapability() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = AtlasScaffoldWorkerService(repository: AtlasWorkspaceRepository(stateFileURL: root.appendingPathComponent("state.json")))
        for command in [AtlasCommand.executePlan(planID: UUID()), .fileOrganizerExecutePlan(planID: UUID()), .executeAppUninstall(appID: UUID()), .restoreItems(taskID: UUID(), itemIDs: [UUID()])] {
            let result = try await worker.submit(AtlasRequestEnvelope(command: command))
            guard case .rejected = result.response.response else { return XCTFail("Mutation must fail closed") }
            XCTAssertTrue(result.snapshot.recoveryItems.isEmpty || result.snapshot.recoveryItems.allSatisfy { $0.restoreMappings?.isEmpty != false })
        }
    }
}
