import AtlasDomain
import AtlasFileSafety
import AtlasInfrastructure
import Darwin
import Foundation

// A test-only process exits at actual crash windows. It only operates fixed paths inside a marked temporary root.
let arguments = CommandLine.arguments
func require(_ condition: Bool) { if !condition { exit(2) } }
require(arguments.count == 3 && getuid() != 0)
let root = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
require(root.resolvingSymlinksInPath().path.hasPrefix(temporary.path + "/") && !arguments[1].split(separator: "/").contains(".."))
let marker = root.appendingPathComponent(".atlas-crash-test")
var markerInfo = stat()
require(lstat(marker.path, &markerInfo) == 0 && markerInfo.st_uid == getuid() && markerInfo.st_mode & S_IFMT == S_IFREG && markerInfo.st_nlink == 1 && markerInfo.st_mode & 0o777 == 0o600)
do {
    let input = root.appendingPathComponent("input"), output = root.appendingPathComponent("output")
    let source = input.appendingPathComponent("a"), destination = output.appendingPathComponent("a")
    _ = try AtlasFileSafetyPolicy.validateOrganizerRoot(input, homeDirectoryURL: root)
    let identity = try AtlasFileIdentityReader.read(source)
    let journal = try AtlasOperationJournal(directoryURL: root.appendingPathComponent("state"))
    var record = AtlasOperationRecord(requestID: UUID(), planID: UUID(), planDigest: "test-crash-plan", entryID: UUID(), kind: .organize,
        sourcePath: source.path, destinationPath: destination.path, sourceIdentity: identity)
    try journal.append(record)
    if arguments[2] == "afterPlanned" { _exit(73) }
    let intent = AtlasFileOperationIntent(entryID: record.entryID, kind: .organize, sourcePath: source.path, destinationPath: destination.path, expectedIdentity: identity)
    _ = try AtlasFileMover.moveWithoutReplacing(AtlasFileSafetyPolicy.validate(intent, context: .init(homeDirectoryURL: root, organizerRoots: [input])))
    if arguments[2] == "afterMove" { _exit(73) }
    record.state = .moved; record.destinationIdentity = try AtlasFileIdentityReader.read(destination)
    try journal.append(record)
    if arguments[2] == "afterMoved" { _exit(73) }
    require(arguments[2] == "afterRestore")
    record.state = .restorePlanned; try journal.append(record)
    let restore = AtlasFileOperationIntent(entryID: record.entryID, kind: .restore, sourcePath: destination.path, destinationPath: source.path, expectedIdentity: identity)
    _ = try AtlasFileMover.moveWithoutReplacing(AtlasFileSafetyPolicy.validate(restore, context: .init(homeDirectoryURL: root, recoveryMappings: [destination.path: source.path])))
    _exit(73)
} catch { fputs("crash harness setup failed: \(error)\n", stderr); exit(2) }
