import AtlasDomain
import Foundation
import XCTest
@testable import AtlasFileSafety

final class AtlasFileSafetyTests: XCTestCase {
    func testPolicyAndMoverPreserveConflictsAndUnselectedFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let sourceRoot = home.appendingPathComponent("Documents")
        let destinationRoot = home.appendingPathComponent("Organized")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("chosen.txt")
        let other = sourceRoot.appendingPathComponent("other.txt")
        let target = destinationRoot.appendingPathComponent("chosen.txt")
        try Data("chosen".utf8).write(to: source)
        try Data("other".utf8).write(to: other)
        try Data("conflict".utf8).write(to: target)
        let intent = AtlasFileOperationIntent(entryID: UUID(), kind: .organize, sourcePath: source.path, destinationPath: target.path, expectedIdentity: try AtlasFileIdentityReader.read(source))
        let context = AtlasFilePolicyContext(homeDirectoryURL: home, organizerRoots: [sourceRoot])
        XCTAssertThrowsError(try AtlasFileSafetyPolicy.validate(intent, context: context))
        XCTAssertEqual(try String(contentsOf: source), "chosen")
        XCTAssertEqual(try String(contentsOf: target), "conflict")
        try FileManager.default.removeItem(at: target)
        let operation = try AtlasFileSafetyPolicy.validate(intent, context: context)
        _ = try AtlasFileMover.moveWithoutReplacing(operation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: target), "chosen")
        XCTAssertEqual(try String(contentsOf: other), "other")
    }

    func testPolicyRejectsRootSymlinksPackagesAndChangedIdentity() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let docs = home.appendingPathComponent("Documents")
        let package = docs.appendingPathComponent("Example.app/Contents")
        let dest = home.appendingPathComponent("Organized/a.txt")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("a.txt")
        try Data("protected".utf8).write(to: file)
        let context = AtlasFilePolicyContext(homeDirectoryURL: home, organizerRoots: [docs])
        let intent = AtlasFileOperationIntent(entryID: UUID(), kind: .organize, sourcePath: file.path, destinationPath: dest.path, expectedIdentity: try AtlasFileIdentityReader.read(file))
        XCTAssertThrowsError(try AtlasFileSafetyPolicy.validate(intent, context: context))
        let link = docs.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)
        XCTAssertThrowsError(try AtlasFileIdentityReader.read(link.appendingPathComponent("a.txt")))
        XCTAssertThrowsError(try AtlasFileSafetyPolicy.validateOrganizerRoot(home, homeDirectoryURL: home))
        XCTAssertEqual(try String(contentsOf: file), "protected")
    }
    func testSelectedObjectReplacementAfterValidationIsRejected() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let docs = home.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let file = docs.appendingPathComponent("a"), target = home.appendingPathComponent("Organized/a")
        try Data("selected".utf8).write(to: file)
        let intent = AtlasFileOperationIntent(entryID: UUID(), kind: .organize, sourcePath: file.path, destinationPath: target.path, expectedIdentity: try AtlasFileIdentityReader.read(file))
        let validated = try AtlasFileSafetyPolicy.validate(intent, context: .init(homeDirectoryURL: home, organizerRoots: [docs]))
        try FileManager.default.moveItem(at: file, to: docs.appendingPathComponent("original"))
        try Data("replacement".utf8).write(to: file)
        XCTAssertThrowsError(try AtlasFileMover.moveWithoutReplacing(validated))
        XCTAssertEqual(try Data(contentsOf: file), Data("replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testOpenedSourceParentDoesNotFollowReplacementLink() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let docs = home.appendingPathComponent("Documents"), outside = home.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = docs.appendingPathComponent("selected.txt"), sentinel = outside.appendingPathComponent("selected.txt")
        try Data("selected".utf8).write(to: source); try Data("protected".utf8).write(to: sentinel)
        let target = home.appendingPathComponent("Organized/selected.txt")
        let intent = AtlasFileOperationIntent(entryID: UUID(), kind: .organize, sourcePath: source.path, destinationPath: target.path, expectedIdentity: try AtlasFileIdentityReader.read(source))
        let operation = try AtlasFileSafetyPolicy.validate(intent, context: AtlasFilePolicyContext(homeDirectoryURL: home, organizerRoots: [docs]))
        try FileManager.default.moveItem(at: docs, to: home.appendingPathComponent("MovedDocuments"))
        try FileManager.default.createSymbolicLink(at: docs, withDestinationURL: outside)
        _ = try AtlasFileMover.moveWithoutReplacing(operation)
        XCTAssertEqual(try String(contentsOf: sentinel), "protected")
        XCTAssertEqual(try String(contentsOf: target), "selected")
    }

}
