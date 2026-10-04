import XCTest
import AtlasApplication
import AtlasDomain
import AtlasInfrastructure
import AtlasProtocol
@testable import AtlasApp

@MainActor
final class AtlasAppSafetyTests: XCTestCase {
    private func repository() -> AtlasWorkspaceRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(stateFileURL: root.appendingPathComponent("workspace.json"))
    }
    func testCorruptStateShowsLedgerFailureAndPreservesBytes() throws {
        let repo = repository(); _ = try repo.saveState(.empty)
        try Data("broken".utf8).write(to: repo.directoryURL.appendingPathComponent("workspace.json"))
        let model = AtlasAppModel(repository: repo, workerService: AtlasScaffoldWorkerService(repository: repo), ledgerNumberStore: InMemoryLedgerNumberStore())
        XCTAssertTrue(model.snapshot.recoveryItems.isEmpty)
        XCTAssertTrue(model.ledgerOutcome?.isError == true)
        XCTAssertEqual(try Data(contentsOf: repo.directoryURL.appendingPathComponent("workspace.json")), Data("broken".utf8))
    }
    func testClosedExecutionPreservesRealFileAndNeverClaimsCompletion() async throws {
        let repo = repository(); _ = try repo.saveState(.empty)
        let file = repo.directoryURL.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: file)
        let worker = AtlasScaffoldWorkerService(repository: repo, smartCleanScanProvider: SafetyScan(path: file.path))
        let model = AtlasAppModel(repository: repo, workerService: worker, ledgerNumberStore: InMemoryLedgerNumberStore())
        await model.runSmartCleanScan()
        XCTAssertFalse(model.canExecuteCurrentSmartCleanPlan)
        await model.executeCurrentPlan()
        XCTAssertFalse(model.smartCleanExecutionCompleted)
        XCTAssertNotNil(model.smartCleanExecutionIssue)
        XCTAssertTrue(model.snapshot.recoveryItems.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
    }
    func testLegacyRestorePreservesRecordAndReportsFailure() async throws {
        let repo = repository(); var state = AtlasWorkspaceState.empty
        let item = RecoveryItem(title: "legacy", detail: "", originalPath: "/missing", bytes: 1, deletedAt: .distantPast)
        state.snapshot.recoveryItems = [item]; _ = try repo.saveState(state)
        let model = AtlasAppModel(repository: repo, workerService: AtlasScaffoldWorkerService(repository: repo), ledgerNumberStore: InMemoryLedgerNumberStore())
        await model.restoreRecoveryItem(item.id)
        XCTAssertEqual(model.snapshot.recoveryItems.map(\.id), [item.id])
        XCTAssertTrue(model.ledgerOutcome?.isError == true)
    }
    func testRejectedResponseRetainsConfirmedRecoverySnapshot() async throws {
        let repo = repository(); _ = try repo.saveState(.empty)
        let item = RecoveryItem(title: "confirmed", detail: "", originalPath: "/missing", bytes: 1, deletedAt: Date(), recoveryAvailability: .reconciliationRequired)
        var snapshot = AtlasWorkspaceState.empty.snapshot; snapshot.recoveryItems = [item]
        let model = AtlasAppModel(repository: repo, workerService: SafetyRejectedWorker(snapshot: snapshot), ledgerNumberStore: InMemoryLedgerNumberStore())
        await model.inspectPermissions()
        XCTAssertEqual(model.snapshot.recoveryItems.map(\.id), [item.id])
    }
    func testUnknownMutationQueriesStatusAndNeverReplays() async throws {
        let repo = repository(); _ = try repo.saveState(.empty)
        let worker = SafetyUnknownWorker()
        let model = AtlasAppModel(repository: repo, workerService: worker, ledgerNumberStore: InMemoryLedgerNumberStore())
        model.applyUITestFixture("review-executable")
        await model.executeCurrentPlan()
        let commands = await worker.commands
        XCTAssertEqual(commands.count, 2)
        guard case .executePlan = commands[0], case .requestStatus = commands[1] else { return XCTFail("Mutation was replayed instead of queried") }
        XCTAssertNotNil(model.pendingUnknownRequestID)
        XCTAssertTrue(model.unknownRequestStatus?.requiresReconciliation == true)
        XCTAssertFalse(model.smartCleanExecutionCompleted)
        XCTAssertFalse(model.canExecuteCurrentSmartCleanPlan)
    }
    func testSourceMissingFixtureCarriesTruthfulAvailability() throws {
        let model = AtlasAppModel(repository: repository(), ledgerNumberStore: InMemoryLedgerNumberStore())
        model.applyUITestFixture("recovery-source-missing")
        XCTAssertEqual(model.snapshot.recoveryItems.first?.recoveryAvailability, .sourceMissing)
        XCTAssertFalse(AtlasSafetyCapabilities.fileMutationsEnabled)
    }
}
private struct SafetyScan: AtlasSmartCleanScanProviding {
    let path: String
    func collectSmartCleanScan() async throws -> AtlasSmartCleanScanResult {
        .init(findings: [.init(title: "sentinel", detail: "", bytes: 4, risk: .safe, category: "cache", targetPaths: [path])], summary: "fixture")
    }
}
private struct SafetyRejectedWorker: AtlasWorkerServing {
    let snapshot: AtlasWorkspaceSnapshot
    func submit(_ request: AtlasRequestEnvelope) async throws -> AtlasWorkerCommandResult {
        .init(request: request, response: .init(requestID: request.id, response: .rejected(code: .executionUnavailable, reason: "save failed")), events: [], snapshot: snapshot)
    }
}

private actor SafetyUnknownWorker: AtlasWorkerServing {
    var commands: [AtlasCommand] = []
    func submit(_ request: AtlasRequestEnvelope) async throws -> AtlasWorkerCommandResult {
        commands.append(request.command)
        if case let .requestStatus(requestID) = request.command {
            return .init(request: request, response: .init(requestID: request.id, response: .requestStatus(.init(requestID: requestID, operations: []))), events: [], snapshot: AtlasWorkspaceState.empty.snapshot)
        }
        throw AtlasXPCTransportError.resultUnknown(requestID: request.id)
    }
}
