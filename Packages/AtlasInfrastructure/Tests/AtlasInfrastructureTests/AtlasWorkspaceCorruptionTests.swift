import XCTest
import Darwin
import AtlasApplication
@testable import AtlasInfrastructure
final class AtlasWorkspaceCorruptionTests: XCTestCase {
    func testFIFOStateAndJournalAreRejectedWithoutWaitingForWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try AtlasSecureDirectory(root)
        for name in ["state.json", "operations.journal"] {
            XCTAssertEqual(mkfifo(root.appendingPathComponent(name).path, 0o600), 0)
            let started = Date()
            XCTAssertThrowsError(try storage.readFile(name))
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        }
    }
    func testStaleSnapshotCannotOverwriteAnotherWorkersSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = AtlasWorkspaceRepository(stateFileURL: root.appendingPathComponent("state.json"))
        let initial = try repo.loadState()
        var newer = initial; newer.settings.recoveryRetentionDays = initial.settings.recoveryRetentionDays + 1
        try repo.saveState(newer, expectedState: initial)
        XCTAssertThrowsError(try repo.saveState(initial, expectedState: initial))
        XCTAssertEqual(try repo.loadState(), newer)
    }
    func testCorruptOrFutureStateIsPreservedAndNeverSeeded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("state.json")
        let repo = AtlasWorkspaceRepository(stateFileURL: url)
        for bytes in [Data("broken".utf8), try JSONEncoder().encode(AtlasPersistedWorkspaceState(schemaVersion: 99, state: AtlasScaffoldWorkspace.state()))] {
            try bytes.write(to: url)
            XCTAssertThrowsError(try repo.loadState())
            XCTAssertThrowsError(try repo.saveState(AtlasScaffoldWorkspace.state()))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }
    func testMissingStateStartsEmptyAndLegacyMigrationHasBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        let repo = AtlasWorkspaceRepository(stateFileURL: url)
        XCTAssertTrue(try repo.loadState().snapshot.apps.isEmpty)
        let old = try JSONEncoder().encode(AtlasPersistedWorkspaceState(schemaVersion: 1, state: AtlasScaffoldWorkspace.state()))
        try old.write(to: url)
        XCTAssertFalse(try repo.loadState().snapshot.apps.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("state.json.schema1.backup")), old)
    }
}
