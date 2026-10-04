import AtlasDomain
import AtlasFileSafety
import Foundation

public protocol AtlasOperationJournaling: Sendable {
    func append(_ record: AtlasOperationRecord) throws
    func replay() throws -> [AtlasOperationRecord]
}
extension AtlasOperationJournal: AtlasOperationJournaling {}
public protocol AtlasNativeFileMutating: Sendable {
    func perform(_ intent: AtlasFileOperationIntent, validated: AtlasValidatedFileOperation) throws -> URL
}
public struct AtlasNativeFileMutator: AtlasNativeFileMutating {
    public init() {}
    public func perform(_ intent: AtlasFileOperationIntent, validated: AtlasValidatedFileOperation) throws -> URL {
        if intent.kind == .organize {
            _ = try AtlasFileMover.moveWithoutReplacing(validated)
            guard let path = intent.destinationPath else { throw AtlasJournalError.invalidRequest }
            return URL(fileURLWithPath: path)
        }
        // Finder Trash is path-based; journal planned is already durable. Never claim atomicity with its reply.
        guard intent.kind == .smartClean || intent.kind == .uninstall else { throw AtlasJournalError.invalidRequest }
        let source = URL(fileURLWithPath: intent.sourcePath)
        guard try AtlasFileIdentityReader.read(source) == intent.expectedIdentity else { throw AtlasFileSafetyError.identityChanged }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &trashed)
        guard let destination = trashed as URL? else { throw AtlasJournalError.corrupt }
        return destination
    }
}

/// Used only by explicitly injected test workflows while production mutation capability is closed.
public final class AtlasNativeMutationService: @unchecked Sendable {
    private let directory: AtlasSecureDirectory
    private let directoryURL: URL
    private let coordinator: AtlasMutationCoordinator
    private let journal: any AtlasOperationJournaling
    private let registry: AtlasActionPlanRegistry
    private let context: AtlasFilePolicyContext
    private let mutator: any AtlasNativeFileMutating
    public init(directoryURL: URL, registry: AtlasActionPlanRegistry, context: AtlasFilePolicyContext,
        journal: (any AtlasOperationJournaling)? = nil, mutator: any AtlasNativeFileMutating = AtlasNativeFileMutator()) throws {
        self.directoryURL = directoryURL
        directory = try AtlasSecureDirectory(directoryURL)
        coordinator = try AtlasMutationCoordinator(directoryURL: directoryURL)
        self.journal = try journal ?? AtlasOperationJournal(directoryURL: directoryURL)
        self.registry = registry; self.context = context; self.mutator = mutator
    }
    public func execute(selection: AtlasExecutionSelection, requestID: UUID, commit: (@Sendable (AtlasMutationLease, AtlasRequestStatus) async throws -> Void)? = nil) async throws -> AtlasRequestStatus {
        try await coordinator.withLease { lease in
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let selectionData = try encoder.encode(selection)
            let requestName = "request-\(requestID.uuidString).json"
            if let previous = try self.directory.readFile(requestName) {
                guard previous == selectionData else { throw AtlasJournalError.invalidRequest }
                let status = try self.status(requestID: requestID)
                try await commit?(lease, status)
                return status // Unknown never authorizes a replay.
            }
            if self.registry.registeredPlan(id: selection.planID) == nil,
               let persisted = try? AtlasActionPlanRegistry.readPersistedPlan(directoryURL: self.directoryURL, id: selection.planID) {
                _ = try self.registry.register(plan: persisted.plan, operations: persisted.operations, policyRevision: persisted.policyRevision)
            }
            let operations = try self.registry.resolve(selection)
            guard let plan = self.registry.registeredPlan(id: selection.planID) else { throw AtlasJournalError.invalidRequest }
            let planName = "plan-\(plan.plan.id.uuidString).json"
            let planData = try encoder.encode(plan)
            if let previous = try self.directory.readFile(planName) { guard previous == planData else { throw AtlasJournalError.invalidRequest } }
            else { try self.directory.writeAtomic(planName, data: planData, replacing: false) }
            _ = try self.journal.replay() // Corruption refuses before touching a file.
            try self.directory.writeAtomic(requestName, data: selectionData, replacing: false)
            for intent in operations {
                if Task.isCancelled { break }
                var record = AtlasOperationRecord(requestID: requestID, planID: selection.planID, planDigest: selection.planDigest,
                    entryID: intent.entryID, kind: intent.kind, sourcePath: intent.sourcePath, destinationPath: intent.destinationPath, sourceIdentity: intent.expectedIdentity)
                try self.journal.append(record) // A failed planned append causes zero file actions.
                var beganMutation = false
                do {
                    let validated = try AtlasFileSafetyPolicy.validate(intent, context: self.context)
                    try Task.checkCancellation()
                    beganMutation = true
                    let destination = try self.mutator.perform(intent, validated: validated)
                    let identity = try AtlasFileIdentityReader.read(destination)
                    guard identity == intent.expectedIdentity else { throw AtlasFileSafetyError.identityChanged }
                    record.destinationPath = destination.path; record.destinationIdentity = identity; record.state = .moved
                    try self.journal.append(record) // Failure leaves durable planned -> requires reconciliation.
                } catch {
                    record.state = beganMutation ? .reconciliationRequired : .failed
                    record.errorCode = String(describing: error)
                    // If persistence fails again, the earlier durable planned record remains the evidence.
                    try? self.journal.append(record)
                    break
                }
            }
            let status = try self.status(requestID: requestID)
            try await commit?(lease, status)
            return status
        }
    }
    public func status(requestID: UUID) throws -> AtlasRequestStatus {
        var latest: [UUID: AtlasOperationRecord] = [:]
        for record in try journal.replay() where record.requestID == requestID || record.restoreRequestID == requestID { latest[record.operationID] = record }
        let selection = try directory.readFile("request-\(requestID.uuidString).json").map {
            try JSONDecoder().decode(AtlasExecutionSelection.self, from: $0)
        }
        let selectedOperations = try directory.readFile("restore-request-\(requestID.uuidString).json").map { try JSONDecoder().decode([UUID].self, from: $0) }
        return AtlasRequestStatus(requestID: requestID, operations: latest.values.sorted { $0.sequence < $1.sequence }, selection: selection, selectedOperationIDs: selectedOperations)
    }
}
