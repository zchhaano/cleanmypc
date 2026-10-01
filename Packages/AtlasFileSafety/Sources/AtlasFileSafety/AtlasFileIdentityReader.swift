import AtlasDomain
import Darwin
import Foundation

public enum AtlasFileSafetyError: Error, LocalizedError, Sendable {
    case unsafePath(String), identityChanged, targetExists, unsupportedObject, filesystemError(Int32), crossVolume
    public var errorDescription: String? {
        switch self {
        case .unsafePath: return "The file is outside this operation's permitted scope."
        case .identityChanged: return "The file changed after preview. Scan again."
        case .targetExists: return "The destination already exists. No file was replaced."
        case .unsupportedObject: return "This file type cannot be changed automatically."
        case .filesystemError(let code): return "File operation failed (errno \(code))."
        case .crossVolume: return "Automatic movement between volumes is unavailable."
        }
    }
}

public enum AtlasFileIdentityReader {
    public static let protectedPackageExtensions: Set<String> = ["app", "framework", "bundle", "photoslibrary", "photolibrary", "pages", "numbers", "key"]
    public static func hasPackageAncestor(_ url: URL, includingSelf: Bool = true) -> Bool {
        var current = includingSelf ? url : url.deletingLastPathComponent()
        while current.path != "/" {
            if protectedPackageExtensions.contains(current.pathExtension.lowercased()) || (try? current.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return true }
            current.deleteLastPathComponent()
        }
        return false
    }
    public static func read(_ url: URL) throws -> AtlasFileIdentity {
        let (parent, name) = try AtlasFileDescriptor.parent(of: url)
        defer { close(parent) }
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw AtlasFileSafetyError.filesystemError(errno) }
        return try identity(value, url: url)
    }
    static func identity(_ value: stat, url: URL) throws -> AtlasFileIdentity {
        let mode = value.st_mode & mode_t(S_IFMT)
        let kind: AtlasFileKind
        switch mode {
        case mode_t(S_IFREG): kind = .regularFile
        case mode_t(S_IFDIR): kind = hasPackageAncestor(url) ? .package : .directory
        default: throw AtlasFileSafetyError.unsupportedObject
        }
        return AtlasFileIdentity(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: UInt64(value.st_ino), birthTimeNanoseconds: Int64(value.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(value.st_birthtimespec.tv_nsec), kind: kind)
    }
}

enum AtlasFileDescriptor {
    static func components(_ url: URL) throws -> [String] {
        var raw = url.path
        // macOS fixed system aliases; no user-controlled links are followed.
        for alias in ["/var", "/tmp", "/etc"] where raw == alias || raw.hasPrefix(alias + "/") { raw = "/private" + raw; break }
        guard raw.hasPrefix("/"), !raw.contains("\0"), !raw.split(separator: "/").contains("..") else { throw AtlasFileSafetyError.unsafePath(raw) }
        return raw.split(separator: "/").map(String.init)
    }
    static func openDirectory(_ url: URL, create: Bool = false) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw AtlasFileSafetyError.filesystemError(errno) }
        do {
            for component in try components(url) {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && create {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw AtlasFileSafetyError.filesystemError(errno) }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw AtlasFileSafetyError.filesystemError(errno) }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    static func parent(of url: URL) throws -> (Int32, String) {
        _ = try components(url)
        guard url.path != "/" else { throw AtlasFileSafetyError.unsafePath(url.path) }
        return (try openDirectory(url.deletingLastPathComponent()), url.lastPathComponent)
    }
}
