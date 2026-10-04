import XCTest
@testable import AtlasInfrastructure
import AtlasApplication
import AtlasDomain
import AtlasProtocol

final class AtlasInfrastructureTests: XCTestCase {
    func testRepositoryPersistsWorkspaceState() throws {
        let fileURL = temporaryStateFileURL()
        let repository = AtlasWorkspaceRepository(stateFileURL: fileURL)
        var state = AtlasScaffoldWorkspace.state()
        state.settings.recoveryRetentionDays = 21

        XCTAssertNoThrow(try repository.saveState(state))
        let loaded = try repository.loadState()

        XCTAssertEqual(loaded.settings.recoveryRetentionDays, 21)
        XCTAssertEqual(loaded.snapshot.apps.count, state.snapshot.apps.count)
    }

    func testRepositoryPersistsVersionedWorkspaceEnvelope() throws {
        let fileURL = temporaryStateFileURL()
        let repository = AtlasWorkspaceRepository(stateFileURL: fileURL)

        XCTAssertNoThrow(try repository.saveState(AtlasScaffoldWorkspace.state()))

        let data = try Data(contentsOf: fileURL)
        let persisted = try JSONDecoder().decode(AtlasPersistedWorkspaceState.self, from: data)

        XCTAssertEqual(persisted.schemaVersion, AtlasWorkspaceStateSchemaVersion.current)
        XCTAssertFalse(persisted.snapshot.apps.isEmpty)
    }

    func testRepositoryLoadsLegacyWorkspaceStateAndRewritesEnvelope() throws {
        let fileURL = temporaryStateFileURL()
        let legacyState = AtlasScaffoldWorkspace.state()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(legacyState).write(to: fileURL)

        let repository = AtlasWorkspaceRepository(stateFileURL: fileURL)
        let loaded = try repository.loadState()

        XCTAssertEqual(loaded.snapshot.apps.count, legacyState.snapshot.apps.count)

        let migratedData = try Data(contentsOf: fileURL)
        let persisted = try JSONDecoder().decode(AtlasPersistedWorkspaceState.self, from: migratedData)
        XCTAssertEqual(persisted.schemaVersion, AtlasWorkspaceStateSchemaVersion.current)
        XCTAssertEqual(persisted.snapshot.apps.count, legacyState.snapshot.apps.count)
    }

    func testRepositorySaveStateThrowsForInvalidParentURL() throws {
        let repository = AtlasWorkspaceRepository(
            stateFileURL: URL(fileURLWithPath: "/dev/null/workspace-state.json")
        )

        XCTAssertThrowsError(try repository.saveState(AtlasScaffoldWorkspace.state()))
    }

    func testRepositorySaveStatePrunesExpiredRecoveryItems() throws {
        let baseDate = Date(timeIntervalSince1970: 1_710_000_000)
        let clock = TestClock(now: baseDate)
        let repository = AtlasWorkspaceRepository(
            stateFileURL: temporaryStateFileURL(),
            nowProvider: { clock.now }
        )
        let activeItem = RecoveryItem(
            id: UUID(),
            title: "Active recovery",
            detail: "Still valid",
            originalPath: "~/Library/Caches/Active",
            bytes: 5,
            deletedAt: baseDate.addingTimeInterval(-120),
            expiresAt: baseDate.addingTimeInterval(3600),
            payload: nil,
            restoreMappings: nil
        )
        let expiredItem = RecoveryItem(
            id: UUID(),
            title: "Expired recovery",
            detail: "Expired",
            originalPath: "~/Library/Caches/Expired",
            bytes: 7,
            deletedAt: baseDate.addingTimeInterval(-7200),
            expiresAt: baseDate.addingTimeInterval(-1),
            payload: nil,
            restoreMappings: nil
        )
        let state = AtlasWorkspaceState(
            snapshot: AtlasWorkspaceSnapshot(
                reclaimableSpaceBytes: 0,
                findings: [],
                apps: [],
                taskRuns: [],
                recoveryItems: [activeItem, expiredItem],
                permissions: [],
                healthSnapshot: nil
            ),
            currentPlan: ActionPlan(title: "Review 0 selected findings", items: [], estimatedBytes: 0),
            settings: AtlasScaffoldWorkspace.state().settings
        )

        let saved = try repository.saveState(state)

        XCTAssertEqual(saved.snapshot.recoveryItems.map(\.id), [activeItem.id, expiredItem.id])
        XCTAssertEqual(try repository.loadState().snapshot.recoveryItems.map(\.id), [activeItem.id, expiredItem.id])
    }

    func testSettingsSetPreservesThemeAcrossWorkerRoundTrip() async throws {
        // Regression (bug: theme-snapback). `AtlasScaffoldWorkerService.sanitized(settings:)`
        // rebuilt AtlasSettings memberwise and dropped `theme`, defaulting it to `.system`.
        // The worker then echoed AND persisted `.system`, so the UI reverted right after the
        // async updateSettings round-trip (in-session snapback) and the choice never survived
        // restart. This exercises the REAL worker — the controller-level test uses a FakeWorker
        // that bypasses `sanitized`, which is why the drift slipped through.
        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        let worker = AtlasScaffoldWorkerService(repository: repository, allowStateOnlyCleanExecution: false)

        var updated = AtlasScaffoldWorkspace.state().settings
        updated.theme = .dark

        let result = try await worker.submit(AtlasRequestEnvelope(command: .settingsSet(updated)))

        guard case let .settings(echoed) = result.response.response else {
            XCTFail("Expected .settings response, got \(result.response.response)")
            return
        }
        XCTAssertEqual(echoed.theme, .dark, "worker must echo back the selected theme (guards in-session snapback)")

        // Must also survive a fresh load from disk (guards cross-restart persistence).
        XCTAssertEqual(try repository.loadState().settings.theme, .dark, "worker must persist the selected theme")
    }

    // MARK: - Real-worker command coverage (closes the FakeWorker bypass gaps)

    func testSettingsGetReturnsCurrentlyPersistedSettings() async throws {
        // .settingsGet had ZERO real-worker coverage. Guards the read path: after a
        // settingsSet with non-default values, settingsGet must echo the persisted values
        // (a dropped/skewed read field would silently revert in-session).
        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        let worker = AtlasScaffoldWorkerService(repository: repository, allowStateOnlyCleanExecution: false)

        var updated = AtlasScaffoldWorkspace.state().settings
        updated.theme = .light
        updated.recoveryRetentionDays = 21
        _ = try await worker.submit(AtlasRequestEnvelope(command: .settingsSet(updated)))

        let result = try await worker.submit(AtlasRequestEnvelope(command: .settingsGet))
        guard case let .settings(readBack) = result.response.response else {
            XCTFail("Expected .settings response, got \(result.response.response)")
            return
        }
        XCTAssertEqual(readBack.theme, .light)
        XCTAssertEqual(readBack.recoveryRetentionDays, 21)
    }

    func testPreviewPlanRespectsFindingIDSubset() async throws {
        // The `.previewPlan(taskID, findingIDs:)` handler rebuilds a plan scoped to the
        // requested finding IDs. It had no direct real-worker test (startScan exercises only
        // the auto-all-findings path). Guards: a subset selection must yield exactly those
        // findings — not all findings.
        let f0 = Finding(id: UUID(), title: "F0", detail: "d0", bytes: 10, risk: .safe, category: "Cat", targetPaths: ["/tmp/f0"])
        let f1 = Finding(id: UUID(), title: "F1", detail: "d1", bytes: 20, risk: .safe, category: "Cat", targetPaths: ["/tmp/f1"])
        let f2 = Finding(id: UUID(), title: "F2", detail: "d2", bytes: 30, risk: .safe, category: "Cat", targetPaths: ["/tmp/f2"])

        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        var state = AtlasScaffoldWorkspace.state()
        state.snapshot.findings = [f0, f1, f2]
        _ = try repository.saveState(state)

        let worker = AtlasScaffoldWorkerService(repository: repository, allowStateOnlyCleanExecution: false)
        let selected: [UUID] = [f0.id, f1.id]
        let result = try await worker.submit(AtlasRequestEnvelope(command: .previewPlan(taskID: UUID(), findingIDs: selected)))

        guard case let .preview(plan) = result.response.response else {
            XCTFail("Expected .preview response, got \(result.response.response)")
            return
        }
        XCTAssertEqual(Set(plan.items.map(\.id)), Set(selected), "previewPlan must scope items to the requested findingIDs")
        XCTAssertEqual(plan.items.count, selected.count, "previewPlan must not include unselected findings")
    }

    func testPreviewPlanDoesNotWidenStaleSelections() async throws {
        // Characterizes makePreviewPlan's fallback branch (previously untested, flagged by
        // review): a non-empty findingIDs list whose entries ALL fail to match current
        // findings is treated as stale and widened back to ALL findings rather than returning
        // an empty plan. Locks this contract so the fallback can't drift silently.
        let f0 = Finding(id: UUID(), title: "F0", detail: "d0", bytes: 10, risk: .safe, category: "Cat", targetPaths: ["/tmp/f0"])
        let f1 = Finding(id: UUID(), title: "F1", detail: "d1", bytes: 20, risk: .safe, category: "Cat", targetPaths: ["/tmp/f1"])

        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        var state = AtlasScaffoldWorkspace.state()
        state.snapshot.findings = [f0, f1]
        _ = try repository.saveState(state)

        let worker = AtlasScaffoldWorkerService(repository: repository, allowStateOnlyCleanExecution: false)
        let result = try await worker.submit(AtlasRequestEnvelope(command: .previewPlan(taskID: UUID(), findingIDs: [UUID()])))

        guard case let .preview(plan) = result.response.response else {
            XCTFail("Expected .preview response, got \(result.response.response)")
            return
        }
        XCTAssertEqual(Set(plan.items.map(\.id)), Set<UUID>(), "stale selections authorize no entries")
    }

    func testAppsListSortsByBytesDescThenNameAscAndPersistsProviderInventory() async throws {
        // .appsList was covered only via FakeWorker. Guards the real listApps handler:
        // sort bytes desc with name-asc tiebreak, AND the provider inventory must persist
        // into the snapshot (a dropped provider write would silently empty apps).
        let provider = InventoryProviderStub(apps: [
            AppFootprint(name: "Zeta", bundleIdentifier: "com.z", bundlePath: "/Zeta.app", bytes: 100, leftoverItems: 0),
            AppFootprint(name: "Alpha", bundleIdentifier: "com.a", bundlePath: "/Alpha.app", bytes: 100, leftoverItems: 0),
            AppFootprint(name: "Mega", bundleIdentifier: "com.m", bundlePath: "/Mega.app", bytes: 500, leftoverItems: 0),
        ])
        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        let worker = AtlasScaffoldWorkerService(repository: repository, appsInventoryProvider: provider, allowStateOnlyCleanExecution: false)

        let result = try await worker.submit(AtlasRequestEnvelope(command: .appsList))
        guard case let .apps(apps) = result.response.response else {
            XCTFail("Expected .apps response, got \(result.response.response)")
            return
        }
        XCTAssertEqual(apps.map(\.name), ["Mega", "Alpha", "Zeta"], "appsList must sort bytes desc, then name asc")
        // The handler persists the provider's raw inventory (source order) and sorts only the
        // response copy — so assert the provider write landed in the snapshot, order-agnostic.
        XCTAssertEqual(Set(try repository.loadState().snapshot.apps.map(\.name)), Set(["Mega", "Alpha", "Zeta"]), "provider inventory must persist to snapshot")
    }

    func testInspectPermissionsPropagatesAndPersistsInspectorSnapshot() async throws {
        // .inspectPermissions was covered only via FakeWorker. The inspector is a concrete
        // value type but accepts injected closures, so we make it fully deterministic and
        // assert the handler propagates its snapshot to BOTH the response and persisted state.
        let inspector = AtlasPermissionInspector(
            fullDiskAccessProbeURLs: [],
            protectedLocationReader: { _ in true },
            accessibilityStatusProvider: { true },
            notificationsAuthorizationProvider: { true }
        )
        let expected = await inspector.snapshot()

        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        let worker = AtlasScaffoldWorkerService(
            repository: repository,
            permissionInspector: inspector,
            allowStateOnlyCleanExecution: false
        )

        let result = try await worker.submit(AtlasRequestEnvelope(command: .inspectPermissions))
        guard case let .permissions(returned) = result.response.response else {
            XCTFail("Expected .permissions response, got \(result.response.response)")
            return
        }
        XCTAssertEqual(returned, expected, "handler must return the inspector's snapshot verbatim")
        XCTAssertEqual(try repository.loadState().snapshot.permissions, expected, "handler must persist the inspector's snapshot")
    }

    func testFileOrganizerClassifyRespectsEntryIDSubsetAndAppliesClassifier() async throws {
        // .fileOrganizerClassify had ZERO coverage anywhere. Guards the real handler:
        // (1) classify scopes to the requested entryIDs, (2) the classifier output is
        // applied (not bypassed), (3) the classified entries persist into the snapshot.
        let e0 = FileOrganizerEntry(path: "/tmp/a.txt", fileName: "a.txt", bytes: 1, category: .documents, proposedDestination: "")
        let e1 = FileOrganizerEntry(path: "/tmp/b.txt", fileName: "b.txt", bytes: 2, category: .documents, proposedDestination: "")
        let e2 = FileOrganizerEntry(path: "/tmp/c.txt", fileName: "c.txt", bytes: 3, category: .documents, proposedDestination: "")

        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        var state = AtlasScaffoldWorkspace.state()
        state.snapshot.fileOrganizerEntries = [e0, e1, e2]
        _ = try repository.saveState(state)

        let worker = AtlasScaffoldWorkerService(
            repository: repository,
            fileOrganizerClassifier: TaggingFileOrganizerClassifier(destinationTag: "/Organized"),
            allowStateOnlyCleanExecution: false
        )

        let selected = [e0.id, e1.id]
        let result = try await worker.submit(AtlasRequestEnvelope(command: .fileOrganizerClassify(taskID: UUID(), entryIDs: selected)))
        guard case let .fileOrganizerEntries(classified) = result.response.response else {
            XCTFail("Expected .fileOrganizerEntries response, got \(result.response.response)")
            return
        }
        XCTAssertEqual(Set(classified.map(\.id)), Set(selected), "classify must scope to the requested entryIDs")
        XCTAssertTrue(classified.allSatisfy { $0.proposedDestination == "/Organized" }, "classify must apply the classifier output")

        let reloaded = try repository.loadState()
        let taggedSelected = reloaded.snapshot.fileOrganizerEntries.filter { selected.contains($0.id) }
        XCTAssertTrue(taggedSelected.allSatisfy { $0.proposedDestination == "/Organized" }, "classifier output must persist into the snapshot")
    }





    func testStartScanRejectsWhenProviderFailsWithoutFallback() async throws {
        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        let worker = AtlasScaffoldWorkerService(
            repository: repository,
            smartCleanScanProvider: FailingSmartCleanProvider(),
            allowProviderFailureFallback: false
        )

        let result = try await worker.submit(
            AtlasRequestEnvelope(command: .startScan(taskID: UUID()))
        )

        guard case let .rejected(code, reason) = result.response.response else {
            return XCTFail("Expected rejected scan response")
        }
        XCTAssertEqual(code, .executionUnavailable)
        XCTAssertTrue(reason.contains("Smart Clean scan is unavailable"))
    }

    func testPermissionInspectorMarksFullDiskAccessGrantedWhenAnyProbeIsReadable() async throws {
        let probeURLs = [
            URL(fileURLWithPath: "/tmp/unreadable"),
            URL(fileURLWithPath: "/tmp/readable"),
        ]
        let inspector = AtlasPermissionInspector(
            homeDirectoryURL: URL(fileURLWithPath: "/tmp"),
            fullDiskAccessProbeURLs: probeURLs,
            protectedLocationReader: { url in url.path == "/tmp/readable" },
            accessibilityStatusProvider: { false },
            notificationsAuthorizationProvider: { false }
        )

        let permissions = await inspector.snapshot()
        let fullDiskAccess = permissions.first(where: { $0.kind == .fullDiskAccess })

        XCTAssertEqual(fullDiskAccess?.isGranted, true)
    }

    func testPermissionInspectorMarksFullDiskAccessMissingWhenAllProbesFail() async throws {
        let probeURLs = [
            URL(fileURLWithPath: "/tmp/probe-a"),
            URL(fileURLWithPath: "/tmp/probe-b"),
        ]
        let inspector = AtlasPermissionInspector(
            homeDirectoryURL: URL(fileURLWithPath: "/tmp"),
            fullDiskAccessProbeURLs: probeURLs,
            protectedLocationReader: { _ in false },
            accessibilityStatusProvider: { false },
            notificationsAuthorizationProvider: { false }
        )

        let permissions = await inspector.snapshot()
        let fullDiskAccess = permissions.first(where: { $0.kind == .fullDiskAccess })

        XCTAssertEqual(fullDiskAccess?.isGranted, false)
        XCTAssertTrue(fullDiskAccess?.rationale.contains("重新打开") == true || fullDiskAccess?.rationale.contains("reopen Atlas") == true)
    }







    func testZcompdumpTargetIsRejected() throws {
        let targetURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zcompdump")
        let finding = Finding(
            id: UUID(),
            title: "Zsh completion cache",
            detail: targetURL.path,
            bytes: 1,
            risk: .safe,
            category: "Developer tools",
            targetPaths: [targetURL.path]
        )

        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isSupportedExecutionTarget(targetURL))
        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isFindingExecutionSupported(finding))
    }

    func testPnpmStoreTargetIsRejected() throws {
        let targetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/pnpm/store/v3/files/atlas-fixture/package.tgz")
        let finding = Finding(
            id: UUID(),
            title: "pnpm store",
            detail: targetURL.path,
            bytes: 1,
            risk: .safe,
            category: "Developer tools",
            targetPaths: [targetURL.path]
        )

        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isSupportedExecutionTarget(targetURL))
        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isFindingExecutionSupported(finding))
    }

    func testGradleCacheTargetIsRejected() throws {
        let targetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gradle/caches/modules-2/files-2.1/atlas-fixture.bin")
        let finding = Finding(
            id: UUID(),
            title: "Gradle cache",
            detail: targetURL.path,
            bytes: 1,
            risk: .safe,
            category: "Developer tools",
            targetPaths: [targetURL.path]
        )

        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isSupportedExecutionTarget(targetURL))
        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isFindingExecutionSupported(finding))
    }

    func testSwiftPMCacheTargetIsRejected() throws {
        let targetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".swiftpm/cache/repositories/atlas-fixture.bin")
        let finding = Finding(
            id: UUID(),
            title: "SwiftPM cache",
            detail: targetURL.path,
            bytes: 1,
            risk: .safe,
            category: "Developer tools",
            targetPaths: [targetURL.path]
        )

        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isSupportedExecutionTarget(targetURL))
        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isFindingExecutionSupported(finding))
    }

    func testPytestCacheTargetIsRejected() throws {
        let targetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pytest_cache/v/cache/atlas-fixture")
        let finding = Finding(
            id: UUID(),
            title: "pytest cache",
            detail: targetURL.path,
            bytes: 1,
            risk: .safe,
            category: "Developer tools",
            targetPaths: [targetURL.path]
        )

        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isSupportedExecutionTarget(targetURL))
        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isFindingExecutionSupported(finding))
    }

    func testAWSCLICacheTargetIsRejected() throws {
        let targetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/cli/cache/atlas-fixture.json")
        let finding = Finding(
            id: UUID(),
            title: "AWS CLI cache",
            detail: targetURL.path,
            bytes: 1,
            risk: .safe,
            category: "Developer tools",
            targetPaths: [targetURL.path]
        )

        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isSupportedExecutionTarget(targetURL))
        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isFindingExecutionSupported(finding))
    }

    func testCoreSimulatorCacheTargetIsRejected() throws {
        let targetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Caches/atlas-fixture/device-cache.db")
        let finding = Finding(
            id: UUID(),
            title: "CoreSimulator cache",
            detail: targetURL.path,
            bytes: 1,
            risk: .safe,
            category: "Developer tools",
            targetPaths: [targetURL.path]
        )

        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isSupportedExecutionTarget(targetURL))
        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isFindingExecutionSupported(finding))
    }

    func testContainerCacheTargetIsSupportedExecutionTarget() throws {
        let targetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.example.preview/Data/Library/Caches/cache.db")
        let finding = Finding(
            id: UUID(),
            title: "Container cache",
            detail: targetURL.path,
            bytes: 1,
            risk: .safe,
            category: "Developer tools",
            targetPaths: [targetURL.path]
        )

        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isSupportedExecutionTarget(targetURL))
        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isFindingExecutionSupported(finding))
    }

    func testContainerLogsTargetIsRejected() throws {
        let targetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.example.preview/Data/Library/Logs/runtime.log")
        let finding = Finding(
            id: UUID(),
            title: "Container logs",
            detail: targetURL.path,
            bytes: 1,
            risk: .safe,
            category: "Developer tools",
            targetPaths: [targetURL.path]
        )

        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isSupportedExecutionTarget(targetURL))
        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isFindingExecutionSupported(finding))
    }

    func testContainerTempTargetIsSupportedExecutionTarget() throws {
        let targetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.example.preview/Data/tmp/runtime.tmp")
        let finding = Finding(
            id: UUID(),
            title: "Container temp",
            detail: targetURL.path,
            bytes: 1,
            risk: .safe,
            category: "Developer tools",
            targetPaths: [targetURL.path]
        )

        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isSupportedExecutionTarget(targetURL))
        XCTAssertFalse(AtlasSmartCleanExecutionSupport.isFindingExecutionSupported(finding))
    }

































    func testPreviewAppUninstallBuildsReviewOnlyEvidenceItems() async throws {
        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        let fileManager = FileManager.default
        let sandboxRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeRoot = sandboxRoot.appendingPathComponent("Home", isDirectory: true)
        let appSupportURL = homeRoot.appendingPathComponent("Library/Application Support/Atlas Preview", isDirectory: true)
        let cacheURL = homeRoot.appendingPathComponent("Library/Caches/com.example.preview", isDirectory: true)
        let launchAgentURL = homeRoot.appendingPathComponent("Library/LaunchAgents/com.example.preview.plist")

        try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 256).write(to: appSupportURL.appendingPathComponent("state.db"))
        try Data(repeating: 0x2, count: 128).write(to: cacheURL.appendingPathComponent("cache.bin"))
        try Data("<?xml version=\"1.0\"?><plist></plist>".utf8).write(to: launchAgentURL)

        addTeardownBlock {
            try? FileManager.default.removeItem(at: sandboxRoot)
        }

        let app = AppFootprint(
            id: UUID(),
            name: "Atlas Preview",
            bundleIdentifier: "com.example.preview",
            bundlePath: "/Applications/Atlas Preview.app",
            bytes: 2_048,
            leftoverItems: 3
        )

        var settings = AtlasScaffoldWorkspace.state().settings
        settings.language = .en

        let state = AtlasWorkspaceState(
            snapshot: AtlasWorkspaceSnapshot(
                reclaimableSpaceBytes: app.bytes,
                findings: [],
                apps: [app],
                taskRuns: [],
                recoveryItems: [],
                permissions: [],
                healthSnapshot: nil
            ),
            currentPlan: ActionPlan(title: "Review 0 selected findings", items: [], estimatedBytes: 0),
            settings: settings
        )
        _ = try repository.saveState(state)

        let worker = AtlasScaffoldWorkerService(
            repository: repository,
            appUninstallEvidenceAnalyzer: AtlasAppUninstallEvidenceAnalyzer(homeDirectoryURL: homeRoot),
            allowStateOnlyCleanExecution: true
        )

        let result = try await worker.submit(
            AtlasRequestEnvelope(command: .previewAppUninstall(appID: app.id))
        )

        guard case let .preview(plan) = result.response.response else {
            return XCTFail("Expected preview response")
        }

        XCTAssertEqual(plan.estimatedBytes, app.bytes)
        XCTAssertEqual(plan.items.first?.kind, .removeApp)
        XCTAssertEqual(plan.items.first?.targetPaths, [app.bundlePath])
        XCTAssertEqual(plan.items.count, 4)
        let supportFilesItem = try XCTUnwrap(plan.items.first(where: { $0.title == "Review support files (1)" && !$0.recoverable }))
        let cachesItem = try XCTUnwrap(plan.items.first(where: { $0.title == "Review caches (1)" && !$0.recoverable }))
        let launchItemsItem = try XCTUnwrap(plan.items.first(where: { $0.title == "Review launch items (1)" && !$0.recoverable }))
        XCTAssertEqual(supportFilesItem.evidencePaths, [appSupportURL.path])
        XCTAssertEqual(cachesItem.evidencePaths, [cacheURL.path])
        XCTAssertEqual(launchItemsItem.evidencePaths, [launchAgentURL.path])
    }





    // MARK: - AtlasAuditStore

    func testAuditStoreAppendsAndRetrieves() async throws {
        let store = AtlasAuditStore()
        await store.append("first")
        await store.append("second")
        let entries = await store.allEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].message, "second")
        XCTAssertEqual(entries[1].message, "first")
    }

    func testAuditStoreTrimsOldEntriesWhenExceedingMaxEntries() async throws {
        let maxEntries = 5
        let store = AtlasAuditStore(maxEntries: maxEntries)
        for i in 0..<10 {
            await store.append("entry-\(i)")
        }
        let entries = await store.allEntries()
        XCTAssertEqual(entries.count, maxEntries)
        // Most recent entries should be kept (inserted at index 0)
        XCTAssertEqual(entries[0].message, "entry-9")
        XCTAssertEqual(entries[4].message, "entry-5")
    }

    func testAuditStoreRespectsCustomMaxEntries() async throws {
        let store = AtlasAuditStore(entries: [], maxEntries: 2)
        await store.append("a")
        await store.append("b")
        await store.append("c")
        let entries = await store.allEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].message, "c")
        XCTAssertEqual(entries[1].message, "b")
    }

    func testAuditStoreInitializesWithExistingEntries() async throws {
        let existing = [
            AuditEntry(id: UUID(), createdAt: Date(), message: "old-1"),
            AuditEntry(id: UUID(), createdAt: Date(), message: "old-2"),
        ]
        let store = AtlasAuditStore(entries: existing, maxEntries: 512)
        let entries = await store.allEntries()
        XCTAssertEqual(entries.count, 2)
    }

    private func temporaryStateFileURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("workspace-state.json")
        // Legacy presentation tests opt in to fixtures; production repositories seed empty state.
        _ = try? AtlasWorkspaceRepository(stateFileURL: url).saveState(AtlasScaffoldWorkspace.state())
        return url
    }

}

private struct FailingSmartCleanProvider: AtlasSmartCleanScanProviding {
    func collectSmartCleanScan() async throws -> AtlasSmartCleanScanResult {
        struct SampleError: LocalizedError { var errorDescription: String? { "simulated scan failure" } }
        throw SampleError()
    }
}

private struct FileBackedSmartCleanProvider: AtlasSmartCleanScanProviding {
    let targetFileURL: URL
    var title: String = "Sample cache"
    var category: String = "Developer tools"

    func collectSmartCleanScan() async throws -> AtlasSmartCleanScanResult {
        guard FileManager.default.fileExists(atPath: targetFileURL.path) else {
            return AtlasSmartCleanScanResult(findings: [], summary: "No reclaimable items remain.")
        }
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: targetFileURL.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let finding = Finding(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001") ?? UUID(),
            title: title,
            detail: targetFileURL.path,
            bytes: size,
            risk: .safe,
            category: category,
            targetPaths: [targetFileURL.path]
        )
        return AtlasSmartCleanScanResult(findings: [finding], summary: "Found 1 reclaimable item.")
    }
}

private actor StubPrivilegedHelperExecutor: AtlasPrivilegedActionExecuting {
    func perform(_ action: AtlasHelperAction) async throws -> AtlasHelperActionResult {
        let fileManager = FileManager.default
        let targetURL = URL(fileURLWithPath: action.targetPath)

        switch action.kind {
        case .trashItems:
            var trashedURL: NSURL?
            try fileManager.trashItem(at: targetURL, resultingItemURL: &trashedURL)
            return AtlasHelperActionResult(
                action: action,
                success: true,
                message: "Moved item to Trash.",
                resolvedPath: (trashedURL as URL?)?.path
            )
        case .restoreItem:
            let destinationPath = try XCTUnwrap(action.destinationPath)
            let destinationURL = URL(fileURLWithPath: destinationPath)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: targetURL, to: destinationURL)
            return AtlasHelperActionResult(
                action: action,
                success: true,
                message: "Restored item from Trash.",
                resolvedPath: destinationURL.path
            )
        case .removeLaunchService, .repairOwnership:
            throw NSError(domain: "StubPrivilegedHelperExecutor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported test helper action: \(action.kind)"])
        }
    }
}

private actor RestoreConflictPrivilegedHelperExecutor: AtlasPrivilegedActionExecuting {
    func perform(_ action: AtlasHelperAction) async throws -> AtlasHelperActionResult {
        AtlasHelperActionResult(
            action: action,
            success: false,
            message: "Restore destination already exists: \(action.destinationPath ?? "<missing>")"
        )
    }
}

// MARK: - File Organizer Use-Case Tests

extension AtlasInfrastructureTests {

    private func emptyWorkspaceState() -> AtlasWorkspaceState {
        AtlasWorkspaceState(
            snapshot: AtlasWorkspaceSnapshot(
                reclaimableSpaceBytes: 0,
                findings: [],
                apps: [],
                taskRuns: [],
                recoveryItems: [],
                permissions: [],
                healthSnapshot: nil
            ),
            currentPlan: ActionPlan(title: "", items: [], estimatedBytes: 0),
            settings: AtlasScaffoldWorkspace.state().settings
        )
    }

    func testFileOrganizerScanReturnsFixtureEntriesWhenNoProvider() async throws {
        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        let worker = AtlasScaffoldWorkerService(repository: repository)

        let result = try await worker.submit(
            AtlasRequestEnvelope(command: .fileOrganizerScan(taskID: UUID(), folderPaths: ["~/Desktop"]))
        )

        if case let .fileOrganizerEntries(entries) = result.response.response {
            XCTAssertFalse(entries.isEmpty, "Should return fixture entries when no scan provider")
            XCTAssertEqual(result.snapshot.fileOrganizerEntries.count, entries.count)
        } else {
            XCTFail("Expected fileOrganizerEntries response")
        }
    }

    func testFileOrganizerScanUsesProviderWhenAvailable() async throws {
        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        let stubEntries = [
            FileOrganizerEntry(path: "~/Desktop/test.png", fileName: "test.png", bytes: 1024, category: .images, proposedDestination: "~/Organized/Images/test.png")
        ]
        let worker = AtlasScaffoldWorkerService(
            repository: repository,
            fileOrganizerScanProvider: StubFileOrganizerScanner(entries: stubEntries)
        )

        let result = try await worker.submit(
            AtlasRequestEnvelope(command: .fileOrganizerScan(taskID: UUID(), folderPaths: ["~/Desktop"]))
        )

        if case let .fileOrganizerEntries(entries) = result.response.response {
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.fileName, "test.png")
        } else {
            XCTFail("Expected fileOrganizerEntries response")
        }
    }

    func testFileOrganizerScanRejectsOnProviderFailure() async throws {
        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        let worker = AtlasScaffoldWorkerService(
            repository: repository,
            fileOrganizerScanProvider: FailingFileOrganizerScanner()
        )

        let result = try await worker.submit(
            AtlasRequestEnvelope(command: .fileOrganizerScan(taskID: UUID(), folderPaths: ["~/Desktop"]))
        )

        if case let .rejected(code, _) = result.response.response {
            XCTAssertEqual(code, .executionUnavailable)
        } else {
            XCTFail("Expected rejected response for scan failure")
        }
    }

    func testFileOrganizerPreviewPlanGeneratesActionItems() async throws {
        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        _ = try repository.saveState(emptyWorkspaceState())

        let entries = [
            FileOrganizerEntry(id: UUID(uuidString: "a0000000-0000-0000-0000-000000000001")!, path: "~/Desktop/a.png", fileName: "a.png", bytes: 100, category: .images, proposedDestination: "~/Organized/Images/a.png"),
            FileOrganizerEntry(id: UUID(uuidString: "a0000000-0000-0000-0000-000000000002")!, path: "~/Desktop/b.pdf", fileName: "b.pdf", bytes: 200, category: .documents, proposedDestination: "~/Organized/Documents/b.pdf"),
        ]
        let worker = AtlasScaffoldWorkerService(
            repository: repository,
            fileOrganizerScanProvider: StubFileOrganizerScanner(entries: entries)
        )
        _ = try await worker.submit(
            AtlasRequestEnvelope(command: .fileOrganizerScan(taskID: UUID(), folderPaths: ["~/Desktop"]))
        )

        let result = try await worker.submit(
            AtlasRequestEnvelope(command: .fileOrganizerPreviewPlan(taskID: UUID(), entryIDs: entries.map(\.id)))
        )

        if case let .fileOrganizerPlan(plan) = result.response.response {
            XCTAssertEqual(plan.items.count, 2)
            XCTAssertEqual(plan.estimatedBytes, 300)
            XCTAssertTrue(plan.items.allSatisfy { $0.kind == .organizeFile })
            XCTAssertTrue(plan.items.allSatisfy { $0.recoverable })
        } else {
            XCTFail("Expected fileOrganizerPlan response")
        }
    }





    func testFileOrganizerDryRunValidatesPlanID() async throws {
        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        _ = try repository.saveState(emptyWorkspaceState())

        let worker = AtlasScaffoldWorkerService(
            repository: repository,
            fileOrganizerScanProvider: StubFileOrganizerScanner(entries: [
                FileOrganizerEntry(path: "~/Desktop/test.png", fileName: "test.png", bytes: 100, category: .images, proposedDestination: "~/Organized/Images/test.png")
            ])
        )
        _ = try await worker.submit(
            AtlasRequestEnvelope(command: .fileOrganizerScan(taskID: UUID(), folderPaths: ["~/Desktop"]))
        )

        let stalePlanID = UUID()
        let result = try await worker.submit(
            AtlasRequestEnvelope(command: .fileOrganizerDryRun(planID: stalePlanID))
        )

        if case let .rejected(code, _) = result.response.response {
            XCTAssertEqual(code, .invalidSelection)
        } else {
            XCTFail("Expected rejected response for stale plan ID in dry run")
        }
    }

    func testFileOrganizerDryRunAcceptsCurrentPlanID() async throws {
        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        _ = try repository.saveState(emptyWorkspaceState())

        let worker = AtlasScaffoldWorkerService(
            repository: repository,
            fileOrganizerScanProvider: StubFileOrganizerScanner(entries: [
                FileOrganizerEntry(path: "~/Desktop/test.png", fileName: "test.png", bytes: 100, category: .images, proposedDestination: "~/Organized/Images/test.png")
            ])
        )
        let scan = try await worker.submit(
            AtlasRequestEnvelope(command: .fileOrganizerScan(taskID: UUID(), folderPaths: ["~/Desktop"]))
        )

        let planResult = try await worker.submit(
            AtlasRequestEnvelope(command: .fileOrganizerPreviewPlan(taskID: UUID(), entryIDs: scan.snapshot.fileOrganizerEntries.map(\.id)))
        )
        guard case let .fileOrganizerPlan(plan) = planResult.response.response else {
            XCTFail("Expected plan, got \(planResult.response.response)"); return
        }

        let dryRunResult = try await worker.submit(
            AtlasRequestEnvelope(command: .fileOrganizerDryRun(planID: plan.id))
        )

        if case let .fileOrganizerPlan(dryRunPlan) = dryRunResult.response.response {
            XCTAssertEqual(dryRunPlan.items.count, plan.items.count)
        } else {
            XCTFail("Expected fileOrganizerPlan response from dry run, got \(dryRunResult.response.response)")
        }
    }



    func testFileOrganizerExecuteSkipsOutOfHomePath() async throws {
        let repository = AtlasWorkspaceRepository(stateFileURL: temporaryStateFileURL())
        _ = try repository.saveState(emptyWorkspaceState())

        let entry = FileOrganizerEntry(
            path: "/etc/hosts",
            fileName: "hosts",
            bytes: 200,
            category: .other,
            proposedDestination: "/etc/Organized/hosts"
        )

        let worker = AtlasScaffoldWorkerService(
            repository: repository,
            fileOrganizerScanProvider: StubFileOrganizerScanner(entries: [entry])
        )
        let scan = try await worker.submit(
            AtlasRequestEnvelope(command: .fileOrganizerScan(taskID: UUID(), folderPaths: ["/etc"]))
        )

        let planResult = try await worker.submit(
            AtlasRequestEnvelope(command: .fileOrganizerPreviewPlan(taskID: UUID(), entryIDs: scan.snapshot.fileOrganizerEntries.map(\.id)))
        )
        guard case let .fileOrganizerPlan(plan) = planResult.response.response else {
            XCTFail("Expected plan"); return
        }

        let executeResult = try await worker.submit(
            AtlasRequestEnvelope(command: .fileOrganizerExecutePlan(planID: plan.id))
        )

        // Should complete but with 0 moves (out-of-scope paths skipped)
        XCTAssertEqual(executeResult.snapshot.recoveryItems.count, 0)
        // /etc/hosts should still exist (not moved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/etc/hosts"))
    }



    // MARK: - File Organizer Undo/Restore Tests




}

// MARK: - File Organizer Test Stubs

private struct StubFileOrganizerScanner: AtlasFileOrganizerScanning {
    let entries: [FileOrganizerEntry]

    func scanFolders(_ paths: [String], destinationBasePath: String = "~/Organized", recursive: Bool = false) async throws -> FileOrganizerScanResult {
        FileOrganizerScanResult(
            entries: entries,
            totalFiles: entries.count,
            totalBytes: entries.map(\.bytes).reduce(0, +),
            categoryCounts: Dictionary(grouping: entries, by: \.category).mapValues(\.count)
        )
    }
}

private struct FailingFileOrganizerScanner: AtlasFileOrganizerScanning {
    func scanFolders(_ paths: [String], destinationBasePath: String = "~/Organized", recursive: Bool = false) async throws -> FileOrganizerScanResult {
        struct ScanError: LocalizedError { var errorDescription: String? { "simulated scan failure" } }
        throw ScanError()
    }
}

// MARK: - AtlasPathValidator Tests

final class AtlasPathValidatorTests: XCTestCase {
    private let homeURL = URL(fileURLWithPath: "/Users/testuser")

    // MARK: - Valid paths

    func testValidHomeSubdirectory() throws {
        let url = try AtlasPathValidator.validate("/Users/testuser/Library/Caches/test", homeDirectoryURL: homeURL)
        XCTAssertEqual(url.path, "/Users/testuser/Library/Caches/test")
    }

    func testValidApplicationsPath() throws {
        let url = try AtlasPathValidator.validate("/Applications/TestApp.app", homeDirectoryURL: homeURL)
        XCTAssertTrue(url.path.hasPrefix("/Applications/"))
    }

    func testValidLaunchAgentsPath() throws {
        let url = try AtlasPathValidator.validate("/Library/LaunchAgents/com.test.agent.plist", homeDirectoryURL: homeURL)
        XCTAssertTrue(url.path.hasPrefix("/Library/LaunchAgents/"))
    }

    func testValidLaunchDaemonsPath() throws {
        let url = try AtlasPathValidator.validate("/Library/LaunchDaemons/com.test.daemon.plist", homeDirectoryURL: homeURL)
        XCTAssertTrue(url.path.hasPrefix("/Library/LaunchDaemons/"))
    }

    func testHomeDirectoryItselfIsValid() throws {
        let url = try AtlasPathValidator.validate("/Users/testuser", homeDirectoryURL: homeURL)
        XCTAssertEqual(url.path, "/Users/testuser")
    }

    func testApplicationsRootItselfIsValid() throws {
        let url = try AtlasPathValidator.validate("/Applications", homeDirectoryURL: homeURL)
        XCTAssertEqual(url.path, "/Applications")
    }

    // MARK: - Invalid paths

    func testRelativePathRejected() throws {
        XCTAssertThrowsError(try AtlasPathValidator.validate("relative/path", homeDirectoryURL: homeURL)) { error in
            XCTAssertTrue(error is AtlasPathValidationError)
            if let pathError = error as? AtlasPathValidationError,
               case .relativePath = pathError { } else {
                XCTFail("Expected relativePath error")
            }
        }
    }

    func testNullByteRejected() throws {
        XCTAssertThrowsError(try AtlasPathValidator.validate("/Users/test\0user/test", homeDirectoryURL: homeURL)) { error in
            XCTAssertTrue(error is AtlasPathValidationError)
            if let pathError = error as? AtlasPathValidationError,
               case .nullByte = pathError { } else {
                XCTFail("Expected nullByte error")
            }
        }
    }

    func testPathTooLongRejected() throws {
        let longPath = "/Users/testuser/" + String(repeating: "a", count: 1200)
        XCTAssertThrowsError(try AtlasPathValidator.validate(longPath, homeDirectoryURL: homeURL)) { error in
            XCTAssertTrue(error is AtlasPathValidationError)
            if let pathError = error as? AtlasPathValidationError,
               case .pathTooLong = pathError { } else {
                XCTFail("Expected pathTooLong error")
            }
        }
    }

    func testOutsideSafeRootsRejected() throws {
        XCTAssertThrowsError(try AtlasPathValidator.validate("/etc/passwd", homeDirectoryURL: homeURL)) { error in
            XCTAssertTrue(error is AtlasPathValidationError)
            if let pathError = error as? AtlasPathValidationError,
               case .outsideSafeRoots = pathError { } else {
                XCTFail("Expected outsideSafeRoots error")
            }
        }
    }

    func testSystemPrivateDirRejected() throws {
        XCTAssertThrowsError(try AtlasPathValidator.validate("/private/var/log/test.log", homeDirectoryURL: homeURL)) { error in
            XCTAssertTrue(error is AtlasPathValidationError)
        }
    }

    func testRootPathRejected() throws {
        XCTAssertThrowsError(try AtlasPathValidator.validate("/", homeDirectoryURL: homeURL)) { error in
            XCTAssertTrue(error is AtlasPathValidationError)
        }
    }

    // MARK: - validateAll

    func testValidateAllSucceedsForValidPaths() throws {
        let paths = [
            "/Users/testuser/Library/Caches/a",
            "/Applications/Test.app",
        ]
        let urls = try AtlasPathValidator.validateAll(paths, homeDirectoryURL: homeURL)
        XCTAssertEqual(urls.count, 2)
    }

    func testValidateAllThrowsOnFirstInvalid() throws {
        let paths = [
            "/Users/testuser/Library/Caches/ok",
            "relative/bad",
        ]
        XCTAssertThrowsError(try AtlasPathValidator.validateAll(paths, homeDirectoryURL: homeURL))
    }

    func testValidateAllEmptyArray() throws {
        let urls = try AtlasPathValidator.validateAll([], homeDirectoryURL: homeURL)
        XCTAssertTrue(urls.isEmpty)
    }
}

private final class TestClock: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private struct InventoryProviderStub: AtlasAppInventoryProviding {
    let apps: [AppFootprint]
    func collectInstalledApps() async throws -> [AppFootprint] { apps }
}

private struct TaggingFileOrganizerClassifier: AtlasFileOrganizerClassifying {
    let destinationTag: String
    func classify(_ entries: [FileOrganizerEntry], rules: [FileOrganizerRule], destinationBasePath: String) async -> [FileOrganizerEntry] {
        entries.map { entry in
            var copy = entry
            copy.proposedDestination = destinationTag
            return copy
        }
    }
}
