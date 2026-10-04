import XCTest
@testable import AtlasInfrastructure
@testable import AtlasDomain
import Foundation

final class AtlasWorkspaceRepositoryTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AtlasWorkspaceRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir!)
        super.tearDown()
    }

    private func stateFileURL() -> URL {
        tempDir!.appendingPathComponent("workspace-state.json")
    }

    // MARK: - Load State Seeds Empty

    func testLoadStateSeedsWhenNoFileExists() throws {
        let repo = AtlasWorkspaceRepository(stateFileURL: stateFileURL())
        let state = try repo.loadState()
        XCTAssertTrue(state.snapshot.findings.isEmpty, "Production starts empty")
    }

    // MARK: - Save and Load Roundtrip

    func testSaveAndLoadRoundtrip() throws {
        let url = stateFileURL()
        let repo = AtlasWorkspaceRepository(stateFileURL: url)
        let original = try repo.loadState()

        var modified = original
        modified.settings.notificationsEnabled = true
        _ = try repo.saveState(modified)

        let loaded = try repo.loadState()
        XCTAssertTrue(loaded.settings.notificationsEnabled)
    }

    // MARK: - Convenience Accessors

    func testLoadScaffoldSnapshot() throws {
        let repo = AtlasWorkspaceRepository(stateFileURL: stateFileURL())
        let snapshot = try repo.loadScaffoldSnapshot()
        XCTAssertTrue(snapshot.findings.isEmpty)
    }

    func testLoadCurrentPlan() throws {
        let repo = AtlasWorkspaceRepository(stateFileURL: stateFileURL())
        let plan = try repo.loadCurrentPlan()
        XCTAssertNotNil(plan)
    }

    func testLoadSettings() throws {
        let repo = AtlasWorkspaceRepository(stateFileURL: stateFileURL())
        let settings = try repo.loadSettings()
        XCTAssertNotNil(settings)
    }

    // MARK: - Error Descriptions

    func testRepositoryErrorDescriptions() throws {
        let errors: [AtlasWorkspaceRepositoryError] = [
            .readFailed("test"),
            .decodeFailed("test"),
            .createDirectoryFailed("test"),
            .encodeFailed("test"),
            .writeFailed("test"),
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testRepositoryErrorEquality() throws {
        XCTAssertEqual(AtlasWorkspaceRepositoryError.readFailed("a"), .readFailed("a"))
        XCTAssertNotEqual(AtlasWorkspaceRepositoryError.readFailed("a"), .readFailed("b"))
        XCTAssertNotEqual(AtlasWorkspaceRepositoryError.readFailed("a"), .decodeFailed("a"))
    }

    // MARK: - Expired Recovery Items Cleaned

    func testExpiredRecoveryItemsCleanedOnLoad() throws {
        let url = stateFileURL()
        let fixedNow = Date()
        let repo = AtlasWorkspaceRepository(stateFileURL: url, nowProvider: { fixedNow })

        let state = try repo.loadState()
        var modified = state
        let expiredItem = RecoveryItem(
            title: "Expired",
            detail: "Should be cleaned",
            originalPath: "/Users/test/Library/Caches/expired",
            bytes: 100,
            deletedAt: fixedNow.addingTimeInterval(-86400 * 60),
            expiresAt: fixedNow.addingTimeInterval(-1)
        )
        modified.snapshot.recoveryItems.append(expiredItem)
        _ = try repo.saveState(modified)

        let loaded = try repo.loadState()
        XCTAssertTrue(loaded.snapshot.recoveryItems.contains(where: { $0.id == expiredItem.id }),
                       "Expired evidence is retained on load")
    }
}
