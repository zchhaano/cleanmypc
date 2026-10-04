import AtlasDomain
import Foundation

public struct AtlasJournalReconciler: Sendable {
    private let journal: any AtlasOperationJournaling
    private let coordinator: AtlasMutationCoordinator
    public init(directoryURL: URL, journal: (any AtlasOperationJournaling)? = nil) throws {
        self.journal = try journal ?? AtlasOperationJournal(directoryURL: directoryURL)
        coordinator = try AtlasMutationCoordinator(directoryURL: directoryURL)
    }
    public func reconcile() async throws -> [AtlasOperationRecord] {
        try await coordinator.withLease { _ in
            var latest: [UUID: AtlasOperationRecord] = [:]
            for record in try journal.replay() { latest[record.operationID] = record }
            for var record in latest.values where record.state == .planned || record.state == .restorePlanned {
                // Filesystem names cannot prove which side of a move/log gap completed.
                record.state = .reconciliationRequired; record.errorCode = "interruptedMutation"
                try journal.append(record)
                latest[record.operationID] = record
            }
            return latest.values.sorted { $0.sequence < $1.sequence }
        }
    }
}
