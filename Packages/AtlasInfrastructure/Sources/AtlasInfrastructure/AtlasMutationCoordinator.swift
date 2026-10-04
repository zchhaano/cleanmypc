import Darwin
import Foundation

public final class AtlasMutationLease: @unchecked Sendable {
    private let descriptor: Int32
    private let device: Int32
    private let inode: UInt64
    fileprivate init(descriptor: Int32, directory: AtlasSecureDirectory) throws {
        self.descriptor = descriptor
        var info = stat()
        guard fstat(directory.descriptor, &info) == 0 else { throw AtlasJournalError.unsafeStorage }
        device = info.st_dev; inode = UInt64(info.st_ino)
    }
    func validates(_ directory: AtlasSecureDirectory) -> Bool {
        var info = stat()
        return fstat(directory.descriptor, &info) == 0 && info.st_dev == device && UInt64(info.st_ino) == inode
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
public final class AtlasMutationCoordinator: @unchecked Sendable {
    private let directory: AtlasSecureDirectory
    public init(directoryURL: URL) throws { directory = try AtlasSecureDirectory(directoryURL) }
    private func acquire() throws -> AtlasMutationLease {
        let fd = try directory.openFile("mutation.lock", flags: O_RDWR | O_CREAT)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw AtlasJournalError.busy }
        do { return try AtlasMutationLease(descriptor: fd, directory: directory) }
        catch { flock(fd, LOCK_UN); close(fd); throw error }
    }
    public func withLease<T: Sendable>(_ body: @Sendable (AtlasMutationLease) async throws -> T) async throws -> T {
        let lease = try acquire()
        return try await withExtendedLifetimeAsync(lease, body: body)
    }
    func withSynchronousLease<T>(_ body: () throws -> T) throws -> T {
        let lease = try acquire()
        return try withExtendedLifetime(lease) { try body() }
    }
    private func withExtendedLifetimeAsync<T: Sendable>(_ lease: AtlasMutationLease, body: @Sendable (AtlasMutationLease) async throws -> T) async throws -> T {
        defer { withExtendedLifetime(lease) {} }
        return try await body(lease)
    }
}
