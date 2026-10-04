import CryptoKit
import Darwin
import Foundation
import AtlasDomain

public struct AtlasJournalInspection: Sendable {
    public let records: [AtlasOperationRecord]
    public let isCorrupt: Bool
}

public final class AtlasOperationJournal: @unchecked Sendable {
    private let directory: AtlasSecureDirectory
    private let mutex = NSLock()
    public init(directoryURL: URL) throws { directory = try AtlasSecureDirectory(directoryURL) }
    public func append(_ input: AtlasOperationRecord) throws {
        mutex.lock(); defer { mutex.unlock() }
        let existing = try readRecords()
        var record = input
        record.sequence = UInt64(existing.count) + 1
        try validate(record, previous: existing.last { $0.operationID == record.operationID })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(record)
        guard payload.count <= 1024*1024 else { throw AtlasJournalError.corrupt }
        var size = UInt32(payload.count).bigEndian
        var frame = Data([65,84,76,49])
        frame.append(Data(bytes: &size, count: 4)); frame.append(payload); frame.append(contentsOf: SHA256.hash(data: payload))
        let fd = try directory.openFile("operations.journal", flags: O_WRONLY | O_CREAT | O_APPEND)
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw AtlasJournalError.io(errno) }
        try AtlasSecureDirectory.writeAll(fd, data: frame)
        guard fsync(fd) == 0, fsync(directory.descriptor) == 0 else { throw AtlasJournalError.io(errno) }
    }
    public func replay() throws -> [AtlasOperationRecord] { mutex.lock(); defer { mutex.unlock() }; return try readRecords() }
    /// Valid prefix is available only for read-only display. replay/append still refuse a damaged tail.
    public func inspect() throws -> AtlasJournalInspection {
        mutex.lock(); defer { mutex.unlock() }
        var records: [AtlasOperationRecord] = []
        do { _ = try readRecords(onRecord: { records.append($0) }); return .init(records: records, isCorrupt: false) }
        catch AtlasJournalError.corrupt { return .init(records: records, isCorrupt: true) }
        catch AtlasJournalError.invalidTransition { return .init(records: records, isCorrupt: true) }
    }
    private func readRecords(onRecord: (AtlasOperationRecord) -> Void = { _ in }) throws -> [AtlasOperationRecord] {
        let fd: Int32
        do { fd = try directory.openFile("operations.journal", flags: O_RDONLY) }
        catch AtlasJournalError.io(ENOENT) { return [] }
        defer { close(fd) }
        func exact(_ count: Int, allowEOF: Bool = false) throws -> Data? {
            var bytes = [UInt8](repeating: 0, count: count), offset = 0
            while offset < count {
                let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), count-offset) }
                if n < 0 { if errno == EINTR { continue }; throw AtlasJournalError.io(errno) }
                if n == 0 { if offset == 0 && allowEOF { return nil }; throw AtlasJournalError.corrupt }
                offset += n
            }
            return Data(bytes)
        }
        var result: [AtlasOperationRecord] = [], latest: [UUID: AtlasOperationRecord] = [:]
        var consumed = 0
        while let header = try exact(8, allowEOF: true) {
            guard header.prefix(4) == Data([65,84,76,49]) else { throw AtlasJournalError.corrupt }
            let size = header.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard size > 0, size <= 1024*1024, consumed < 256*1024*1024 else { throw AtlasJournalError.corrupt }
            let payload = try exact(Int(size))!, checksum = try exact(32)!
            consumed += 40 + Int(size)
            guard checksum == Data(SHA256.hash(data: payload)) else { throw AtlasJournalError.corrupt }
            let record: AtlasOperationRecord
            do { record = try JSONDecoder().decode(AtlasOperationRecord.self, from: payload) } catch { throw AtlasJournalError.corrupt }
            guard record.sequence == UInt64(result.count) + 1 else { throw AtlasJournalError.corrupt }
            try validate(record, previous: latest[record.operationID])
            latest[record.operationID] = record; result.append(record); onRecord(record)
        }
        return result
    }
    private func validate(_ r: AtlasOperationRecord, previous p: AtlasOperationRecord?) throws {
        guard r.journalVersion == 1, r.policyRevision == 1 else { throw AtlasJournalError.corrupt }
        guard let p else { guard r.state == .planned else { throw AtlasJournalError.invalidTransition }; return }
        guard r.requestID == p.requestID, r.planID == p.planID, r.planDigest == p.planDigest, r.entryID == p.entryID,
              r.findingID == p.findingID, r.kind == p.kind, r.sourcePath == p.sourcePath, r.sourceIdentity == p.sourceIdentity else { throw AtlasJournalError.corrupt }
        if p.restoreRequestID != nil { guard r.restoreRequestID == p.restoreRequestID else { throw AtlasJournalError.corrupt } }
        if r.restoreRequestID != p.restoreRequestID { guard p.state == .moved && r.state == .restorePlanned else { throw AtlasJournalError.corrupt } }
        let allowed: [AtlasOperationState: Set<AtlasOperationState>] = [
            .planned: [.moved, .failed, .reconciliationRequired], .moved: [.restorePlanned, .reconciliationRequired],
            .restorePlanned: [.restored, .reconciliationRequired], .reconciliationRequired: [], .failed: [], .restored: []]
        guard allowed[p.state, default: []].contains(r.state) else { throw AtlasJournalError.invalidTransition }
        if r.state == .moved { guard r.destinationPath != nil, r.destinationIdentity == r.sourceIdentity else { throw AtlasJournalError.corrupt } }
        if r.kind == .organize { guard r.destinationPath == p.destinationPath else { throw AtlasJournalError.corrupt } }
        if p.state != .planned { guard r.destinationPath == p.destinationPath, r.destinationIdentity == p.destinationIdentity else { throw AtlasJournalError.corrupt } }
    }
}
