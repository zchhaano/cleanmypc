import Foundation

public enum AtlasFileKind: String, Codable, Hashable, Sendable { case regularFile, directory, package }
public struct AtlasFileIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let birthTimeNanoseconds: Int64
    public let kind: AtlasFileKind
    public init(device: UInt64, inode: UInt64, birthTimeNanoseconds: Int64, kind: AtlasFileKind) {
        self.device = device; self.inode = inode; self.birthTimeNanoseconds = birthTimeNanoseconds; self.kind = kind
    }
}
public enum AtlasFileOperationKind: String, Codable, Hashable, Sendable { case smartClean, organize, uninstall, restore }
public struct AtlasFileOperationIntent: Codable, Hashable, Sendable {
    public let entryID: UUID
    public let kind: AtlasFileOperationKind
    public let sourcePath: String
    public let destinationPath: String?
    public let expectedIdentity: AtlasFileIdentity
    public init(entryID: UUID, kind: AtlasFileOperationKind, sourcePath: String, destinationPath: String? = nil, expectedIdentity: AtlasFileIdentity) {
        self.entryID = entryID; self.kind = kind; self.sourcePath = sourcePath; self.destinationPath = destinationPath; self.expectedIdentity = expectedIdentity
    }
}
