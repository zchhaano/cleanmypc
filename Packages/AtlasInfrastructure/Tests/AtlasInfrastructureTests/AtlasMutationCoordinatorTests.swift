import XCTest
@testable import AtlasInfrastructure
final class AtlasMutationCoordinatorTests: XCTestCase {
    func testSnapshotPublicationUsesExistingBoundLeaseAndRejectsForeignLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = AtlasWorkspaceRepository(stateFileURL: root.appendingPathComponent("state.json"))
        let initial = try repo.loadState()
        let coordinator = try AtlasMutationCoordinator(directoryURL: root)
        try await coordinator.withLease { lease in
            XCTAssertThrowsError(try repo.saveState(initial))
            XCTAssertEqual(try repo.saveState(initial, expectedState: initial, lease: lease), initial)
            let foreign = AtlasWorkspaceRepository(stateFileURL: root.appendingPathComponent("other/state.json"))
            XCTAssertThrowsError(try foreign.saveState(initial, lease: lease))
        }
    }
    func testSecondCoordinatorIsBusyDuringAwaitAndCancellationReleasesLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try AtlasMutationCoordinator(directoryURL: root), second = try AtlasMutationCoordinator(directoryURL: root)
        let started = expectation(description: "lease held")
        let task = Task {
            try await first.withLease { _ in
                started.fulfill()
                try await Task.sleep(for: .seconds(10))
                return true
            }
        }
        await fulfillment(of: [started], timeout: 1)
        do { _ = try await second.withLease { _ in true }; XCTFail("overlap") }
        catch { XCTAssertEqual(error as? AtlasJournalError, .busy) }
        task.cancel(); _ = try? await task.value
        let acquired = try await second.withLease { _ in true }
        XCTAssertTrue(acquired)
    }
}
