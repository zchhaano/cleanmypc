import XCTest
import AtlasDomain
@testable import AtlasInfrastructure

final class AtlasOperationJournalTests: XCTestCase {
    func testDurableReplayAndCorruptTailPreservesBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try AtlasOperationJournal(directoryURL: root)
        let identity = AtlasFileIdentity(device: 1, inode: 2, birthTimeNanoseconds: 3, kind: .regularFile)
        var record = AtlasOperationRecord(requestID: UUID(), planID: UUID(), planDigest: "digest", entryID: UUID(), kind: .organize, sourcePath: "/a", destinationPath: "/b", sourceIdentity: identity)
        try journal.append(record)
        record.state = .moved; record.destinationIdentity = identity
        try journal.append(record)
        XCTAssertEqual(try journal.replay().map(\.sequence), [1,2])
        let url = root.appendingPathComponent("operations.journal")
        let good = try Data(contentsOf: url)
        try (good + Data([1,2])).write(to: url)
        let corrupt = try Data(contentsOf: url)
        XCTAssertThrowsError(try journal.replay())
        let inspection = try journal.inspect()
        XCTAssertTrue(inspection.isCorrupt)
        XCTAssertEqual(inspection.records.map(\.sequence), [1, 2])
        XCTAssertThrowsError(try journal.append(record))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
    func testTransitionAndSymlinkRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try AtlasOperationJournal(directoryURL: root)
        var record = AtlasOperationRecord(requestID: UUID(), planID: UUID(), planDigest: "digest", entryID: UUID(), kind: .organize, sourcePath: "/a", sourceIdentity: .init(device: 1, inode: 1, birthTimeNanoseconds: 1, kind: .regularFile))
        record.state = .restored
        XCTAssertThrowsError(try journal.append(record))
        let outside = root.appendingPathComponent("sentinel"); try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("operations.journal"), withDestinationURL: outside)
        XCTAssertThrowsError(try journal.append(record))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }
}
