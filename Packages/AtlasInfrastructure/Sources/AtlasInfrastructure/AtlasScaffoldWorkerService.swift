import AtlasApplication
import AtlasDomain
import AtlasFileSafety
import CryptoKit
import AtlasProtocol
import Foundation

public actor AtlasScaffoldWorkerService: AtlasWorkerServing {
    private let repository: AtlasWorkspaceRepository
    private let auditStore: AtlasAuditStore
    private let permissionInspector: AtlasPermissionInspector
    private let healthSnapshotProvider: (any AtlasHealthSnapshotProviding)?
    private let smartCleanScanProvider: (any AtlasSmartCleanScanProviding)?
    private let appsInventoryProvider: (any AtlasAppInventoryProviding)?
    private let helperExecutor: (any AtlasPrivilegedActionExecuting)?
    private let appUninstallEvidenceAnalyzer: AtlasAppUninstallEvidenceAnalyzer
    private let fileOrganizerScanProvider: (any AtlasFileOrganizerScanning)?
    private let fileOrganizerClassifier: (any AtlasFileOrganizerClassifying)?
    private let nowProvider: @Sendable () -> Date
    private let allowProviderFailureFallback: Bool
    private let allowStateOnlyCleanExecution: Bool
    private let planRegistry = AtlasActionPlanRegistry()
    private var organizerRoots: [URL] = []
    private var organizerPreviews: [UUID: ActionPlan] = [:]
    private let mutationsEnabledForTesting: Bool
    private var didReconcile = false
    private var persistenceFailure: String?
    private var state: AtlasWorkspaceState
    private var pendingAppUninstallSnapshots: [UUID: AtlasAppUninstallEvidenceSnapshot] = [:]

    public init(
        repository: AtlasWorkspaceRepository = AtlasWorkspaceRepository(),
        permissionInspector: AtlasPermissionInspector = AtlasPermissionInspector(),
        healthSnapshotProvider: (any AtlasHealthSnapshotProviding)? = nil,
        smartCleanScanProvider: (any AtlasSmartCleanScanProviding)? = nil,
        appsInventoryProvider: (any AtlasAppInventoryProviding)? = nil,
        helperExecutor: (any AtlasPrivilegedActionExecuting)? = nil,
        appUninstallEvidenceAnalyzer: AtlasAppUninstallEvidenceAnalyzer = AtlasAppUninstallEvidenceAnalyzer(),
        fileOrganizerScanProvider: (any AtlasFileOrganizerScanning)? = nil,
        fileOrganizerClassifier: (any AtlasFileOrganizerClassifying)? = nil,
        auditStore: AtlasAuditStore = AtlasAuditStore(),
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        allowProviderFailureFallback: Bool = ProcessInfo.processInfo.environment["ATLAS_ALLOW_PROVIDER_FAILURE_FALLBACK"] == "1",
        mutationsEnabledForTesting: Bool = false,
        allowStateOnlyCleanExecution: Bool = ProcessInfo.processInfo.environment["ATLAS_ALLOW_STATE_ONLY_CLEAN_EXECUTION"] == "1"
    ) {
        #if DEBUG
        self.mutationsEnabledForTesting = mutationsEnabledForTesting
        #else
        self.mutationsEnabledForTesting = false
        #endif
        self.repository = repository
        self.auditStore = auditStore
        self.permissionInspector = permissionInspector
        self.healthSnapshotProvider = healthSnapshotProvider
        self.smartCleanScanProvider = smartCleanScanProvider
        self.appsInventoryProvider = appsInventoryProvider
        self.helperExecutor = helperExecutor
        self.appUninstallEvidenceAnalyzer = appUninstallEvidenceAnalyzer
        self.fileOrganizerScanProvider = fileOrganizerScanProvider
        self.fileOrganizerClassifier = fileOrganizerClassifier
        self.nowProvider = nowProvider
        #if DEBUG
        self.allowProviderFailureFallback = allowProviderFailureFallback
        self.allowStateOnlyCleanExecution = allowStateOnlyCleanExecution
        #else
        self.allowProviderFailureFallback = false
        self.allowStateOnlyCleanExecution = false
        #endif
        do { self.state = try repository.loadState() }
        catch { self.state = .empty; self.persistenceFailure = error.localizedDescription }
        AtlasL10n.setCurrentLanguage(self.state.settings.language)
    }

    public func submit(_ request: AtlasRequestEnvelope) async throws -> AtlasWorkerCommandResult {
        if let persistenceFailure {
            if !didReconcile, let inspection = try? AtlasOperationJournal(directoryURL: repository.directoryURL).inspect() {
                didReconcile = true
                var latest: [UUID: AtlasOperationRecord] = [:]
                for record in inspection.records { latest[record.operationID] = record }
                projectOperations(Array(latest.values), forceReconciliation: true)
            }
            return rejectedResult(for: request, code: .executionUnavailable, reason: persistenceFailure)
        }
        if !didReconcile {
            didReconcile = true
            do {
                // Re-read under the repository lease at the first actual request; initialization may precede another process's save.
                state = try repository.loadState()
                projectOperations(try await AtlasJournalReconciler(directoryURL: repository.directoryURL).reconcile())
            }
            catch {
                if let inspection = try? AtlasOperationJournal(directoryURL: repository.directoryURL).inspect() {
                    var latest: [UUID: AtlasOperationRecord] = [:]
                    for record in inspection.records { latest[record.operationID] = record }
                    projectOperations(Array(latest.values), forceReconciliation: true)
                }
                persistenceFailure = error.localizedDescription
                return rejectedResult(for: request, code: .executionUnavailable, reason: error.localizedDescription)
            }
        }
        let result = try await process(request)
        if let persistenceFailure {
            var failed = result
            failed.response = AtlasResponseEnvelope(requestID: request.id, response: .rejected(code: .executionUnavailable, reason: persistenceFailure))
            return failed
        }
        return result
    }

    private func process(_ request: AtlasRequestEnvelope) async throws -> AtlasWorkerCommandResult {
        AtlasL10n.setCurrentLanguage(state.settings.language)
        // Release capability remains closed until recovery and VM acceptance are recorded.
        // Environment variables cannot enable file mutations.
        switch request.command {
        case .executePlan, .fileOrganizerExecutePlan, .executeAppUninstall, .restoreItems:
            if mutationsEnabledForTesting { return try await executeRegisteredMutation(request) }
            return rejectedResult(for: request, code: .executionUnavailable,
                reason: AtlasL10n.string("security.mutation.unavailable"))
        default: break
        }
        if case .restoreItems = request.command {
            // Restore needs selected-item expiry reporting before the general prune.
        } else {
            await pruneExpiredRecoveryItemsIfNeeded(context: "process request \(request.id.uuidString)")
        }
        switch request.command {
        case let .requestStatus(requestID):
            let service = try AtlasNativeMutationService(directoryURL: repository.directoryURL, registry: planRegistry, context: .init())
            return AtlasWorkerCommandResult(request: request, response: AtlasResponseEnvelope(requestID: request.id,
                response: .requestStatus(try service.status(requestID: requestID))), events: [], snapshot: state.snapshot)
        case .healthSnapshot:
            return try await healthSnapshot(using: request)
        case .inspectPermissions:
            return await inspectPermissions(using: request)
        case let .startScan(taskID):
            return await startScan(using: request, taskID: taskID)
        case let .previewPlan(_, findingIDs):
            return await previewPlan(using: request, findingIDs: findingIDs)
        case .executePlan:
            return rejectedResult(for: request, code: .executionUnavailable, reason: AtlasL10n.string("security.mutation.unavailable"))
        case .restoreItems:
            return rejectedResult(for: request, code: .executionUnavailable, reason: AtlasL10n.string("security.mutation.unavailable"))
        case .appsList:
            return await listApps(using: request)
        case let .previewAppUninstall(appID):
            return await previewAppUninstall(using: request, appID: appID)
        case .executeAppUninstall:
            return rejectedResult(for: request, code: .executionUnavailable, reason: AtlasL10n.string("security.mutation.unavailable"))
        case .settingsGet:
            return await settingsGet(using: request)
        case let .settingsSet(settings):
            return await settingsSet(using: request, settings: settings)
        case let .fileOrganizerScan(taskID, folderPaths):
            return await fileOrganizerScan(using: request, taskID: taskID, folderPaths: folderPaths)
        case let .fileOrganizerClassify(taskID, entryIDs):
            return await fileOrganizerClassify(using: request, taskID: taskID, entryIDs: entryIDs)
        case let .fileOrganizerPreviewPlan(taskID, entryIDs):
            return await fileOrganizerPreviewPlan(using: request, taskID: taskID, entryIDs: entryIDs)
        case .fileOrganizerExecutePlan:
            return rejectedResult(for: request, code: .executionUnavailable, reason: AtlasL10n.string("security.mutation.unavailable"))
        case let .fileOrganizerDryRun(planID):
            return await fileOrganizerDryRun(using: request, planID: planID)
        }
    }

    private func projectOperations(_ records: [AtlasOperationRecord], forceReconciliation: Bool = false) {
        for record in records {
            var availability: AtlasRecoveryAvailability
            switch record.state {
            case .moved:
                if let destination = record.destinationPath, let expected = record.destinationIdentity {
                    let actual = try? AtlasFileIdentityReader.read(URL(fileURLWithPath: destination))
                    availability = actual == expected ? .ready : (actual == nil ? .sourceMissing : .reconciliationRequired)
                } else { availability = .reconciliationRequired }
            case .restored: availability = .restored
            case .planned, .restorePlanned, .reconciliationRequired: availability = .reconciliationRequired
            case .failed: continue
            }
            if forceReconciliation { availability = .reconciliationRequired }
            let mappings = record.destinationPath.map { [RecoveryPathMapping(originalPath: record.sourcePath,
                trashedPath: $0, operationID: record.operationID, sourceIdentity: record.sourceIdentity, trashedIdentity: record.destinationIdentity)] }
            let item = RecoveryItem(id: record.operationID, title: URL(fileURLWithPath: record.sourcePath).lastPathComponent,
                detail: AtlasL10n.string(availability.explanationKey), originalPath: record.sourcePath, bytes: 0,
                deletedAt: record.timestamp, restoreMappings: mappings, recoveryAvailability: availability)
            if let index = state.snapshot.recoveryItems.firstIndex(where: { $0.id == record.operationID }) { state.snapshot.recoveryItems[index] = item }
            else { state.snapshot.recoveryItems.insert(item, at: 0) }
        }
    }

    private func executeRegisteredMutation(_ request: AtlasRequestEnvelope) async throws -> AtlasWorkerCommandResult {
        let status: AtlasRequestStatus
        let kind: TaskKind
        switch request.command {
        case let .restoreItems(_, itemIDs):
            guard !itemIDs.isEmpty, itemIDs.count <= AtlasExecutionLimits.maximumMutationEntries,
                  Set(itemIDs).count == itemIDs.count else { throw AtlasJournalError.invalidRequest }
            let executor = try AtlasRecoveryExecutor(directoryURL: repository.directoryURL)
            for id in itemIDs {
                guard let item = state.snapshot.recoveryItems.first(where: { $0.id == id }),
                      let operationID = item.restoreMappings?.first?.operationID else { throw AtlasJournalError.invalidRequest }
                guard !item.isExpired(asOf: nowProvider()) else {
                    return rejectedResult(for: request, code: .restoreExpired, reason: AtlasL10n.string("security.recovery.unverified"))
                }
                let result = try await executor.restore(operationID: operationID, requestID: request.id)
                if ![.restored, .alreadyRestored].contains(result.status) {
                    if let index = state.snapshot.recoveryItems.firstIndex(where: { $0.id == id }) {
                        state.snapshot.recoveryItems[index].recoveryAvailability = AtlasRecoveryAvailability(rawValue: result.status.rawValue) ?? .reconciliationRequired
                    }
                    await persistState(context: "restore failure")
                    return rejectedResult(for: request, code: .executionUnavailable, reason: AtlasL10n.string("security.recovery." + result.status.rawValue))
                }
            }
            let records = try AtlasOperationJournal(directoryURL: repository.directoryURL).replay()
            var latest: [UUID: AtlasOperationRecord] = [:]
            for r in records { latest[r.operationID] = r }
            projectOperations(Array(latest.values))
            await persistState(context: "restore journal projection")
            let run = TaskRun(kind: .restore, status: .completed, summary: AtlasL10n.string("security.restore.completed", itemIDs.count), startedAt: request.issuedAt, finishedAt: Date())
            return AtlasWorkerCommandResult(request: request, response: AtlasResponseEnvelope(requestID: request.id, response: .accepted(task: .init(taskID: run.id, kind: .restore))), events: [.init(event: .taskFinished(run))], snapshot: state.snapshot)
        case .executePlan: kind = .executePlan
        case .fileOrganizerExecutePlan: kind = .organizeFiles
        case .executeAppUninstall: kind = .uninstallApp
        default: throw AtlasJournalError.invalidRequest
        }
        guard let selection = request.executionSelection else { return rejectedResult(for: request, code: .invalidSelection, reason: "Refresh the preview; this request has no plan proof.") }
        if planRegistry.registeredPlan(id: selection.planID) == nil {
            let stored = try AtlasActionPlanRegistry.readPersistedPlan(directoryURL: repository.directoryURL, id: selection.planID)
            _ = try planRegistry.register(plan: stored.plan, operations: stored.operations, policyRevision: stored.policyRevision)
            if organizerRoots.isEmpty {
                organizerRoots = try stored.operations.filter { $0.kind == .organize }.map {
                    try AtlasFileSafetyPolicy.validateOrganizerRoot(URL(fileURLWithPath: $0.sourcePath).deletingLastPathComponent())
                }
            }
        }
        let expectedKind: AtlasFileOperationKind
        switch request.command {
        case let .executePlan(planID): guard planID == selection.planID else { throw AtlasJournalError.invalidRequest }; expectedKind = .smartClean
        case let .fileOrganizerExecutePlan(planID): guard planID == selection.planID else { throw AtlasJournalError.invalidRequest }; expectedKind = .organize
        case let .executeAppUninstall(appID, planID):
            guard planID == selection.planID, state.snapshot.apps.contains(where: { $0.id == appID }), planRegistry.registeredPlan(id: selection.planID)?.plan.items.contains(where: { $0.id == appID }) == true else { throw AtlasJournalError.invalidRequest }; expectedKind = .uninstall
        default: throw AtlasJournalError.invalidRequest
        }
        let operations = try planRegistry.resolve(selection)
        guard operations.allSatisfy({ $0.kind == expectedKind }) else { throw AtlasJournalError.invalidRequest }
        let service = try AtlasNativeMutationService(directoryURL: repository.directoryURL, registry: planRegistry,
            context: AtlasFilePolicyContext(organizerRoots: organizerRoots, allowedApplicationPaths: Set(state.snapshot.apps.map(\.bundlePath))))
        status = try await service.execute(selection: selection, requestID: request.id)
        projectOperations(status.operations)
        let moved = status.operations.filter { $0.state == .moved }.count
        let failed = operations.count - moved
        let summary = AtlasL10n.string("security.execution.result", moved, failed)
        let run = TaskRun(kind: kind, status: failed == 0 ? .completed : .failed, summary: summary, startedAt: request.issuedAt, finishedAt: Date())
        state.snapshot.taskRuns.insert(run, at: 0)
        await persistState(context: "journal projection")
        return AtlasWorkerCommandResult(request: request, response: AtlasResponseEnvelope(requestID: request.id,
            response: .accepted(task: .init(taskID: run.id, kind: kind))), events: [.init(event: .taskFinished(run))], snapshot: state.snapshot, movedCount: moved, failedCount: failed)
    }

    private func healthSnapshot(using request: AtlasRequestEnvelope) async throws -> AtlasWorkerCommandResult {
        let healthSnapshot: AtlasHealthSnapshot

        if let healthSnapshotProvider {
            healthSnapshot = try await healthSnapshotProvider.collectHealthSnapshot()
        } else {
            #if DEBUG
            healthSnapshot = AtlasScaffoldFixtures.healthSnapshot
            #else
            return rejectedResult(for: request, code: .executionUnavailable, reason: AtlasL10n.string("security.provider.unavailable"))
            #endif
        }

        state.snapshot.healthSnapshot = healthSnapshot
        await persistState(context: "health snapshot")
        let response = AtlasResponseEnvelope(requestID: request.id, response: .health(healthSnapshot))
        await auditStore.append("Collected health snapshot for request \(request.id.uuidString)")
        return AtlasWorkerCommandResult(request: request, response: response, events: [], snapshot: state.snapshot)
    }

    private func inspectPermissions(using request: AtlasRequestEnvelope) async -> AtlasWorkerCommandResult {
        let permissions = await permissionInspector.snapshot()
        state.snapshot.permissions = permissions
        await persistState(context: "permission inspection")
        let events = permissions.map { permission in
            AtlasEventEnvelope(event: .permissionUpdated(permission))
        }
        let response = AtlasResponseEnvelope(requestID: request.id, response: .permissions(permissions))
        await auditStore.append("Inspected permissions for request \(request.id.uuidString)")
        return AtlasWorkerCommandResult(request: request, response: response, events: events, snapshot: state.snapshot)
    }

    private func startScan(using request: AtlasRequestEnvelope, taskID: UUID) async -> AtlasWorkerCommandResult {
        let scanSummary: String
        if let smartCleanScanProvider {
            do {
                let scanResult = try await smartCleanScanProvider.collectSmartCleanScan()
                guard scanResult.findings.count <= AtlasExecutionLimits.maximumScanEntries,
                      scanResult.findings.allSatisfy({ $0.bytes >= 0 }) else { throw AtlasPlanRegistryError.tooManyEntries }
                var total: Int64 = 0
                for finding in scanResult.findings {
                    let sum = total.addingReportingOverflow(finding.bytes)
                    guard !sum.overflow else { throw AtlasPlanRegistryError.tooManyEntries }
                    total = sum.partialValue
                }
                state.snapshot.findings = scanResult.findings
                scanSummary = scanResult.summary
            } catch {
                guard allowProviderFailureFallback else {
                    return rejectedResult(
                        for: request,
                        code: .executionUnavailable,
                        reason: "Smart Clean scan is unavailable because the upstream clean workflow could not complete: \(error.localizedDescription)"
                    )
                }
                state.snapshot.findings = AtlasScaffoldFixtures.findings(language: state.settings.language)
                scanSummary = AtlasL10n.string(
                    state.snapshot.findings.count == 1 ? "infrastructure.scan.completed.one" : "infrastructure.scan.completed.other",
                    language: state.settings.language,
                    state.snapshot.findings.count
                )
            }
        } else {
            #if DEBUG
            state.snapshot.findings = AtlasScaffoldFixtures.findings(language: state.settings.language)
            scanSummary = AtlasL10n.string(
                state.snapshot.findings.count == 1 ? "infrastructure.scan.completed.one" : "infrastructure.scan.completed.other",
                language: state.settings.language,
                state.snapshot.findings.count
            )
            #else
            return rejectedResult(for: request, code: .executionUnavailable, reason: AtlasL10n.string("security.provider.unavailable"))
            #endif
        }
        recalculateReclaimableSpace()

        let response = AtlasResponseEnvelope(
            requestID: request.id,
            response: .accepted(task: AtlasTaskDescriptor(taskID: taskID, kind: .scan))
        )

        let progressEvents = (1 ... 4).map { step in
            AtlasEventEnvelope(event: .taskProgress(taskID: taskID, completed: step, total: 4))
        }

        let completedRun = TaskRun(
            id: taskID,
            kind: .scan,
            status: .completed,
            summary: scanSummary,
            startedAt: request.issuedAt,
            finishedAt: Date()
        )

        state.snapshot.taskRuns.removeAll { $0.id == taskID }
        state.snapshot.taskRuns.insert(completedRun, at: 0)
        let previewPlan = makePreviewPlan(findingIDs: state.snapshot.findings.map(\.id))
        state.currentPlan = previewPlan
        await persistState(context: "smart clean scan")
        let events = progressEvents + [AtlasEventEnvelope(event: .taskFinished(completedRun))]
        await auditStore.append("Completed Smart Clean scan \(taskID.uuidString)")
        return AtlasWorkerCommandResult(
            request: request,
            response: response,
            events: events,
            snapshot: state.snapshot,
            previewPlan: previewPlan
        )
    }

    private func previewPlan(using request: AtlasRequestEnvelope, findingIDs: [UUID]) async -> AtlasWorkerCommandResult {
        let plan = registeredPreview(makePreviewPlan(findingIDs: findingIDs), kind: .smartClean)
        state.currentPlan = plan
        await persistState(context: "preview plan refresh")
        let response = AtlasResponseEnvelope(requestID: request.id, response: .preview(plan))
        await auditStore.append("Prepared preview plan \(plan.id.uuidString) for request \(request.id.uuidString)")
        return AtlasWorkerCommandResult(
            request: request,
            response: response,
            events: [],
            snapshot: state.snapshot,
            previewPlan: plan
        )
    }





    private func listApps(using request: AtlasRequestEnvelope) async -> AtlasWorkerCommandResult {
        if let appsInventoryProvider {
            do {
                let apps = try await appsInventoryProvider.collectInstalledApps()
                guard apps.count <= AtlasExecutionLimits.maximumScanEntries else { throw AtlasPlanRegistryError.tooManyEntries }
                state.snapshot.apps = apps
                await persistState(context: "refresh app inventory")
            } catch { return rejectedResult(for: request, code: .executionUnavailable, reason: error.localizedDescription) }
        } else {
            #if !DEBUG
            return rejectedResult(for: request, code: .executionUnavailable, reason: AtlasL10n.string("security.provider.unavailable"))
            #endif
        }

        let apps = state.snapshot.apps.sorted { lhs, rhs in
            if lhs.bytes == rhs.bytes {
                return lhs.name < rhs.name
            }
            return lhs.bytes > rhs.bytes
        }
        let response = AtlasResponseEnvelope(requestID: request.id, response: .apps(apps))
        await auditStore.append("Listed \(apps.count) apps for request \(request.id.uuidString)")
        return AtlasWorkerCommandResult(request: request, response: response, events: [], snapshot: state.snapshot)
    }

    private func previewAppUninstall(using request: AtlasRequestEnvelope, appID: UUID) async -> AtlasWorkerCommandResult {
        guard let app = state.snapshot.apps.first(where: { $0.id == appID }) else {
            return rejectedResult(
                for: request,
                code: .invalidSelection,
                reason: "The selected app is no longer available for uninstall preview."
            )
        }

        let preview = registeredPreview(makeAppUninstallPreview(for: app), kind: .uninstall)
        let response = AtlasResponseEnvelope(requestID: request.id, response: .preview(preview))
        await auditStore.append("Prepared uninstall preview for \(app.name)")
        return AtlasWorkerCommandResult(
            request: request,
            response: response,
            events: [],
            snapshot: state.snapshot,
            previewPlan: preview
        )
    }



    private func settingsGet(using request: AtlasRequestEnvelope) async -> AtlasWorkerCommandResult {
        let response = AtlasResponseEnvelope(requestID: request.id, response: .settings(state.settings))
        return AtlasWorkerCommandResult(request: request, response: response, events: [], snapshot: state.snapshot)
    }

    private func settingsSet(using request: AtlasRequestEnvelope, settings: AtlasSettings) async -> AtlasWorkerCommandResult {
        state.settings = sanitized(settings: settings)
        await persistState(context: "update settings")
        let response = AtlasResponseEnvelope(requestID: request.id, response: .settings(state.settings))
        await auditStore.append("Updated settings for request \(request.id.uuidString)")
        return AtlasWorkerCommandResult(request: request, response: response, events: [], snapshot: state.snapshot)
    }

    // MARK: - File Organizer

    private func fileOrganizerScan(using request: AtlasRequestEnvelope, taskID: UUID, folderPaths: [String]) async -> AtlasWorkerCommandResult {
        organizerPreviews.removeAll()
        let entries: [FileOrganizerEntry]
        organizerRoots = folderPaths.compactMap { raw in
            guard let url = try? AtlasFileSafetyPolicy.expanded(raw, homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser) else { return nil }
            return try? AtlasFileSafetyPolicy.validateOrganizerRoot(url)
        }

        if let scanProvider = fileOrganizerScanProvider {
            do {
                let result = try await scanProvider.scanFolders(folderPaths, destinationBasePath: state.settings.fileOrganizerDestinationBasePath, recursive: state.settings.fileOrganizerRecursiveScan)
                entries = result.entries
            } catch {
                return rejectedResult(
                    for: request,
                    code: .executionUnavailable,
                    reason: AtlasL10n.string("fileorganizer.error.scanFailed", error.localizedDescription)
                )
            }
        } else {
            #if DEBUG
            entries = AtlasScaffoldFixtures.fileOrganizerEntries(language: state.settings.language)
            #else
            return rejectedResult(for: request, code: .executionUnavailable, reason: AtlasL10n.string("security.provider.unavailable"))
            #endif
        }

        guard entries.count <= AtlasExecutionLimits.maximumScanEntries else {
            return rejectedResult(for: request, code: .invalidSelection, reason: "Scan exceeds the candidate limit")
        }
        var total: Int64 = 0
        for entry in entries {
            let sum = total.addingReportingOverflow(entry.bytes)
            guard entry.bytes >= 0, !sum.overflow else { return rejectedResult(for: request, code: .invalidSelection, reason: "Scan byte total exceeds the limit") }
            total = sum.partialValue
        }
        state.snapshot.fileOrganizerEntries = entries
        await persistState(context: "file organizer scan")

        let response = AtlasResponseEnvelope(
            requestID: request.id,
            response: .fileOrganizerEntries(entries)
        )

        let progressEvents = (1 ... 3).map { step in
            AtlasEventEnvelope(event: .taskProgress(taskID: taskID, completed: step, total: 3))
        }

        let completedRun = TaskRun(
            id: taskID,
            kind: .scan,
            status: .completed,
            summary: AtlasL10n.string(
                entries.count == 1 ? "infrastructure.scan.completed.one" : "infrastructure.scan.completed.other",
                entries.count
            ),
            startedAt: request.issuedAt,
            finishedAt: Date()
        )
        state.snapshot.taskRuns.removeAll { $0.id == taskID }
        state.snapshot.taskRuns.insert(completedRun, at: 0)
        await persistState(context: "file organizer scan complete")

        let events = progressEvents + [AtlasEventEnvelope(event: .taskFinished(completedRun))]
        await auditStore.append("Completed File Organizer scan \(taskID.uuidString)")

        return AtlasWorkerCommandResult(
            request: request,
            response: response,
            events: events,
            snapshot: state.snapshot
        )
    }

    private func fileOrganizerClassify(using request: AtlasRequestEnvelope, taskID: UUID, entryIDs: [UUID]) async -> AtlasWorkerCommandResult {
        let currentEntries: [FileOrganizerEntry]
        if entryIDs.isEmpty {
            currentEntries = state.snapshot.fileOrganizerEntries
        } else {
            currentEntries = state.snapshot.fileOrganizerEntries.filter { entryIDs.contains($0.id) }
        }

        let classifiedEntries: [FileOrganizerEntry]
        if let classifier = fileOrganizerClassifier {
            classifiedEntries = await classifier.classify(currentEntries, rules: state.settings.fileOrganizerCustomRules ?? AtlasScaffoldFixtures.fileOrganizerRules(language: state.settings.language), destinationBasePath: state.settings.fileOrganizerDestinationBasePath)
        } else {
            classifiedEntries = currentEntries
        }

        for entry in classifiedEntries {
            if let idx = state.snapshot.fileOrganizerEntries.firstIndex(where: { $0.id == entry.id }) {
                state.snapshot.fileOrganizerEntries[idx] = entry
            }
        }
        await persistState(context: "file organizer classify")

        let response = AtlasResponseEnvelope(
            requestID: request.id,
            response: .fileOrganizerEntries(classifiedEntries)
        )
        await auditStore.append("Classified \(classifiedEntries.count) file organizer entries")

        return AtlasWorkerCommandResult(
            request: request,
            response: response,
            events: [],
            snapshot: state.snapshot
        )
    }

    private func fileOrganizerPreviewPlan(using request: AtlasRequestEnvelope, taskID: UUID, entryIDs: [UUID]) async -> AtlasWorkerCommandResult {
        let entries: [FileOrganizerEntry]
        if entryIDs.isEmpty {
            entries = []
        } else {
            entries = state.snapshot.fileOrganizerEntries.filter { entryIDs.contains($0.id) }
        }

        let plan = registeredPreview(makeFileOrganizerPlan(from: entries), kind: .organize)
        // Bound the presentation cache to the current scan's most recent previews.
        if organizerPreviews.count >= 16 { organizerPreviews.removeAll() }
        organizerPreviews[plan.id] = plan
        let response = AtlasResponseEnvelope(requestID: request.id, response: .fileOrganizerPlan(plan))
        await auditStore.append("Prepared file organizer plan \(plan.id.uuidString)")
        return AtlasWorkerCommandResult(
            request: request,
            response: response,
            events: [],
            snapshot: state.snapshot
        )
    }



    private func fileOrganizerDryRun(using request: AtlasRequestEnvelope, planID: UUID) async -> AtlasWorkerCommandResult {
        guard let plan = organizerPreviews[planID] else {
            return rejectedResult(
                for: request,
                code: .invalidSelection,
                reason: AtlasL10n.string("fileorganizer.error.stalePlan")
            )
        }
        let response = AtlasResponseEnvelope(requestID: request.id, response: .fileOrganizerPlan(plan))
        await auditStore.append("Dry run file organizer plan \(plan.id.uuidString)")
        return AtlasWorkerCommandResult(
            request: request,
            response: response,
            events: [],
            snapshot: state.snapshot
        )
    }

    private func boundedByteTotal(_ values: [Int64]) -> Int64 {
        var total: Int64 = 0
        for value in values {
            let sum = total.addingReportingOverflow(value)
            guard value >= 0, !sum.overflow else { return 0 }
            total = sum.partialValue
        }
        return total
    }

    private func registeredPreview(_ plan: ActionPlan, kind: AtlasFileOperationKind) -> ActionPlan {
        var plan = plan
        guard plan.items.count <= AtlasExecutionLimits.maximumScanEntries else { return plan }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let context = AtlasFilePolicyContext(homeDirectoryURL: home, organizerRoots: organizerRoots,
            allowedApplicationPaths: Set(state.snapshot.apps.map(\.bundlePath)))
        var operations: [AtlasFileOperationIntent] = []
        for item in plan.items {
            guard item.kind != .inspectPermission, item.kind != .reviewEvidence else { continue }
            for path in item.targetPaths ?? [] {
                do {
                    let url = try AtlasFileSafetyPolicy.expanded(path, homeDirectoryURL: home)
                    let identity = try AtlasFileIdentityReader.read(url)
                    let destination = kind == .organize ? state.snapshot.fileOrganizerEntries.first { $0.id == item.id }?.proposedDestination : nil
                    let id = contentID(Data((item.id.uuidString + "\0" + url.path).utf8))
                    let intent = AtlasFileOperationIntent(entryID: id, kind: kind, sourcePath: url.path,
                        destinationPath: try destination.map { try AtlasFileSafetyPolicy.expanded($0, homeDirectoryURL: home).path }, expectedIdentity: identity)
                    _ = try AtlasFileSafetyPolicy.validate(intent, context: context)
                    operations.append(intent)
                } catch { return plan } // Preview remains review-only when any target lacks proof.
            }
        }
        plan.id = contentID(Data(AtlasActionPlanRegistry.digest(operations, policyRevision: 1).utf8))
        return (try? planRegistry.register(plan: plan, operations: operations, policyRevision: 1).plan) ?? plan
    }

    private func contentID(_ data: Data) -> UUID {
        let b = Array(SHA256.hash(data: data).prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private func makeFileOrganizerPlan(from entries: [FileOrganizerEntry]) -> ActionPlan {
        let items = entries.map { entry in
            ActionItem(
                id: entry.id,
                title: AtlasL10n.string("application.plan.reviewFinding", entry.fileName),
                detail: "\(entry.path) → \(entry.proposedDestination)",
                kind: .organizeFile,
                recoverable: true,
                targetPaths: [entry.path]
            )
        }
        // Stable content identity; count has no narrowing integer conversion.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = (try? encoder.encode(entries.sorted { $0.id.uuidString < $1.id.uuidString })) ?? Data()
        let bytes = Array(SHA256.hash(data: payload).prefix(16))
        let planID = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return ActionPlan(
            id: planID,
            title: AtlasL10n.string("fileorganizer.section.plan.title"),
            items: items,
            estimatedBytes: boundedByteTotal(entries.map(\.bytes))
        )
    }

    private func rejectedResult(
        for request: AtlasRequestEnvelope,
        code: AtlasProtocolErrorCode,
        reason: String
    ) -> AtlasWorkerCommandResult {
        AtlasWorkerCommandResult(
            request: request,
            response: AtlasResponseEnvelope(requestID: request.id, response: .rejected(code: code, reason: reason)),
            events: [],
            snapshot: state.snapshot
        )
    }





    private func expiredRecoveryItemIDs(asOf now: Date? = nil) -> Set<UUID> {
        let cutoff = now ?? nowProvider()
        return Set(state.snapshot.recoveryItems.compactMap { item in
            item.isExpired(asOf: cutoff) ? item.id : nil
        })
    }

    private func pruneExpiredRecoveryItemsIfNeeded(context: String, now: Date? = nil) async {
        // Retention never removes operation evidence or its physical source.
    }

    private func persistState(context: String) async {
        guard persistenceFailure == nil else { return }
        do { _ = try repository.saveState(state) }
        catch {
            persistenceFailure = "State save failed; writes are disabled: " + error.localizedDescription
            await auditStore.append("\(context): \(persistenceFailure!)")
        }
    }

    private func recalculateReclaimableSpace() {
        state.snapshot.reclaimableSpaceBytes = state.snapshot.findings.map(\.bytes).reduce(0, +)
    }

    private func progressEvents(taskID: UUID, total: Int) -> [AtlasEventEnvelope] {
        (1 ... total).map { step in
            AtlasEventEnvelope(event: .taskProgress(taskID: taskID, completed: step, total: total))
        }
    }



    private func resolvedTargetPaths(for item: ActionItem, finding: Finding) -> [String] {
        Array(Set(item.targetPaths ?? finding.targetPaths ?? [])).sorted()
    }











    private func recoveryRestoreFailure(fromHelperMessage message: String) -> RecoveryRestoreFailure {
        if message.hasPrefix("Restore destination already exists:") {
            return .restoreConflict(message)
        }
        return .executionUnavailable(message)
    }







    private func smartCleanExecutionSummary(executedCount: Int, staleCount: Int, reviewOnlyCount: Int, failedCount: Int) -> String {
        var clauses: [String] = []

        if executedCount > 0 {
            clauses.append(
                AtlasL10n.string(
                    executedCount == 1 ? "infrastructure.execute.summary.clean.one" : "infrastructure.execute.summary.clean.other",
                    language: state.settings.language,
                    executedCount
                )
            )
        }

        if staleCount > 0 {
            clauses.append(
                AtlasL10n.string(
                    staleCount == 1 ? "infrastructure.execute.summary.clean.stale.one" : "infrastructure.execute.summary.clean.stale.other",
                    language: state.settings.language,
                    staleCount
                )
            )
        }

        if reviewOnlyCount > 0 {
            clauses.append(
                AtlasL10n.string(
                    reviewOnlyCount == 1 ? "infrastructure.execute.summary.clean.review.one" : "infrastructure.execute.summary.clean.review.other",
                    language: state.settings.language,
                    reviewOnlyCount
                )
            )
        }

        if failedCount > 0 {
            clauses.append(
                AtlasL10n.string(
                    failedCount == 1 ? "infrastructure.execute.summary.clean.failed.one" : "infrastructure.execute.summary.clean.failed.other",
                    language: state.settings.language,
                    failedCount
                )
            )
        }

        guard !clauses.isEmpty else {
            return AtlasL10n.string("infrastructure.execute.summary.clean.none", language: state.settings.language)
        }

        return clauses.joined(separator: " ")
    }

    private func restoreSummary(physicalRestoreCount: Int, atlasOnlyRestoreCount: Int) -> String {
        var clauses: [String] = []

        if physicalRestoreCount > 0 {
            clauses.append(
                AtlasL10n.string(
                    physicalRestoreCount == 1 ? "infrastructure.restore.summary.disk.one" : "infrastructure.restore.summary.disk.other",
                    language: state.settings.language,
                    physicalRestoreCount
                )
            )
        }

        if atlasOnlyRestoreCount > 0 {
            clauses.append(
                AtlasL10n.string(
                    atlasOnlyRestoreCount == 1 ? "infrastructure.restore.summary.state.one" : "infrastructure.restore.summary.state.other",
                    language: state.settings.language,
                    atlasOnlyRestoreCount
                )
            )
        }

        guard !clauses.isEmpty else {
            return AtlasL10n.string("infrastructure.restore.summary.none", language: state.settings.language)
        }

        return clauses.joined(separator: " ")
    }


    private func recoveryExpiryDate(from deletedAt: Date) -> Date {
        deletedAt.addingTimeInterval(TimeInterval(state.settings.recoveryRetentionDays * 86_400))
    }

    private func makeRecoveryItem(for finding: Finding, deletedAt: Date, restoreMappings: [RecoveryPathMapping]? = nil) -> RecoveryItem {
        RecoveryItem(
            title: finding.title,
            detail: finding.detail,
            originalPath: restoreMappings?.first?.originalPath ?? inferredPath(for: finding),
            bytes: finding.bytes,
            deletedAt: deletedAt,
            expiresAt: recoveryExpiryDate(from: deletedAt),
            payload: .finding(finding),
            restoreMappings: restoreMappings
        )
    }

    private func makeRecoveryItem(for app: AppFootprint, deletedAt: Date, restoreMappings: [RecoveryPathMapping]? = nil) -> RecoveryItem {
        makeRecoveryItem(
            for: app,
            uninstallEvidence: AtlasAppUninstallEvidence(bundlePath: app.bundlePath, bundleBytes: app.bytes, reviewOnlyGroups: []),
            deletedAt: deletedAt,
            restoreMappings: restoreMappings
        )
    }

    private func makeRecoveryItem(
        for app: AppFootprint,
        uninstallEvidence: AtlasAppUninstallEvidence,
        uninstallSnapshot: AtlasAppUninstallEvidenceSnapshot? = nil,
        evidenceDivergenceAtExecution: Bool = false,
        deletedAt: Date,
        restoreMappings: [RecoveryPathMapping]? = nil
    ) -> RecoveryItem {
        let reviewOnlyItemCount = uninstallEvidence.reviewOnlyItemCount > 0 ? uninstallEvidence.reviewOnlyItemCount : app.leftoverItems
        let baseDetail = AtlasL10n.string(
            reviewOnlyItemCount == 1 ? "infrastructure.recovery.app.detail.one" : "infrastructure.recovery.app.detail.other",
            language: state.settings.language,
            reviewOnlyItemCount
        )
        return RecoveryItem(
            title: app.name,
            detail: appReviewOnlyEvidenceDetail(baseDetail: baseDetail, uninstallEvidence: uninstallEvidence),
            originalPath: app.bundlePath,
            bytes: app.bytes,
            deletedAt: deletedAt,
            expiresAt: recoveryExpiryDate(from: deletedAt),
            payload: .app(AtlasAppRecoveryPayload(
                app: app,
                uninstallEvidence: uninstallEvidence,
                uninstallSnapshot: uninstallSnapshot,
                evidenceDivergenceAtExecution: evidenceDivergenceAtExecution
            )),
            restoreMappings: restoreMappings
        )
    }

    private func appUninstallSummary(for app: AppFootprint, uninstallEvidence: AtlasAppUninstallEvidence) -> String {
        let reviewOnlyGroupCount = uninstallEvidence.reviewOnlyGroupCount
        guard reviewOnlyGroupCount > 0 else {
            return AtlasL10n.string("infrastructure.apps.uninstall.summary", language: state.settings.language, app.name)
        }

        let baseSummary = AtlasL10n.string(
            reviewOnlyGroupCount == 1 ? "infrastructure.apps.uninstall.summary.review.one" : "infrastructure.apps.uninstall.summary.review.other",
            language: state.settings.language,
            app.name,
            reviewOnlyGroupCount
        )
        return appReviewOnlyEvidenceDetail(baseDetail: baseSummary, uninstallEvidence: uninstallEvidence)
    }

    private func appReviewOnlyEvidenceDetail(baseDetail: String, uninstallEvidence: AtlasAppUninstallEvidence) -> String {
        let categorySummary = appReviewOnlyEvidenceCategorySummary(for: uninstallEvidence.reviewOnlyGroups)
        guard !categorySummary.isEmpty else {
            return baseDetail
        }
        return baseDetail + " " + AtlasL10n.string(
            "infrastructure.apps.uninstall.reviewCategories",
            language: state.settings.language,
            categorySummary
        )
    }

    private func appReviewOnlyEvidenceCategorySummary(for groups: [AtlasAppFootprintEvidenceGroup]) -> String {
        groups.map { appReviewOnlyEvidenceLabel(for: $0.category) }.joined(separator: ", ")
    }

    private func inferredPath(for finding: Finding) -> String {
        if let firstTargetPath = finding.targetPaths?.first {
            return firstTargetPath
        }
        switch finding.category.lowercased() {
        case "developer":
            return "~/Library/Developer"
        case "system":
            return "~/Library/Caches"
        case "apps":
            return "~/Library/Application Support"
        case "browsers":
            return "~/Library/Caches"
        default:
            return "~/Library"
        }
    }

    private func makePreviewPlan(findingIDs: [UUID]) -> ActionPlan {
        let selectedFindings: [Finding]

        if findingIDs.isEmpty {
            selectedFindings = []
        } else {
            let selected = state.snapshot.findings.filter { findingIDs.contains($0.id) }
            selectedFindings = selected
        }

        let items = selectedFindings.map { finding in
            ActionItem(
                id: finding.id,
                title: actionTitle(for: finding),
                detail: finding.detail,
                kind: actionKind(for: finding),
                recoverable: finding.risk != .advanced,
                targetPaths: Array(Set(finding.targetPaths ?? [])).sorted()
            )
        }

        let estimatedBytes = boundedByteTotal(selectedFindings.map(\.bytes))

        return ActionPlan(
            title: AtlasL10n.string(selectedFindings.count == 1 ? "infrastructure.plan.review.one" : "infrastructure.plan.review.other", language: state.settings.language, selectedFindings.count),
            items: items,
            estimatedBytes: estimatedBytes
        )
    }

    private func makeAppUninstallPreview(for app: AppFootprint) -> ActionPlan {
        let uninstallEvidence = appUninstallEvidenceAnalyzer.analyze(
            appName: app.name,
            bundleIdentifier: app.bundleIdentifier,
            bundlePath: app.bundlePath,
            bundleBytes: app.bytes
        )

        var items: [ActionItem] = [
            ActionItem(
                id: app.id,
                title: AtlasL10n.string("infrastructure.plan.uninstall.moveBundle.title", language: state.settings.language, app.name),
                detail: AtlasL10n.string("infrastructure.plan.uninstall.moveBundle.detail", language: state.settings.language, uninstallEvidence.bundlePath),
                kind: .removeApp,
                recoverable: true,
                targetPaths: [uninstallEvidence.bundlePath]
            ),
        ]

        items.append(contentsOf: uninstallEvidence.reviewOnlyGroups.map { group in
            ActionItem(
                title: appReviewOnlyEvidenceTitle(for: group),
                detail: AtlasL10n.string(
                    "infrastructure.plan.uninstall.review.detail",
                    language: state.settings.language,
                    formattedByteCount(group.totalBytes),
                    group.items.count
                ),
                kind: .reviewEvidence,
                recoverable: false,
                evidencePaths: group.items.map(\.path)
            )
        })

        // Copy-on-modify for the evidence-enrichment step: build the plan ONCE with the real
        // items, then fill the three evidence fields in place. This eliminates the prior second
        // memberwise `finalPlan` rebuild, which re-derived fields from the first plan and would
        // silently drop any ActionPlan field added later (same drift class as the `sanitized`
        // theme bug). Guarantee: every field present on the base plan survives to the returned
        // plan; only evidencePlanID / estimatedReviewOnlyBytes / evidenceGroups are set after.
        var plan = ActionPlan(
            title: AtlasL10n.string("infrastructure.plan.uninstall.title", language: state.settings.language, app.name),
            items: items,
            estimatedBytes: uninstallEvidence.bundleBytes
        )

        // Capture evidence snapshot for preview-execute integrity (needs plan.id).
        let snapshot = appUninstallEvidenceAnalyzer.analyzeSnapshot(
            planID: plan.id,
            appName: app.name,
            bundleIdentifier: app.bundleIdentifier,
            bundlePath: app.bundlePath,
            bundleBytes: app.bytes
        )

        plan.evidencePlanID = plan.id
        plan.estimatedReviewOnlyBytes = snapshot.reviewOnlyBytes
        plan.evidenceGroups = snapshot.groups

        // Store snapshot for verification at execution time.
        // Each snapshot is keyed by unique planID; execution removes its own entry via removeValue(forKey:).
        pendingAppUninstallSnapshots[plan.id] = snapshot

        return plan
    }

    private func appReviewOnlyEvidenceTitle(for group: AtlasAppFootprintEvidenceGroup) -> String {
        AtlasL10n.string(
            "infrastructure.plan.uninstall.review.title",
            language: state.settings.language,
            appReviewOnlyEvidenceLabel(for: group.category),
            group.items.count
        )
    }

    private func appReviewOnlyEvidenceLabel(for category: AtlasAppFootprintEvidenceCategory) -> String {
        switch category {
        case .supportFiles:
            return AtlasL10n.string("infrastructure.plan.uninstall.review.supportFiles", language: state.settings.language)
        case .caches:
            return AtlasL10n.string("infrastructure.plan.uninstall.review.caches", language: state.settings.language)
        case .preferences:
            return AtlasL10n.string("infrastructure.plan.uninstall.review.preferences", language: state.settings.language)
        case .logs:
            return AtlasL10n.string("infrastructure.plan.uninstall.review.logs", language: state.settings.language)
        case .launchItems:
            return AtlasL10n.string("infrastructure.plan.uninstall.review.launchItems", language: state.settings.language)
        }
    }

    private func formattedByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func actionTitle(for finding: Finding) -> String {
        switch actionKind(for: finding) {
        case .removeApp:
            return AtlasL10n.string("infrastructure.action.reviewUninstall", language: state.settings.language, finding.title)
        case .inspectPermission:
            return AtlasL10n.string("infrastructure.action.inspectPrivileged", language: state.settings.language, finding.title)
        case .reviewEvidence:
            return AtlasL10n.string("infrastructure.action.inspectPrivileged", language: state.settings.language, finding.title)
        case .archiveFile:
            return AtlasL10n.string("infrastructure.action.archiveRecovery", language: state.settings.language, finding.title)
        case .removeCache:
            return AtlasL10n.string("infrastructure.action.moveToTrash", language: state.settings.language, finding.title)
        case .organizeFile:
            return AtlasL10n.string("infrastructure.action.archiveRecovery", language: state.settings.language, finding.title)
        }
    }

    private func actionKind(for finding: Finding) -> ActionItem.Kind {
        if finding.risk == .advanced {
            return .inspectPermission
        }

        if !AtlasSmartCleanExecutionSupport.isFindingExecutionSupported(finding) {
            return .inspectPermission
        }

        if finding.category == "Apps" {
            return .removeApp
        }

        if finding.risk == .review {
            return .archiveFile
        }

        return .removeCache
    }

    private func sanitized(settings: AtlasSettings) -> AtlasSettings {
        // Copy-on-modify: start from the WHOLE struct and touch ONLY the fields that
        // need normalization. Do NOT rebuild AtlasSettings memberwise — a memberwise
        // init call silently drops any field omitted from the argument list (defaulted
        // init params still compile), which is exactly how `theme` was lost and the
        // user's appearance choice snapped back to .system (regression theme-snapback).
        // This form makes dropping a field structurally impossible: any future field
        // added to AtlasSettings survives sanitization with zero edits here.
        var result = settings
        result.recoveryRetentionDays = min(max(result.recoveryRetentionDays, 1), 30)
        result.excludedPaths = Array(
            Set(result.excludedPaths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        ).sorted()
        return result
    }
}

private struct SmartCleanExecutionResult {
    var restoreMappingsByFindingID: [UUID: [RecoveryPathMapping]] = [:]
    var staleFindingIDs: Set<UUID> = []
    var failedFindingIDs: Set<UUID> = []
    var failureReason: String?

    var hasRecordedOutcome: Bool {
        !restoreMappingsByFindingID.isEmpty || !staleFindingIDs.isEmpty
    }
}

private struct SmartCleanExecutableSelection {
    let finding: Finding
    let targetPaths: [String]
}

private struct SmartCleanExecutionFailure: LocalizedError {
    let result: SmartCleanExecutionResult

    var errorDescription: String? {
        result.failureReason
    }
}

private enum RecoveryRestoreFailure: LocalizedError {
    case helperUnavailable(String)
    case restoreConflict(String)
    case executionUnavailable(String)

    var code: AtlasProtocolErrorCode {
        switch self {
        case .helperUnavailable:
            return .helperUnavailable
        case .restoreConflict:
            return .restoreConflict
        case .executionUnavailable:
            return .executionUnavailable
        }
    }

    var errorDescription: String? {
        switch self {
        case let .helperUnavailable(reason),
             let .restoreConflict(reason),
             let .executionUnavailable(reason):
            return reason
        }
    }
}

extension RecoveryItem {
    func isExpired(asOf date: Date) -> Bool {
        guard let expiresAt else {
            return false
        }
        return expiresAt <= date
    }
}
