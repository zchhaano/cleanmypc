import XCTest
import AtlasApplication
@testable import AtlasInfrastructure
final class AtlasWorkspaceCorruptionTests: XCTestCase {
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
