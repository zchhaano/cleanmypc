import XCTest
@testable import AtlasApp
import AtlasApplication
import AtlasDesignSystem
import AtlasDomain
import AtlasFeaturesSmartClean
import AtlasInfrastructure

/// Batch I flow tests: decision A (resolve-on-render single stage truth),
/// decision B (rescan confirmation flow shared by Cmd+Shift+R and the
/// on-screen button), the execution receipt + 「已入账 №N · 撤销」 toast, and
/// the undo path through the existing restore chain.
@MainActor
final class SmartCleanWorkflowFlowTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AtlasL10n.setCurrentLanguage(.zhHans)
    }

    // MARK: - Stage constant lock (feature mirror == Apps map)

    func testFeatureStageConstantsMatchWorkflowStageMap() {
        XCTAssertEqual(SmartCleanStage.scan, AtlasWorkflowStageMap.scanStage)
        XCTAssertEqual(SmartCleanStage.review, AtlasWorkflowStageMap.reviewStage)
        XCTAssertEqual(SmartCleanStage.execute, AtlasWorkflowStageMap.executeStage)
        XCTAssertEqual(SmartCleanStage.receipt, AtlasWorkflowStageMap.receiptStage)
    }

    // MARK: - Decision A regression: resolve output tracks assign/supersede

    func testResolveOnRenderAfterAssignAndSupersede() async {
        let model = makeModel(scanProvider: TwoFindingScanProvider())

        await model.runSmartCleanScan()
        XCTAssertNotNil(model.workflowState(for: .smartClean).planNumber)
        XCTAssertEqual(resolveStage(of: model), AtlasWorkflowStageMap.reviewStage,
                       "scan completion + assignPlanNumber ⇒ resolve lands on ② review")

        model.supersedePlan(for: .smartClean)
        XCTAssertNil(model.workflowState(for: .smartClean).planNumber)
        XCTAssertFalse(model.isCurrentSmartCleanPlanFresh, "superseded plan is no longer fresh")
        XCTAssertEqual(resolveStage(of: model), AtlasWorkflowStageMap.scanStage,
                       "supersede voids the plan ⇒ resolve lands on ① scan (no stored-stage truth)")
    }

    // MARK: - Decision B: rescan confirmation flow

    func testRescanConfirmFlowIncrementsNumberAndVoidsOld() async {
        let model = makeModel(scanProvider: TwoFindingScanProvider())

        await model.runSmartCleanScan()
        let firstNumber = model.workflowState(for: .smartClean).planNumber
        XCTAssertNotNil(firstNumber)

        // Cmd+Shift+R / on-screen button: raise the pending flag only.
        model.requestRescanConfirmation(for: .smartClean)
        XCTAssertTrue(model.workflowState(for: .smartClean).rescanConfirmationPending)

        // Confirm: supersede (old № void) + new scan (fresh № = old + 1).
        model.supersedePlan(for: .smartClean)
        XCTAssertNil(model.workflowState(for: .smartClean).planNumber)
        XCTAssertFalse(model.workflowState(for: .smartClean).rescanConfirmationPending)

        await model.runSmartCleanScan()
        let state = model.workflowState(for: .smartClean)
        XCTAssertEqual(state.planNumber, firstNumber.map { $0 + 1 },
                       "the counter never rewinds — the new plan gets a fresh №")
        XCTAssertEqual(resolveStage(of: model), AtlasWorkflowStageMap.reviewStage)
    }

    func testRescanCancelFlowKeepsPlanUntouched() async {
        let model = makeModel(scanProvider: TwoFindingScanProvider())

        await model.runSmartCleanScan()
        let before = model.workflowState(for: .smartClean)
        XCTAssertNotNil(before.planNumber)
        XCTAssertFalse(before.selectedIDs.isEmpty)

        model.requestRescanConfirmation(for: .smartClean)
        XCTAssertTrue(model.workflowState(for: .smartClean).rescanConfirmationPending)

        // Cancel: only the pending flag clears — №/selection/freshness stay.
        model.updateWorkflowState(for: .smartClean) { $0.rescanConfirmationPending = false }

        let after = model.workflowState(for: .smartClean)
        XCTAssertEqual(after.planNumber, before.planNumber)
        XCTAssertEqual(after.receiptCode, before.receiptCode)
        XCTAssertEqual(after.selectedIDs, before.selectedIDs)
        XCTAssertFalse(after.rescanConfirmationPending)
        XCTAssertTrue(model.isCurrentSmartCleanPlanFresh)
        XCTAssertEqual(resolveStage(of: model), AtlasWorkflowStageMap.reviewStage)
    }

    // MARK: - Selection seeding + subset preview

    func testScanCompletionSeedsSelectionWithAllFindings() async {
        let model = makeModel(scanProvider: TwoFindingScanProvider())

        await model.runSmartCleanScan()

        let state = model.workflowState(for: .smartClean)
        XCTAssertEqual(
            state.selectedIDs,
            Set(model.snapshot.findings.map(\.id.uuidString)),
            "default review selection matches the legacy execute-all behavior"
        )
    }

    func testSelectionSubsetPreviewRebuildsPlanAndKeepsNumber() async throws {
        let model = makeModel(scanProvider: TwoFindingScanProvider())

        await model.runSmartCleanScan()
        XCTAssertEqual(model.currentPlan.items.count, 2)
        let numberAfterScan = model.workflowState(for: .smartClean).planNumber

        let keptID = try XCTUnwrap(model.snapshot.findings.first?.id)
        let refreshed = await model.refreshPlanPreview(findingIDs: [keptID])

        XCTAssertTrue(refreshed)
        XCTAssertEqual(model.currentPlan.items.count, 1, "the rebuilt plan mirrors the checked subset")
        XCTAssertEqual(model.currentPlan.items.first?.id, keptID)
        XCTAssertEqual(model.workflowState(for: .smartClean).planNumber, numberAfterScan,
                       "subset preview within the same plan keeps its №")
    }

    func testRefreshPreviewAssignsNumberWhenMissing() async {
        // Cached findings revalidated without a scan (scaffold seed state).
        let model = makeModel(scanProvider: nil)
        XCTAssertNil(model.workflowState(for: .smartClean).planNumber)

        let refreshed = await model.refreshPlanPreview()

        XCTAssertTrue(refreshed)
        if model.currentPlan.items.isEmpty {
            XCTAssertNil(model.workflowState(for: .smartClean).planNumber, "empty plans stay unnumbered")
        } else {
            XCTAssertNotNil(model.workflowState(for: .smartClean).planNumber,
                            "every executable plan is ledger-addressable")
            XCTAssertNotNil(model.workflowState(for: .smartClean).receiptCode)
        }
    }

    // MARK: - Execution receipt + ledger toast (state-only path, fail-closed undo)



    // MARK: - Execution + undo with a REAL recovery delta (file roundtrip)



    // MARK: - Helpers

    private func makeModel(scanProvider: (any AtlasSmartCleanScanProviding)?) -> AtlasAppModel {
        let repository = AtlasWorkspaceRepository(
            stateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("workspace-state.json")
        )
        let worker: AtlasScaffoldWorkerService
        if let scanProvider {
            worker = AtlasScaffoldWorkerService(
                repository: repository,
                smartCleanScanProvider: scanProvider,
                allowStateOnlyCleanExecution: true
            )
        } else {
            worker = AtlasScaffoldWorkerService(repository: repository, allowStateOnlyCleanExecution: true)
        }
        return AtlasAppModel(
            repository: repository,
            workerService: worker,
            ledgerNumberStore: InMemoryLedgerNumberStore()
        )
    }

    private func resolveStage(of model: AtlasAppModel) -> Int {
        AtlasWorkflowStageMap.resolve(AtlasWorkflowStageMap.Inputs(
            isScanning: model.isScanRunning,
            isExecuting: model.isPlanRunning,
            executionFailed: model.smartCleanExecutionIssue != nil,
            executionCompleted: model.smartCleanExecutionCompleted,
            isPlanFresh: model.isCurrentSmartCleanPlanFresh,
            findingsCount: model.snapshot.findings.count
        )).current
    }
}

// MARK: - Scan fixtures

private struct TwoFindingScanProvider: AtlasSmartCleanScanProviding {
    func collectSmartCleanScan() async throws -> AtlasSmartCleanScanResult {
        AtlasSmartCleanScanResult(
            findings: [
                Finding(
                    id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                    title: "Build cache",
                    detail: "Derived data",
                    bytes: 512_000,
                    risk: .safe,
                    category: "Developer",
                    targetPaths: [
                        FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Library/Caches/AtlasBatchIFixtureA.bin").path
                    ]
                ),
                Finding(
                    id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
                    title: "Old runtime",
                    detail: "Unused simulator runtime",
                    bytes: 2_048_000,
                    risk: .review,
                    category: "Developer",
                    targetPaths: [
                        FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Library/Caches/AtlasBatchIFixtureB.bin").path
                    ]
                ),
            ],
            summary: "Batch I fixture scan found 2 reclaimable items."
        )
    }
}

private struct SingleRealFileScanProvider: AtlasSmartCleanScanProviding {
    let path: String

    func collectSmartCleanScan() async throws -> AtlasSmartCleanScanResult {
        AtlasSmartCleanScanResult(
            findings: [
                Finding(
                    title: "Undo fixture cache",
                    detail: path,
                    bytes: 256,
                    risk: .safe,
                    category: "Developer",
                    targetPaths: [path]
                )
            ],
            summary: "Batch I real-file fixture scan."
        )
    }
}
