import Darwin
import Foundation

public enum AtlasJournalError: Error, Equatable, Sendable { case unsafeStorage, io(Int32), corrupt, invalidTransition, busy, invalidRequest }

/// Descriptor-bound private storage. Ancestors may be system-owned; final directory must belong to the current user.
final class AtlasSecureDirectory: @unchecked Sendable {
    let descriptor: Int32
    init(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), !url.pathComponents.contains("..") else { throw AtlasJournalError.unsafeStorage }
        let canonical: String
        if path == "/var" || path.hasPrefix("/var/") || path == "/tmp" || path.hasPrefix("/tmp/") { canonical = "/private" + path } else { canonical = path }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw AtlasJournalError.io(errno) }
        do {
            for part in canonical.split(separator: "/").map(String.init) {
                var next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    guard mkdirat(parent, part, 0o700) == 0 || errno == EEXIST else { throw AtlasJournalError.io(errno) }
                    next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw AtlasJournalError.unsafeStorage }
                close(parent); parent = next
            }
            var info = stat()
            guard fstat(parent, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else { throw AtlasJournalError.unsafeStorage }
            guard fchmod(parent, 0o700) == 0 else { throw AtlasJournalError.io(errno) }
            descriptor = parent
        } catch { close(parent); throw error }
    }
    deinit { close(descriptor) }
    func openFile(_ name: String, flags: Int32) throws -> Int32 {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { throw AtlasJournalError.unsafeStorage }
        let fd = openat(descriptor, name, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtlasJournalError.io(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { close(fd); throw AtlasJournalError.unsafeStorage }
        return fd
    }
    func readFile(_ name: String, maximum: Int = 128*1024*1024) throws -> Data? {
        let fd: Int32
        do { fd = try openFile(name, flags: O_RDONLY) } catch AtlasJournalError.io(ENOENT) { return nil }
        defer { close(fd) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n == 0 { return data }
            if n < 0 { if errno == EINTR { continue }; throw AtlasJournalError.io(errno) }
            guard data.count <= maximum - n else { throw AtlasJournalError.corrupt }
            data.append(contentsOf: buffer.prefix(n))
        }
    }
    func writeAtomic(_ name: String, data: Data, replacing: Bool = true) throws {
        let temporary = ".atlas-\(UUID().uuidString)"
        let fd = try openFile(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { close(fd); unlinkat(descriptor, temporary, 0) }
        try Self.writeAll(fd, data: data)
        guard fsync(fd) == 0 else { throw AtlasJournalError.io(errno) }
        if replacing {
            if let old = try? openFile(name, flags: O_RDONLY) { close(old) }
            else {
                var info = stat()
                if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw AtlasJournalError.unsafeStorage }
            }
        }
        let flags = replacing ? UInt32(0) : UInt32(RENAME_EXCL)
        guard renameatx_np(descriptor, temporary, descriptor, name, flags) == 0 else { throw AtlasJournalError.io(errno) }
        guard fsync(descriptor) == 0 else { throw AtlasJournalError.io(errno) }
    }
    static func writeAll(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: offset), data.count-offset)
                if n < 0 { if errno == EINTR { continue }; throw AtlasJournalError.io(errno) }
                guard n > 0 else { throw AtlasJournalError.io(EIO) }
                offset += n
            }
        }
    }
}
