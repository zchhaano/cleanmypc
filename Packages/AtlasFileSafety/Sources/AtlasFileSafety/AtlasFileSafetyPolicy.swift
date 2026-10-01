import AtlasDomain
import Darwin
import Foundation

public struct AtlasFilePolicyContext: Sendable {
    public let homeDirectoryURL: URL
    public let organizerRoots: [URL]
    public let allowedApplicationPaths: Set<String>
    public let recoveryMappings: [String: String]
    public init(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser, organizerRoots: [URL] = [], allowedApplicationPaths: Set<String> = [], recoveryMappings: [String: String] = [:]) {
        self.homeDirectoryURL = homeDirectoryURL; self.organizerRoots = organizerRoots; self.allowedApplicationPaths = allowedApplicationPaths; self.recoveryMappings = recoveryMappings
    }
}

public final class AtlasValidatedFileOperation: @unchecked Sendable {
    let intent: AtlasFileOperationIntent
    let sourceURL: URL
    let destinationURL: URL?
    let sourceParent: Int32
    init(intent: AtlasFileOperationIntent, sourceURL: URL, destinationURL: URL?, sourceParent: Int32) {
        self.intent = intent; self.sourceURL = sourceURL; self.destinationURL = destinationURL; self.sourceParent = sourceParent
    }
    deinit { close(sourceParent) }
}

public enum AtlasFileSafetyPolicy {
    public static func expanded(_ rawPath: String, homeDirectoryURL: URL) throws -> URL {
        guard !rawPath.isEmpty, rawPath.utf8.count <= 4096, !rawPath.contains("\0"), !rawPath.split(separator: "/").contains("..") else { throw AtlasFileSafetyError.unsafePath(rawPath) }
        let path: String
        if rawPath == "~" { path = homeDirectoryURL.path }
        else if rawPath.hasPrefix("~/") { path = homeDirectoryURL.path + String(rawPath.dropFirst()) }
        else { path = rawPath }
        guard path.hasPrefix("/") else { throw AtlasFileSafetyError.unsafePath(path) }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    public static func isDescendant(_ url: URL, of root: URL) -> Bool { url.path.hasPrefix(root.path + "/") }
    public static func validateOrganizerRoot(_ url: URL, homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        guard isDescendant(url, of: homeDirectoryURL), !forbiddenOrganizerPath(url, home: homeDirectoryURL), !AtlasFileIdentityReader.hasPackageAncestor(url) else { throw AtlasFileSafetyError.unsafePath(url.path) }
        let fd = try AtlasFileDescriptor.openDirectory(url); close(fd)
        return url
    }
    static func forbiddenOrganizerPath(_ url: URL, home: URL) -> Bool {
        ["Library", "Applications", ".Trash"].contains { let root = home.appendingPathComponent($0); return url.path == root.path || isDescendant(url, of: root) }
    }
    public static func validate(_ intent: AtlasFileOperationIntent, context: AtlasFilePolicyContext) throws -> AtlasValidatedFileOperation {
        let home = context.homeDirectoryURL
        let source = try expanded(intent.sourcePath, homeDirectoryURL: home)
        let destination = try intent.destinationPath.map { try expanded($0, homeDirectoryURL: home) }
        switch intent.kind {
        case .organize:
            guard context.organizerRoots.contains(where: { isDescendant(source, of: $0) }), isDescendant(source, of: home), !forbiddenOrganizerPath(source, home: home), !AtlasFileIdentityReader.hasPackageAncestor(source), intent.expectedIdentity.kind == .regularFile else { throw AtlasFileSafetyError.unsafePath(source.path) }
            guard let destination, isDescendant(destination, of: home), !forbiddenOrganizerPath(destination, home: home), !AtlasFileIdentityReader.hasPackageAncestor(destination), !context.organizerRoots.contains(where: { destination.path == $0.path || isDescendant(destination, of: $0) }) else { throw AtlasFileSafetyError.unsafePath(intent.destinationPath ?? "") }
        case .smartClean:
            guard ["Library/Caches", "Library/Logs"].contains(where: { isDescendant(source, of: home.appendingPathComponent($0)) }), !AtlasFileIdentityReader.hasPackageAncestor(source) else { throw AtlasFileSafetyError.unsafePath(source.path) }
        case .uninstall:
            guard context.allowedApplicationPaths.contains(source.path), source.pathExtension.lowercased() == "app", !AtlasFileIdentityReader.hasPackageAncestor(source, includingSelf: false) else { throw AtlasFileSafetyError.unsafePath(source.path) }
            if let bundleID = Bundle(url: source)?.bundleIdentifier, bundleID.hasPrefix("com.apple.") { throw AtlasFileSafetyError.unsafePath(source.path) }
        case .restore:
            guard let destination, context.recoveryMappings[source.path] == destination.path, destination.path != home.path, !AtlasFileIdentityReader.hasPackageAncestor(destination, includingSelf: false) else { throw AtlasFileSafetyError.unsafePath(source.path) }
        }
        guard try AtlasFileIdentityReader.read(source) == intent.expectedIdentity else { throw AtlasFileSafetyError.identityChanged }
        if let destination, FileManager.default.fileExists(atPath: destination.path) { throw AtlasFileSafetyError.targetExists }
        let (parent, _) = try AtlasFileDescriptor.parent(of: source)
        return AtlasValidatedFileOperation(intent: intent, sourceURL: source, destinationURL: destination, sourceParent: parent)
    }
}
