import AtlasDomain
import Foundation

public enum AtlasSmartCleanExecutionSupport {
    public static func requiresHelper(for targetURL: URL, homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        // App uninstall has a separate inventory-backed policy. Smart Clean never mutates services or apps.
        false
    }

    public static func isDirectlyTrashable(_ targetURL: URL, homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = targetURL.standardizedFileURL.path
        guard !targetURL.pathComponents.contains("..") else { return false }
        return ["Library/Caches", "Library/Logs"].contains { suffix in
            let root = homeDirectoryURL.appendingPathComponent(suffix).path
            return path.hasPrefix(root + "/")
        }
    }

    public static func isSupportedExecutionTarget(_ targetURL: URL, homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        requiresHelper(for: targetURL, homeDirectoryURL: homeDirectoryURL)
            || isDirectlyTrashable(targetURL, homeDirectoryURL: homeDirectoryURL)
    }

    public static func isFindingExecutionSupported(_ finding: Finding, homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let targetPaths = finding.targetPaths, !targetPaths.isEmpty else {
            return false
        }
        return targetPaths.allSatisfy { rawPath in
            let url = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath()
            return isSupportedExecutionTarget(url, homeDirectoryURL: homeDirectoryURL)
        }
    }
}
