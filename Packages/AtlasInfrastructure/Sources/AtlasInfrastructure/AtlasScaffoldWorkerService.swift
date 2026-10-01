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
        allowStateOnlyCleanExecution: Bool = ProcessInfo.processInfo.environment["ATLAS_ALLOW_STATE_ONLY_CLEAN_EXECUTION"] == "1"
    ) {
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
        self.allowProviderFailureFallback = allowProviderFailureFallback
        self.allowStateOnlyCleanExecution = allowStateOnlyCleanExecution
        self.state = repository.loadState()
        AtlasL10n.setCurrentLanguage(self.state.settings.language)
    }

    public func submit(_ request: AtlasRequestEnvelope) async throws -> AtlasWorkerCommandResult {
        AtlasL10n.setCurrentLanguage(state.settings.language)
        // Release capability remains closed until recovery and VM acceptance are recorded.
        // Environment variables cannot enable file mutations.
        switch request.command {
        case .executePlan, .fileOrganizerExecutePlan, .executeAppUninstall, .restoreItems:
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
        case .healthSnapshot:
            return try await healthSnapshot(using: request)
        case .inspectPermissions:
            return await inspectPermissions(using: request)
        case let .startScan(taskID):
            return await startScan(using: request, taskID: taskID)
        case let .previewPlan(_, findingIDs):
            return await previewPlan(using: request, findingIDs: findingIDs)
        case let .executePlan(planID):
            return await executePlan(using: request, planID: planID)
        case let .restoreItems(taskID, itemIDs):
            return await restoreItems(using: request, taskID: taskID, itemIDs: itemIDs)
        case .appsList:
            return await listApps(using: request)
        case let .previewAppUninstall(appID):
            return await previewAppUninstall(using: request, appID: appID)
        case let .executeAppUninstall(appID, planID):
            return await executeAppUninstall(using: request, appID: appID, planID: planID)
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
        case let .fileOrganizerExecutePlan(planID):
            return await fileOrganizerExecutePlan(using: request, planID: planID)
        case let .fileOrganizerDryRun(planID):
            return await fileOrganizerDryRun(using: request, planID: planID)
        }
    }

    private func healthSnapshot(using request: AtlasRequestEnvelope) async throws -> AtlasWorkerCommandResult {
        let healthSnapshot: AtlasHealthSnapshot

        if let healthSnapshotProvider {
            healthSnapshot = try await healthSnapshotProvider.collectHealthSnapshot()
        } else {
            healthSnapshot = AtlasScaffoldFixtures.healthSnapshot
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
            state.snapshot.findings = AtlasScaffoldFixtures.findings(language: state.settings.language)
            scanSummary = AtlasL10n.string(
                state.snapshot.findings.count == 1 ? "infrastructure.scan.completed.one" : "infrastructure.scan.completed.other",
                language: state.settings.language,
                state.snapshot.findings.count
            )
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

    private func executePlan(using request: AtlasRequestEnvelope, planID: UUID) async -> AtlasWorkerCommandResult {
        guard state.currentPlan.id == planID else {
            return rejectedResult(
                for: request,
                code: .invalidSelection,
                reason: "The requested Smart Clean plan is no longer current. Refresh the preview and try again."
            )
        }

        let selectedItems = state.currentPlan.items
        let findingsByID = Dictionary(uniqueKeysWithValues: state.snapshot.findings.map { ($0.id, $0) })
        let missingFindingIDs = selectedItems.compactMap { item in
            findingsByID[item.id] == nil ? item.id : nil
        }

        if !missingFindingIDs.isEmpty {
            return rejectedResult(
                for: request,
                code: .invalidSelection,
                reason: "The requested Smart Clean items are no longer available. Refresh the preview and try again."
            )
        }

        let selectedFindings = selectedItems.compactMap { item in
            findingsByID[item.id]
        }

        guard !selectedFindings.isEmpty else {
            return rejectedResult(
                for: request,
                code: .invalidSelection,
                reason: "The requested Smart Clean items are no longer available. Refresh the preview and try again."
            )
        }

        let executableSelections = selectedItems.compactMap { item -> SmartCleanExecutableSelection? in
            guard item.kind != .inspectPermission, item.kind != .reviewEvidence, let finding = findingsByID[item.id] else {
                return nil
            }
            return SmartCleanExecutableSelection(
                finding: finding,
                targetPaths: resolvedTargetPaths(for: item, finding: finding)
            )
        }
        let missingExecutableTargets = executableSelections.filter { $0.targetPaths.isEmpty }

        if !missingExecutableTargets.isEmpty && !allowStateOnlyCleanExecution {
            return rejectedResult(
                for: request,
                code: .executionUnavailable,
                reason: "Smart Clean execution is unavailable because one or more plan items do not include executable cleanup targets in this build."
            )
        }
        let skippedCount = selectedItems.count - executableSelections.count
        let taskID = UUID()

        let response = AtlasResponseEnvelope(
            requestID: request.id,
            response: .accepted(task: AtlasTaskDescriptor(taskID: taskID, kind: .executePlan))
        )

        var executionResult = SmartCleanExecutionResult()
        if !executableSelections.isEmpty {
            do {
                executionResult = try await executeSmartCleanSelections(executableSelections)
            } catch let failure as SmartCleanExecutionFailure {
                executionResult = failure.result
                if !allowStateOnlyCleanExecution && !executionResult.hasRecordedOutcome {
                    return rejectedResult(
                        for: request,
                        code: .executionUnavailable,
                        reason: failure.localizedDescription
                    )
                }
            } catch {
                if !allowStateOnlyCleanExecution {
                    return rejectedResult(
                        for: request,
                        code: .executionUnavailable,
                        reason: error.localizedDescription
                    )
                }
            }
        }

        let executedFindings = executableSelections.map(\.finding)
        let physicallyExecutedFindings = executedFindings.filter {
            !(executionResult.restoreMappingsByFindingID[$0.id] ?? []).isEmpty
        }
        let staleFindings = executedFindings.filter { executionResult.staleFindingIDs.contains($0.id) }
        let failedFindings = executedFindings.filter { executionResult.failedFindingIDs.contains($0.id) }
        let recoveryItems = physicallyExecutedFindings.map {
            makeRecoveryItem(for: $0, deletedAt: Date(), restoreMappings: executionResult.restoreMappingsByFindingID[$0.id])
        }
        let removedFindingIDs = Set(physicallyExecutedFindings.map(\.id)).union(staleFindings.map(\.id))
        state.snapshot.findings.removeAll { removedFindingIDs.contains($0.id) }
        state.snapshot.recoveryItems.insert(contentsOf: recoveryItems, at: 0)
        recalculateReclaimableSpace()
        state.currentPlan = makePreviewPlan(findingIDs: state.snapshot.findings.map(\.id))

        let summary = smartCleanExecutionSummary(
            executedCount: physicallyExecutedFindings.count,
            staleCount: staleFindings.count,
            reviewOnlyCount: skippedCount,
            failedCount: failedFindings.count
        )

        let completedRun = TaskRun(
            id: taskID,
            kind: .executePlan,
            status: failedFindings.isEmpty ? .completed : .failed,
            summary: summary,
            startedAt: request.issuedAt,
            finishedAt: Date()
        )
        state.snapshot.taskRuns.removeAll { $0.id == taskID }
        state.snapshot.taskRuns.insert(completedRun, at: 0)
        await persistState(context: "execute Smart Clean plan")
        let events = progressEvents(taskID: taskID, total: 3) + [AtlasEventEnvelope(event: .taskFinished(completedRun))]
        if let failureReason = executionResult.failureReason {
            await auditStore.append("Smart Clean execution recorded partial failure: \(failureReason)")
        }
        await auditStore.append("Executed Smart Clean plan \(planID.uuidString)")
        return AtlasWorkerCommandResult(request: request, response: response, events: events, snapshot: state.snapshot)
    }

    private func restoreItems(using request: AtlasRequestEnvelope, taskID: UUID, itemIDs: [UUID]) async -> AtlasWorkerCommandResult {
        let requestedItemIDs = Set(itemIDs)
        let expiredSelectionIDs = requestedItemIDs.intersection(expiredRecoveryItemIDs())

        if !expiredSelectionIDs.isEmpty {
            await pruneExpiredRecoveryItemsIfNeeded(context: "prune expired recovery items before rejected restore")
            return rejectedResult(
                for: request,
                code: .restoreExpired,
                reason: "One or more selected recovery items have expired and can no longer be restored."
            )
        }

        await pruneExpiredRecoveryItemsIfNeeded(context: "refresh recovery retention before restore")
        let itemsToRestore = state.snapshot.recoveryItems.filter { requestedItemIDs.contains($0.id) }

        guard !itemsToRestore.isEmpty else {
            return rejectedResult(
                for: request,
                code: .invalidSelection,
                reason: "The selected recovery item is no longer available."
            )
        }

        do {
            try validateRestoreItems(itemsToRestore)
        } catch let failure as RecoveryRestoreFailure {
            return rejectedResult(
                for: request,
                code: failure.code,
                reason: failure.localizedDescription
            )
        } catch {
            return rejectedResult(
                for: request,
                code: .executionUnavailable,
                reason: error.localizedDescription
            )
        }

        var physicalRestoreCount = 0
        var atlasOnlyRestoreCount = 0

        for item in itemsToRestore {
            if let restoreMappings = item.restoreMappings, !restoreMappings.isEmpty {
                do {
                    try await restoreRecoveryMappings(restoreMappings)
                    physicalRestoreCount += 1
                } catch let failure as RecoveryRestoreFailure {
                    return rejectedResult(
                        for: request,
                        code: failure.code,
                        reason: failure.localizedDescription
                    )
                } catch {
                    return rejectedResult(
                        for: request,
                        code: .executionUnavailable,
                        reason: error.localizedDescription
                    )
                }
            } else {
                atlasOnlyRestoreCount += 1
            }
        }

        for item in itemsToRestore {
            switch item.payload {
            case let .finding(finding):
                if !state.snapshot.findings.contains(where: { $0.id == finding.id }) {
                    state.snapshot.findings.insert(finding, at: 0)
                }
            case let .app(payload):
                var restoredApp = payload.app
                if payload.uninstallEvidence.reviewOnlyItemCount > 0 {
                    restoredApp.leftoverItems = payload.uninstallEvidence.reviewOnlyItemCount
                }
                if !state.snapshot.apps.contains(where: { $0.id == restoredApp.id }) {
                    state.snapshot.apps.insert(restoredApp, at: 0)
                }
            case .fileOrganizer:
                // File organizer restore is handled by generic restoreMappings below
                break
            case nil:
                break
            }
        }

        state.snapshot.recoveryItems.removeAll { requestedItemIDs.contains($0.id) }
        recalculateReclaimableSpace()
        state.currentPlan = makePreviewPlan(findingIDs: state.snapshot.findings.map(\.id))

        let completedRun = TaskRun(
            id: taskID,
            kind: .restore,
            status: .completed,
            summary: restoreSummary(physicalRestoreCount: physicalRestoreCount, atlasOnlyRestoreCount: atlasOnlyRestoreCount),
            startedAt: request.issuedAt,
            finishedAt: Date()
        )
        state.snapshot.taskRuns.removeAll { $0.id == taskID }
        state.snapshot.taskRuns.insert(completedRun, at: 0)
        await persistState(context: "restore recovery items")
        let response = AtlasResponseEnvelope(
            requestID: request.id,
            response: .accepted(task: AtlasTaskDescriptor(taskID: taskID, kind: .restore))
        )
        let events = progressEvents(taskID: taskID, total: 2) + [AtlasEventEnvelope(event: .taskFinished(completedRun))]
        await auditStore.append("Restored \(itemsToRestore.count) item(s) for task \(taskID.uuidString)")
        return AtlasWorkerCommandResult(request: request, response: response, events: events, snapshot: state.snapshot)
    }

    private func listApps(using request: AtlasRequestEnvelope) async -> AtlasWorkerCommandResult {
        if let appsInventoryProvider, let apps = try? await appsInventoryProvider.collectInstalledApps(), !apps.isEmpty {
            state.snapshot.apps = apps
            await persistState(context: "refresh app inventory")
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

    private func executeAppUninstall(using request: AtlasRequestEnvelope, appID: UUID, planID: UUID?) async -> AtlasWorkerCommandResult {
        guard let app = state.snapshot.apps.first(where: { $0.id == appID }) else {
            return rejectedResult(
                for: request,
                code: .invalidSelection,
                reason: "The selected app is no longer available to uninstall."
            )
        }

        let uninstallEvidence: AtlasAppUninstallEvidence
        var matchedSnapshot: AtlasAppUninstallEvidenceSnapshot?
        var evidenceDivergenceAtExecution = false

        if let planID, let snapshot = pendingAppUninstallSnapshots[planID] {
            // Snapshot found: verify fingerprint integrity
            let currentSnapshot = appUninstallEvidenceAnalyzer.analyzeSnapshot(
                planID: planID,
                appName: app.name,
                bundleIdentifier: app.bundleIdentifier,
                bundlePath: app.bundlePath,
                bundleBytes: app.bytes
            )

            if currentSnapshot.fingerprintHash != snapshot.fingerprintHash {
                evidenceDivergenceAtExecution = true
                await auditStore.append("Evidence divergence detected for \(app.name): fingerprint mismatch")
            }

            // Convert snapshot groups back to legacy evidence format for recovery item creation
            let legacyGroups = snapshot.reviewOnlyGroups.compactMap { group -> AtlasAppFootprintEvidenceGroup? in
                // Map AtlasAppEvidenceCategory to AtlasAppFootprintEvidenceCategory where possible
                guard let legacyCategory = AtlasAppFootprintEvidenceCategory(rawValue: group.category.rawValue) else {
                    return nil
                }
                return AtlasAppFootprintEvidenceGroup(
                    category: legacyCategory,
                    items: group.items.map { AtlasAppFootprintEvidenceItem(path: $0.path, bytes: $0.bytes) }
                )
            }
            uninstallEvidence = AtlasAppUninstallEvidence(
                bundlePath: app.bundlePath,
                bundleBytes: app.bytes,
                reviewOnlyGroups: legacyGroups
            )
            matchedSnapshot = snapshot

            // Remove snapshot from pending map after use
            pendingAppUninstallSnapshots.removeValue(forKey: planID)
        } else {
            // No snapshot found (nil planID or worker restarted): fall back to re-running analyzer
            uninstallEvidence = appUninstallEvidenceAnalyzer.analyze(
                appName: app.name,
                bundleIdentifier: app.bundleIdentifier,
                bundlePath: app.bundlePath,
                bundleBytes: app.bytes
            )
            if let planID {
                await auditStore.append("No pending snapshot found for plan \(planID.uuidString), falling back to fresh analysis for \(app.name)")
            }
        }

        var appRestoreMappings: [RecoveryPathMapping]?
        if !app.bundlePath.isEmpty, FileManager.default.fileExists(atPath: app.bundlePath) {
            guard let helperExecutor else {
                return rejectedResult(
                    for: request,
                    code: .helperUnavailable,
                    reason: "Bundled helper unavailable for app uninstall. Build or package the helper and try again."
                )
            }

            do {
                let result = try await helperExecutor.perform(
                    AtlasHelperAction(kind: .trashItems, targetPath: app.bundlePath)
                )
                guard result.success else {
                    return rejectedResult(for: request, code: .helperUnavailable, reason: result.message)
                }
                if let trashedPath = result.resolvedPath {
                    appRestoreMappings = [RecoveryPathMapping(originalPath: app.bundlePath, trashedPath: trashedPath)]
                }
            } catch {
                return rejectedResult(for: request, code: .helperUnavailable, reason: error.localizedDescription)
            }
        }

        let taskID = UUID()
        state.snapshot.apps.removeAll { $0.id == appID }
        state.snapshot.recoveryItems.insert(
            makeRecoveryItem(for: app, uninstallEvidence: uninstallEvidence, uninstallSnapshot: matchedSnapshot, evidenceDivergenceAtExecution: evidenceDivergenceAtExecution, deletedAt: Date(), restoreMappings: appRestoreMappings),
            at: 0
        )

        let completedRun = TaskRun(
            id: taskID,
            kind: .uninstallApp,
            status: .completed,
            summary: appUninstallSummary(for: app, uninstallEvidence: uninstallEvidence),
            startedAt: request.issuedAt,
            finishedAt: Date()
        )
        state.snapshot.taskRuns.removeAll { $0.id == taskID }
        state.snapshot.taskRuns.insert(completedRun, at: 0)
        await persistState(context: "execute app uninstall")

        let response = AtlasResponseEnvelope(
            requestID: request.id,
            response: .accepted(task: AtlasTaskDescriptor(taskID: taskID, kind: .uninstallApp))
        )
        let events = progressEvents(taskID: taskID, total: 3) + [AtlasEventEnvelope(event: .taskFinished(completedRun))]
        await auditStore.append("Executed uninstall preview for \(app.name)")
        return AtlasWorkerCommandResult(request: request, response: response, events: events, snapshot: state.snapshot)
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
            entries = AtlasScaffoldFixtures.fileOrganizerEntries(language: state.settings.language)
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
        let response = AtlasResponseEnvelope(requestID: request.id, response: .fileOrganizerPlan(plan))
        await auditStore.append("Prepared file organizer plan \(plan.id.uuidString)")
        return AtlasWorkerCommandResult(
            request: request,
            response: response,
            events: [],
            snapshot: state.snapshot
        )
    }

    private func fileOrganizerExecutePlan(using request: AtlasRequestEnvelope, planID: UUID) async -> AtlasWorkerCommandResult {
        let entries = state.snapshot.fileOrganizerEntries
        guard !entries.isEmpty else {
            return rejectedResult(
                for: request,
                code: .invalidSelection,
                reason: AtlasL10n.string("fileorganizer.error.noEntries")
            )
        }

        let plan = makeFileOrganizerPlan(from: entries)
        guard plan.id == planID else {
            return rejectedResult(
                for: request,
                code: .invalidSelection,
                reason: AtlasL10n.string("fileorganizer.error.stalePlan")
            )
        }

        let taskID = UUID()
        var moveMappings: [FileOrganizerMoveMapping] = []
        var absoluteDestPaths: [String] = []  // parallel array: absolute paths for restore mappings
        var totalBytesMoved: Int64 = 0
        var failedMoves: [(String, String)] = []

        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser.path

        // Track used destination paths to detect cross-source filename collisions
        var usedDestPaths: [String: Int] = [:]

        for entry in entries {
            let rawSourcePath = (entry.path as NSString).expandingTildeInPath
            let rawDestPath = (entry.proposedDestination as NSString).expandingTildeInPath

            let sourceURL: URL
            let destURL: URL
            do {
                sourceURL = try AtlasPathValidator.validate(rawSourcePath)
                destURL = try AtlasPathValidator.validate(rawDestPath)
            } catch {
                await auditStore.append("Skipped invalid path for \(entry.fileName): \(error.localizedDescription)")
                failedMoves.append((entry.fileName, "Invalid path: \(error.localizedDescription)"))
                continue
            }
            let sourcePath = sourceURL.path
            let proposedDestPath = destURL.path

            guard fm.fileExists(atPath: sourcePath) else {
                await auditStore.append("Source no longer exists: \(entry.fileName)")
                failedMoves.append((entry.fileName, "Source file no longer exists"))
                continue
            }

            // Resolve destination: handle in-memory duplicates + on-disk conflicts
            let claimIndex = usedDestPaths[proposedDestPath, default: 0]
            usedDestPaths[proposedDestPath] = claimIndex + 1

            var destPath = proposedDestPath
            if claimIndex > 0 || fm.fileExists(atPath: destPath) {
                let ext = (proposedDestPath as NSString).pathExtension
                let baseName = (proposedDestPath as NSString).deletingPathExtension
                var attempt = claimIndex > 0 ? claimIndex : 1
                var candidate = ext.isEmpty
                    ? "\(baseName) (\(attempt))"
                    : "\(baseName) (\(attempt)).\(ext)"
                while fm.fileExists(atPath: candidate) {
                    attempt += 1
                    candidate = ext.isEmpty
                        ? "\(baseName) (\(attempt))"
                        : "\(baseName) (\(attempt)).\(ext)"
                }
                destPath = candidate
            }

            // Security boundary (audit #22): FileOrganizer destinations are
            // confined to the user's home. A traversing subfolder or a base
            // path configured outside home must never move a file into
            // /Applications, /Library, or anywhere else. Reject (don't write).
            guard destPath == homeDir || destPath.hasPrefix(homeDir + "/") else {
                await auditStore.append("Rejected FileOrganizer destination outside home for \(entry.fileName): \(destPath)")
                failedMoves.append((entry.fileName, "Destination is outside the home directory"))
                continue
            }
            do {
                let intent = AtlasFileOperationIntent(entryID: entry.id, kind: .organize, sourcePath: sourcePath, destinationPath: destPath, expectedIdentity: try AtlasFileIdentityReader.read(sourceURL))
                let operation = try AtlasFileSafetyPolicy.validate(intent, context: AtlasFilePolicyContext(organizerRoots: organizerRoots))
                _ = try AtlasFileMover.moveWithoutReplacing(operation)
                // Map display path back from resolved destPath. Separator
                // boundary (audit #2): match scanner's homeDir + "/" convention.
                let resolvedDisplay: String
                if destPath == homeDir || destPath.hasPrefix(homeDir + "/") {
                    resolvedDisplay = "~" + String(destPath.dropFirst(homeDir.count))
                } else {
                    resolvedDisplay = destPath
                }
                moveMappings.append(FileOrganizerMoveMapping(originalPath: entry.path, destinationPath: resolvedDisplay))
                absoluteDestPaths.append(destPath)
                totalBytesMoved += entry.bytes
            } catch {
                await auditStore.append("Failed to move \(entry.fileName): \(error.localizedDescription)")
                failedMoves.append((entry.fileName, error.localizedDescription))
            }
        }

        if !failedMoves.isEmpty {
            await auditStore.append("File organizer partial failure: \(failedMoves.count)/\(entries.count) files failed")
        }

        if !moveMappings.isEmpty {
            // Source folder (audit #10): the directory being organized, not a
            // single file path.
            let sourceFolder = (entries.first?.path).map { ($0 as NSString).deletingLastPathComponent } ?? "~/Desktop"
            let newRestoreMappings = zip(moveMappings, absoluteDestPaths).map { mapping, absoluteDest in
                RecoveryPathMapping(originalPath: (mapping.originalPath as NSString).expandingTildeInPath, trashedPath: absoluteDest)
            }
            let recoveryItem = RecoveryItem(
                title: AtlasL10n.string("fileorganizer.recovery.title"),
                detail: AtlasL10n.string("fileorganizer.recovery.detail"),
                originalPath: sourceFolder,
                bytes: totalBytesMoved,
                deletedAt: Date(),
                expiresAt: Date().addingTimeInterval(30 * 24 * 3600),
                payload: .fileOrganizer(FileOrganizerRecoveryPayload(
                    moveMappings: moveMappings,
                    sourceFolder: sourceFolder
                )),
                restoreMappings: newRestoreMappings
            )
            state.snapshot.recoveryItems.insert(recoveryItem, at: 0)
        }

        // Keep unmoved entries for retry; clear only on full success (audit
        // #8). Previously full failure also cleared entries, leaving nothing to
        // retry while the UI reported success.
        let movedIDs = Set(moveMappings.compactMap { mapping -> UUID? in
            entries.first(where: { $0.path == mapping.originalPath })?.id
        })
        if failedMoves.isEmpty {
            state.snapshot.fileOrganizerEntries = []
        } else {
            state.snapshot.fileOrganizerEntries = entries.filter { !movedIDs.contains($0.id) }
        }
        await persistState(context: "file organizer execute plan")

        let allFailed = !failedMoves.isEmpty && moveMappings.isEmpty
        let completedRun = TaskRun(
            id: taskID,
            kind: .organizeFiles,
            status: allFailed ? .failed : .completed,
            summary: AtlasL10n.string(
                moveMappings.count == 1 ? "infrastructure.scan.completed.one" : "infrastructure.scan.completed.other",
                moveMappings.count
            ),
            startedAt: request.issuedAt,
            finishedAt: Date()
        )
        state.snapshot.taskRuns.removeAll { $0.id == taskID }
        state.snapshot.taskRuns.insert(completedRun, at: 0)
        await persistState(context: "file organizer execute complete")

        let response = AtlasResponseEnvelope(
            requestID: request.id,
            response: .accepted(task: AtlasTaskDescriptor(taskID: taskID, kind: .organizeFiles))
        )
        let events = progressEvents(taskID: taskID, total: 3) + [AtlasEventEnvelope(event: .taskFinished(completedRun))]
        await auditStore.append("Executed file organizer plan: \(moveMappings.count) moved, \(failedMoves.count) failed")
        return AtlasWorkerCommandResult(request: request, response: response, events: events, snapshot: state.snapshot, movedCount: moveMappings.count, failedCount: failedMoves.count)
    }

    private func fileOrganizerDryRun(using request: AtlasRequestEnvelope, planID: UUID) async -> AtlasWorkerCommandResult {
        let entries = state.snapshot.fileOrganizerEntries
        let plan = makeFileOrganizerPlan(from: entries)
        guard plan.id == planID else {
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
                    let id = UUID()
                    let intent = AtlasFileOperationIntent(entryID: id, kind: kind, sourcePath: url.path,
                        destinationPath: try destination.map { try AtlasFileSafetyPolicy.expanded($0, homeDirectoryURL: home).path }, expectedIdentity: identity)
                    _ = try AtlasFileSafetyPolicy.validate(intent, context: context)
                    operations.append(intent)
                } catch { return plan } // Preview remains review-only when any target lacks proof.
            }
        }
        return (try? planRegistry.register(plan: plan, operations: operations, policyRevision: 1).plan) ?? plan
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

    private func validateRestoreItems(_ items: [RecoveryItem]) throws {
        for item in items {
            guard let restoreMappings = item.restoreMappings, !restoreMappings.isEmpty else {
                continue
            }
            try validateRestoreMappings(restoreMappings)
        }
    }

    private func validateRestoreMappings(_ restoreMappings: [RecoveryPathMapping]) throws {
        for mapping in restoreMappings {
            try validateRestoreTarget(mapping)
        }
    }

    private func expiredRecoveryItemIDs(asOf now: Date? = nil) -> Set<UUID> {
        let cutoff = now ?? nowProvider()
        return Set(state.snapshot.recoveryItems.compactMap { item in
            item.isExpired(asOf: cutoff) ? item.id : nil
        })
    }

    private func pruneExpiredRecoveryItemsIfNeeded(context: String, now: Date? = nil) async {
        let cutoff = now ?? nowProvider()
        let expiredIDs = expiredRecoveryItemIDs(asOf: cutoff)
        guard !expiredIDs.isEmpty else {
            return
        }

        state.snapshot.recoveryItems.removeAll { expiredIDs.contains($0.id) }
        await persistState(context: context)
        await auditStore.append("Pruned \(expiredIDs.count) expired recovery item(s)")
    }

    private func persistState(context: String) async {
        do {
            _ = try repository.saveState(state)
        } catch {
            await auditStore.append("Failed to persist state after \(context): \(error.localizedDescription)")
            let message = "[AtlasScaffoldWorkerService] Failed to persist state after \(context): \(error.localizedDescription)\n"
            if let data = message.data(using: .utf8) {
                try? FileHandle.standardError.write(contentsOf: data)
            }
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

    private func executeSmartCleanSelections(_ selections: [SmartCleanExecutableSelection]) async throws -> SmartCleanExecutionResult {
        var result = SmartCleanExecutionResult()
        for selection in selections {
            let targetPaths = Array(Set(selection.targetPaths)).sorted()
            guard !targetPaths.isEmpty else {
                result.failedFindingIDs.insert(selection.finding.id)
                result.failureReason = result.failureReason ?? "Smart Clean finding is missing executable targets."
                throw SmartCleanExecutionFailure(result: result)
            }
            do {
                let preparedTargetPaths = try prepareSmartCleanTargetPaths(targetPaths)
                var mappings: [RecoveryPathMapping] = []
                for targetPath in preparedTargetPaths {
                    if let mapping = try await trashSmartCleanTarget(at: targetPath) {
                        mappings.append(mapping)
                        result.restoreMappingsByFindingID[selection.finding.id] = mappings
                    }
                }
                if mappings.isEmpty {
                    result.staleFindingIDs.insert(selection.finding.id)
                } else {
                    result.restoreMappingsByFindingID[selection.finding.id] = mappings
                }
            } catch {
                result.failedFindingIDs.insert(selection.finding.id)
                result.failureReason = result.failureReason ?? error.localizedDescription
                throw SmartCleanExecutionFailure(result: result)
            }
        }
        return result
    }

    private func resolvedTargetPaths(for item: ActionItem, finding: Finding) -> [String] {
        Array(Set(item.targetPaths ?? finding.targetPaths ?? [])).sorted()
    }

    private func prepareSmartCleanTargetPaths(_ targetPaths: [String]) throws -> [String] {
        let validatedURLs = try AtlasPathValidator.validateAll(targetPaths)
        var preparedTargetPaths: [String] = []
        for targetURL in validatedURLs {
            guard FileManager.default.fileExists(atPath: targetURL.path) else {
                continue
            }
            if shouldUseHelperForSmartCleanTarget(targetURL) {
                guard helperExecutor != nil else {
                    throw AtlasWorkspaceRepositoryError.writeFailed("Bundled helper unavailable for Smart Clean target: \(targetURL.path)")
                }
            } else if !isDirectlyTrashableSmartCleanTarget(targetURL) {
                throw AtlasWorkspaceRepositoryError.writeFailed("Smart Clean target is outside the supported execution allowlist: \(targetURL.path)")
            }
            preparedTargetPaths.append(targetURL.path)
        }
        return preparedTargetPaths
    }

    private func trashSmartCleanTarget(at targetPath: String) async throws -> RecoveryPathMapping? {
        let targetURL = URL(fileURLWithPath: targetPath).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return nil
        }

        if shouldUseHelperForSmartCleanTarget(targetURL) {
            guard let helperExecutor else {
                throw AtlasWorkspaceRepositoryError.writeFailed("Bundled helper unavailable for Smart Clean target: \(targetURL.path)")
            }
            let result = try await helperExecutor.perform(AtlasHelperAction(kind: .trashItems, targetPath: targetURL.path))
            guard result.success else {
                throw AtlasWorkspaceRepositoryError.writeFailed(result.message)
            }
            guard let trashedPath = result.resolvedPath else {
                throw AtlasWorkspaceRepositoryError.writeFailed("Smart Clean target was trashed but no recovery path was returned.")
            }
            return RecoveryPathMapping(originalPath: targetURL.path, trashedPath: trashedPath)
        }

        guard isDirectlyTrashableSmartCleanTarget(targetURL) else {
            throw AtlasWorkspaceRepositoryError.writeFailed("Smart Clean target is outside the supported execution allowlist: \(targetURL.path)")
        }

        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: targetURL, resultingItemURL: &trashedURL)
        guard let trashedPath = (trashedURL as URL?)?.path else {
            throw AtlasWorkspaceRepositoryError.writeFailed("Smart Clean target was trashed but no recovery path was returned.")
        }
        return RecoveryPathMapping(originalPath: targetURL.path, trashedPath: trashedPath)
    }

    private func restoreRecoveryMappings(_ restoreMappings: [RecoveryPathMapping]) async throws {
        for mapping in restoreMappings {
            try await restoreRecoveryTarget(mapping)
        }
    }

    private func validateRestoreTarget(_ mapping: RecoveryPathMapping) throws {
        let sourceURL = URL(fileURLWithPath: mapping.trashedPath).resolvingSymlinksInPath()
        let destinationURL = URL(fileURLWithPath: mapping.originalPath).resolvingSymlinksInPath()
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw RecoveryRestoreFailure.executionUnavailable("Recovery source is no longer available on disk: \(sourceURL.path)")
        }
        if shouldUseHelperForSmartCleanTarget(destinationURL) {
            guard helperExecutor != nil else {
                throw RecoveryRestoreFailure.helperUnavailable("Bundled helper unavailable for recovery target: \(destinationURL.path)")
            }
        } else if isDirectlyTrashableSmartCleanTarget(destinationURL) {
            // SmartClean cache paths are valid restore targets
        } else if isFileOrganizerRestoreTarget(mapping) {
            // File organizer targets within home directory are valid restore targets
        } else {
            throw RecoveryRestoreFailure.executionUnavailable("Recovery target is outside the supported execution allowlist: \(destinationURL.path)")
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            throw RecoveryRestoreFailure.restoreConflict("Recovery target already exists: \(destinationURL.path)")
        }
    }

    private func restoreRecoveryTarget(_ mapping: RecoveryPathMapping) async throws {
        try validateRestoreTarget(mapping)
        let source = try AtlasFileSafetyPolicy.expanded(mapping.trashedPath, homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser)
        let destination = try AtlasFileSafetyPolicy.expanded(mapping.originalPath, homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser)
        let intent = AtlasFileOperationIntent(entryID: UUID(), kind: .restore, sourcePath: source.path,
            destinationPath: destination.path, expectedIdentity: try AtlasFileIdentityReader.read(source))
        let context = AtlasFilePolicyContext(recoveryMappings: [source.path: destination.path])
        _ = try AtlasFileMover.moveWithoutReplacing(AtlasFileSafetyPolicy.validate(intent, context: context))
    }

    private func recoveryRestoreFailure(fromHelperMessage message: String) -> RecoveryRestoreFailure {
        if message.hasPrefix("Restore destination already exists:") {
            return .restoreConflict(message)
        }
        return .executionUnavailable(message)
    }

    private func shouldUseHelperForSmartCleanTarget(_ targetURL: URL) -> Bool {
        AtlasSmartCleanExecutionSupport.requiresHelper(for: targetURL)
    }

    private func isDirectlyTrashableSmartCleanTarget(_ targetURL: URL) -> Bool {
        AtlasSmartCleanExecutionSupport.isDirectlyTrashable(targetURL)
    }

    private func isFileOrganizerRestoreTarget(_ mapping: RecoveryPathMapping) -> Bool {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let originalPath = (mapping.originalPath as NSString).expandingTildeInPath
        let trashedPath = (mapping.trashedPath as NSString).expandingTildeInPath
        return originalPath.hasPrefix(homeDir + "/") && trashedPath.hasPrefix(homeDir + "/")
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
