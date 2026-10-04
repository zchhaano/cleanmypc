import XCTest
import AtlasDomain
import AtlasProcessSupport
@testable import AtlasInfrastructure
final class AtlasRecoveryCrashTests: XCTestCase {
    func testActualChildExitAtEachMoveAndRestoreJournalWindow() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runner = AtlasProcessRunner()
        let location = try await runner.run(.init(executableURL: URL(fileURLWithPath: "/usr/bin/swift"), arguments: ["build", "--package-path", repo.appendingPathComponent("Testing").path, "--show-bin-path"], timeout: .seconds(30)))
        let binary = URL(fileURLWithPath: String(decoding: location.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent("AtlasRecoveryCrashHarness")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path), "Build Testing crash harness before this suite")
        for stage in ["afterPlanned", "afterMove", "afterMoved", "afterRestore"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("input"), withIntermediateDirectories: true)
            try Data("test-marker".utf8).write(to: root.appendingPathComponent(".atlas-crash-test"))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(".atlas-crash-test").path)
            try Data("original".utf8).write(to: root.appendingPathComponent("input/a"))
            let child = try await runner.run(.init(executableURL: binary, arguments: [root.path, stage], timeout: .seconds(3)))
            XCTAssertEqual(child.exitStatus, 73, stage)
            let records = try await AtlasJournalReconciler(directoryURL: root.appendingPathComponent("state")).reconcile()
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.state, stage == "afterMoved" ? .moved : .reconciliationRequired, stage)
            let source = root.appendingPathComponent("input/a"), destination = root.appendingPathComponent("output/a")
            let actual = FileManager.default.fileExists(atPath: source.path) ? source : destination
            XCTAssertEqual(try Data(contentsOf: actual), Data("original".utf8))
        }
    }

    func testPlannedOnlyRecordRemainsUnknownAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try AtlasOperationJournal(directoryURL: root)
        let record = AtlasOperationRecord(requestID: UUID(), planID: UUID(), planDigest: "digest", entryID: UUID(), kind: .organize, sourcePath: "/not-a-real-source", destinationPath: "/not-a-real-target", sourceIdentity: .init(device: 1, inode: 2, birthTimeNanoseconds: 3, kind: .regularFile))
        try journal.append(record)
        let reconciler = try AtlasJournalReconciler(directoryURL: root)
        let restarted = try await reconciler.reconcile()
        XCTAssertEqual(restarted.count, 1)
        XCTAssertEqual(restarted[0].state, .reconciliationRequired)
        let repeated = try await reconciler.reconcile()
        XCTAssertEqual(repeated[0].state, .reconciliationRequired)
        XCTAssertEqual(try journal.replay().count, 2)
    }
}
