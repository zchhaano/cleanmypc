import XCTest
@testable import AtlasPrivilegedHelperCore
import AtlasProtocol
import AtlasDomain
import AtlasInfrastructure
import AtlasFileSafety

final class AtlasPrivilegedHelperTests: XCTestCase {
    func testRepairOwnershipIsDisabledAndPreservesFile() throws {
        let root = makeAllowedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Sample.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("sample".utf8).write(to: fileURL)
        let executor = AtlasPrivilegedHelperActionExecutor(allowedRoots: [root.path])
        XCTAssertThrowsError(try executor.perform(AtlasHelperAction(kind: .repairOwnership, targetPath: fileURL.path)))
        XCTAssertEqual(try String(contentsOf: fileURL), "sample")
    }

    func testRestoreWithoutJournalProofIsRejected() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        let root = home.appendingPathComponent("Applications", isDirectory: true)
        let sourceURL = trash.appendingPathComponent("Sample.app", isDirectory: true)
        let destinationURL = root.appendingPathComponent("Sample.app", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executor = AtlasPrivilegedHelperActionExecutor(allowedRoots: [root.path], homeDirectoryURL: home)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertThrowsError(try executor.perform(AtlasHelperAction(kind: .restoreItem, targetPath: sourceURL.path, destinationPath: destinationURL.path)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testRemoveLaunchServiceRejectsNonPlistPath() throws {
        let root = makeAllowedRoot()
        let fileURL = root.appendingPathComponent("not-a-plist.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("sample".utf8).write(to: fileURL)

        let executor = AtlasPrivilegedHelperActionExecutor(allowedRoots: [root.path])

        XCTAssertThrowsError(try executor.perform(AtlasHelperAction(kind: .removeLaunchService, targetPath: fileURL.path)))
    }

    func testValidPlanProofIsCheckedButProductionPerformRemainsClosed() throws {
        let home = makeAllowedRoot(); defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Caches"), state = home.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("a"); try Data("keep".utf8).write(to: source)
        let identity = try AtlasFileIdentityReader.read(source)
        let intent = AtlasFileOperationIntent(entryID: UUID(), kind: .smartClean, sourcePath: source.path, expectedIdentity: identity)
        let plan = try AtlasActionPlanRegistry().register(plan: .init(title: "proof", items: [], estimatedBytes: 4), operations: [intent], policyRevision: 1)
        let journal = try AtlasOperationJournal(directoryURL: state)
        try JSONEncoder().encode(plan).write(to: state.appendingPathComponent("plan-\(plan.plan.id.uuidString).json"))
        let record = AtlasOperationRecord(requestID: UUID(), planID: plan.plan.id, planDigest: plan.digest, entryID: intent.entryID, kind: .smartClean, sourcePath: source.path, sourceIdentity: identity)
        try journal.append(record)
        let executor = AtlasPrivilegedHelperActionExecutor(homeDirectoryURL: home, evidenceDirectoryURL: state)
        var action = AtlasHelperAction(kind: .trashItems, targetPath: source.path, operationID: record.operationID, planID: plan.plan.id, planDigest: plan.digest, policyRevision: 1, expectedIdentity: identity)
        _ = try executor.validateEvidence(action)
        XCTAssertThrowsError(try executor.perform(action))
        for invalid in ["wrong-digest", "wrong-operation", "wrong-path"] {
            var forged = action
            if invalid == "wrong-digest" { forged.planDigest = "wrong" }
            if invalid == "wrong-operation" { forged.operationID = UUID() }
            if invalid == "wrong-path" { forged.targetPath = root.path }
            XCTAssertThrowsError(try executor.validateEvidence(forged))
        }
        action.kind = .repairOwnership
        XCTAssertThrowsError(try executor.validateEvidence(action))
        XCTAssertEqual(try Data(contentsOf: source), Data("keep".utf8))
    }

    private func makeAllowedRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
