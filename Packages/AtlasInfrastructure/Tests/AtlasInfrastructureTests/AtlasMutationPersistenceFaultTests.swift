import XCTest
import AtlasApplication
import AtlasDomain
import AtlasFileSafety
import AtlasProtocol
@testable import AtlasInfrastructure

final class AtlasMutationPersistenceFaultTests: XCTestCase {
    func testPlannedAppendFailurePerformsZeroMoves() async throws {
        let f = try FaultFixture(); defer { f.clean() }
        let service = try f.service(journal: FailingJournal(base: f.journal, at: .planned))
        do { _ = try await service.execute(selection: f.selection, requestID: UUID()); XCTFail("planned failure") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
    }
    func testMoveThenJournalFailureStopsAndRestartKeepsUnknownEvidence() async throws {
        let f = try FaultFixture(); defer { f.clean() }
        let service = try f.service(journal: FailingJournal(base: f.journal, at: .moved))
        let result = try await service.execute(selection: f.selection, requestID: UUID())
        XCTAssertTrue(result.requiresReconciliation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.destination.path))
        let restarted = try await AtlasJournalReconciler(directoryURL: f.state).reconcile()
        XCTAssertEqual(restarted.first?.state, .reconciliationRequired)
    }
    func testPlanPersistenceFailureDoesNotMoveOrOverwriteSentinel() async throws {
        let f = try FaultFixture(); defer { f.clean() }
        let outside = f.home.appendingPathComponent("sentinel"); try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.state.appendingPathComponent("plan-\(f.selection.planID.uuidString).json"), withDestinationURL: outside)
        do { _ = try await f.service().execute(selection: f.selection, requestID: UUID()); XCTFail("plan failure") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }
    func testSnapshotFailureIsVisibleAndCorruptBytesRemainUntouched() async throws {
        let f = try FaultFixture(); defer { f.clean() }
        let url = f.state.appendingPathComponent("workspace.json"), repo = AtlasWorkspaceRepository(stateFileURL: url)
        _ = try repo.saveState(.empty)
        let worker = AtlasScaffoldWorkerService(repository: repo)
        try Data("corrupt-after-load".utf8).write(to: url)
        let result = try await worker.submit(.init(command: .settingsSet(AtlasWorkspaceState.empty.settings)))
        guard case .rejected = result.response.response else { return XCTFail("save failure must be visible") }
        XCTAssertEqual(try Data(contentsOf: url), Data("corrupt-after-load".utf8))
    }
}
private struct FailingJournal: AtlasOperationJournaling {
    let base: AtlasOperationJournal, at: AtlasOperationState
    func append(_ record: AtlasOperationRecord) throws {
        if record.state == at || (at == .moved && record.state == .reconciliationRequired) { throw AtlasJournalError.io(28) }
        try base.append(record)
    }
    func replay() throws -> [AtlasOperationRecord] { try base.replay() }
}
private struct FaultFixture {
    let home: URL, state: URL, root: URL, source: URL, destination: URL
    let registry: AtlasActionPlanRegistry, journal: AtlasOperationJournal, selection: AtlasExecutionSelection
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        state = home.appendingPathComponent("state"); root = home.appendingPathComponent("input")
        source = root.appendingPathComponent("a"); destination = home.appendingPathComponent("output/a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try Data("original".utf8).write(to: source)
        journal = try AtlasOperationJournal(directoryURL: state); registry = AtlasActionPlanRegistry()
        let intent = AtlasFileOperationIntent(entryID: UUID(), kind: .organize, sourcePath: source.path, destinationPath: destination.path, expectedIdentity: try AtlasFileIdentityReader.read(source))
        selection = try registry.register(plan: .init(title: "fault", items: [], estimatedBytes: 8), operations: [intent], policyRevision: 1).plan.executionSelection!
    }
    func service(journal: (any AtlasOperationJournaling)? = nil) throws -> AtlasNativeMutationService {
        try .init(directoryURL: state, registry: registry, context: .init(homeDirectoryURL: home, organizerRoots: [root]), journal: journal)
    }
    func clean() { try? FileManager.default.removeItem(at: home) }
}
