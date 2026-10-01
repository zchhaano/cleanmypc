import AtlasDomain
import Darwin
import Foundation

public enum AtlasFileMover {
    public static func moveWithoutReplacing(_ operation: AtlasValidatedFileOperation) throws -> AtlasFileIdentity {
        guard let destination = operation.destinationURL else { throw AtlasFileSafetyError.unsafePath("") }
        var sourceStat = stat()
        guard fstatat(operation.sourceParent, operation.sourceURL.lastPathComponent, &sourceStat, AT_SYMLINK_NOFOLLOW) == 0 else { throw AtlasFileSafetyError.filesystemError(errno) }
        guard try AtlasFileIdentityReader.identity(sourceStat, url: operation.sourceURL) == operation.intent.expectedIdentity else { throw AtlasFileSafetyError.identityChanged }
        let targetParent = try AtlasFileDescriptor.openDirectory(destination.deletingLastPathComponent(), create: true)
        defer { close(targetParent) }
        var targetStat = stat()
        guard fstat(targetParent, &targetStat) == 0 else { throw AtlasFileSafetyError.filesystemError(errno) }
        guard targetStat.st_dev == sourceStat.st_dev else { throw AtlasFileSafetyError.crossVolume }
        guard renameatx_np(operation.sourceParent, operation.sourceURL.lastPathComponent, targetParent, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw AtlasFileSafetyError.targetExists }
            throw AtlasFileSafetyError.filesystemError(errno)
        }
        var result = stat()
        guard fstatat(targetParent, destination.lastPathComponent, &result, AT_SYMLINK_NOFOLLOW) == 0 else { throw AtlasFileSafetyError.filesystemError(errno) }
        return try AtlasFileIdentityReader.identity(result, url: destination)
    }
}
