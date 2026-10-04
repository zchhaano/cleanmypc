import XCTest
import AtlasApplication
import AtlasDomain
import AtlasFileSafety
@testable import AtlasInfrastructure

final class AtlasRecoveryExecutorTests: XCTestCase {
    func testSameNameReplacementIsNeverCountedOrOverwritten() async throws {
        let f = try Fixture(); defer { f.clean() }
        try FileManager.default.removeItem(at: f.destination)
        try Data("new-content".utf8).write(to: f.source)
        let result = try await f.executor.restore(operationID: f.record.operationID, requestID: UUID())
        XCTAssertEqual(result.status, .sourceMissing)
        XCTAssertEqual(try Data(contentsOf: f.source), Data("new-content".utf8))
    }
    func testConflictAndProofBasedIdempotence() async throws {
        let f = try Fixture(); defer { f.clean() }
        try Data("conflict".utf8).write(to: f.source)
        let result1 = try await f.executor.restore(operationID: f.record.operationID, requestID: UUID()).status
        XCTAssertEqual(result1, .targetConflict)
        try FileManager.default.removeItem(at: f.source)
        let result2 = try await f.executor.restore(operationID: f.record.operationID, requestID: UUID()).status
        XCTAssertEqual(result2, .restored)
        let result3 = try await f.executor.restore(operationID: f.record.operationID, requestID: UUID()).status
        XCTAssertEqual(result3, .alreadyRestored)
        try FileManager.default.removeItem(at: f.source)
        try Data("replacement".utf8).write(to: f.source)
        let result4 = try await f.executor.restore(operationID: f.record.operationID, requestID: UUID()).status
        XCTAssertEqual(result4, .reconciliationRequired)
    }
    func testInterruptedRecordRequiresReconciliationAndNeverGuessSuccess() async throws {
        let f = try Fixture(); defer { f.clean() }
        var record = f.record; record.state = .restorePlanned
        try f.journal.append(record)
        let records = try await AtlasJournalReconciler(directoryURL: f.state).reconcile()
        XCTAssertEqual(records.last?.state, .reconciliationRequired)
        let result5 = try await f.executor.restore(operationID: record.operationID, requestID: UUID()).status
        XCTAssertEqual(result5, .reconciliationRequired)
    }
}
private struct Fixture {
    let home: URL, state: URL, source: URL, destination: URL
    let journal: AtlasOperationJournal, record: AtlasOperationRecord, executor: AtlasRecoveryExecutor
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        state = home.appendingPathComponent("state"); source = home.appendingPathComponent("original"); destination = home.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source)
        let identity = try AtlasFileIdentityReader.read(source)
        journal = try AtlasOperationJournal(directoryURL: state)
        var r = AtlasOperationRecord(requestID: UUID(), planID: UUID(), planDigest: "digest", entryID: UUID(), kind: .organize, sourcePath: source.path, destinationPath: destination.path, sourceIdentity: identity)
        try journal.append(r)
        try FileManager.default.moveItem(at: source, to: destination)
        r.state = .moved; r.destinationIdentity = identity; try journal.append(r)
        record = r; executor = try AtlasRecoveryExecutor(directoryURL: state, homeDirectoryURL: home)
    }
    func clean() { try? FileManager.default.removeItem(at: home) }
}
