# Native File Safety and Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 防止原生整理破坏文件包，使每个已发生的文件变更有证据，恢复成功不依赖同名猜测。

**Architecture:** Domain 保存可编码的操作事实，新增 FileSafety 模块负责类型化范围和文件对象，Infrastructure 负责计划、日志、执行租约及状态投影。现有 Worker 做协调，不继续承载所有文件/持久化细节。

**Tech Stack:** macOS 14+、Swift tools 5.10 / Xcode Swift 6.0、Foundation、Darwin、CryptoKit、XCTest/XCUITest。

**Spec:** [改进方案 §3、5～7、9](../design/2026-10-01-security-hardening.md)；[总计划](2026-10-01-security-hardening.md)。

## Global Constraints

- Helper 保持普通用户权限；不新增第三方依赖。
- 一次扫描最多 100,000 候选，一次变更批次最多 1,000 个选中项；超限拒绝，不静默截断或自动分批。
- 同一工作区同时只有一个变更批次；执行、恢复、迁移和记录清理共用跨进程锁。
- 原生最低版本保持 macOS 14；SPM 保持 Swift tools 5.10，Xcode 保持 Swift 6.0。
- 生产测试不修改真实 PAM、路由、蓝牙、用户废纸篓或服务；文件测试用隔离目录和可注入的 mover/journal，故障注入只在测试构建开放。
- 不能把 Finder Trash 与日志描绘成一个原子事务；结果未知进入 `reconciliationRequired`。

## Review Focus

1. 用户直接选择包内部目录或伪造旧执行请求：N1/N2 拒绝，完整包保持原状。
2. 同一 Finding 第二个文件失败：N3/N4 保留第一个成功记录，不继续操作第三个文件。
3. 日志满、尾记录截断、未来版本状态：N4 保留原始文件并进入只读/核对模式。
4. 两 Worker、取消、重试、重复选择：N2/N4 保证选中集准确且不重复执行。
5. Finder 清空后出现同名新文件：N5/N6 显示来源丢失，不计成功，不覆盖新文件。

## N1：共同文件策略与包保护

**Files — Create:**

- `Packages/AtlasDomain/Sources/AtlasDomain/AtlasFileOperation.swift`：操作种类、文件身份和意图。
- `Packages/AtlasFileSafety/Sources/AtlasFileSafety/AtlasFileSafetyPolicy.swift`：按动作限域。
- `Packages/AtlasFileSafety/Sources/AtlasFileSafety/AtlasFileIdentityReader.swift`：no-follow 身份/包/文件类型检查。
- `Packages/AtlasFileSafety/Sources/AtlasFileSafety/AtlasFileMover.swift`：整理/普通恢复的描述符移动，目标不可覆盖。
- `Packages/AtlasFileSafety/Tests/AtlasFileSafetyTests/AtlasFileSafetyTests.swift`。

**Modify:** `Packages/Package.swift`、`Helpers/Package.swift`、`Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasPathValidator.swift`、`AtlasSmartCleanExecutionSupport.swift`、`AtlasScaffoldWorkerService.swift`（后三者同目录）、`Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/AtlasFileOrganizerScanner.swift`、`Helpers/AtlasPrivilegedHelper/Sources/AtlasPrivilegedHelperCore/HelperActionExecutor.swift`。

**Test:** `Packages/AtlasCoreAdapters/Tests/AtlasCoreAdaptersTests/AtlasFileOrganizerScannerTests.swift`、`Packages/AtlasInfrastructure/Tests/AtlasInfrastructureTests/AtlasSmartCleanExecutionSupportTests.swift`、`Helpers/AtlasPrivilegedHelper/Tests/AtlasPrivilegedHelperTests/AtlasPrivilegedHelperTests.swift`，以及新增 FileSafetyTests。

**Interfaces:**

- Domain：`AtlasFileIdentity: Codable, Hashable, Sendable`，字段 `device: UInt64`、`inode: UInt64`、`birthTimeNanoseconds: Int64`、`kind: AtlasFileKind`；`AtlasFileKind` 为 `regularFile|directory|package`，其他对象拒绝。
- `AtlasFileOperationKind` 为 `smartClean|organize|uninstall|restore`；`AtlasFileOperationIntent` 含 `entryID: UUID`、`kind`、`sourcePath: String`、`destinationPath: String?`、`expectedIdentity: AtlasFileIdentity`。
- Safety：`AtlasFileSafetyPolicy.validate(_ intent: AtlasFileOperationIntent, context: AtlasFilePolicyContext) throws -> AtlasValidatedFileOperation`；`validateOrganizerRoot(_ url: URL) throws -> URL`；`AtlasFileMover.moveWithoutReplacing(_ operation: AtlasValidatedFileOperation) throws -> AtlasFileIdentity`。
- `AtlasFilePolicyContext` 从本机账户、用户已选整理根、Worker 应用清单和本地恢复记录建立；不是由请求方自由指定的 allowlist。`AtlasValidatedFileOperation` 构造不公开，持有已核对源/目的父目录及身份，执行后关闭句柄；不把“验证过”对象编码发给另一个进程继续信任。
- 新增 `AtlasFileSafety` library/test target；Infrastructure、CoreAdapters、HelperCore 显式依赖它，Domain 不依赖 Safety。如果变更 `project.yml`，同任务运行 `xcodegen generate`。

- [ ] **写回归。** 临时 `.app/Contents/MacOS`、`.photoslibrary`、`.pages`、大小写扩展名、无扩展名但有包元数据；递归扫描只输出普通兄弟文件。直接选包内部、`/Applications`、`~/Library`、主目录本身拒绝。伪造执行项、cache 名称相似路径、目标父链接、已选对象身份变化、目标重名均拒绝且哨兵完整；合法用户文件整理、精确缓存项、完整选中第三方应用分别有正向用例。
- [ ] **验红。** `swift test --package-path Packages --filter AtlasFileOrganizerScannerTests`、`swift test --package-path Packages --filter AtlasSmartCleanExecutionSupportTests`；先用现有 scanner/worker 触发包内部与宽泛路径失败，不能只因新模块不存在算行为复现。
- [ ] **实现共同策略。** 按 spec 动作表收窄执行端；扫描器增加 `.skipsPackageDescendants`、包属性和来源祖先检查，目的地嵌入来源根则拒绝。未知元数据和枚举失败显式报告；取消宽泛默认 roots 和 `contains`。禁用 Helper `removeLaunchService/repairOwnership`。普通移动通过父描述符 no-follow、身份重核及原子 no-replace rename；跨卷拒绝，不隐式 copy+delete。Finder Trash 保持独立适配器并记录残余窗口。
- [ ] **验证。** `swift test --package-path Packages --filter AtlasFileSafetyTests`、上述两组测试及 `swift test --package-path Helpers` 全通过；确定性路径替换 hook 下保护对象和未选项不变。扫描和执行测试分别覆盖，不能以 scanner 已过滤替代 Helper 拒绝测试。
- [ ] **审查并提交。** 列出清理/卸载范围缩小的实际影响，确认缺安全证据的操作不回退到旧 validator；记录在 evidence，独立提交 N1。

## N2：计划身份、选择和规模约束

依赖 N1。

**Files — Create:** `Packages/AtlasDomain/Sources/AtlasDomain/AtlasExecutionSelection.swift`、`Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasActionPlanRegistry.swift`、`Packages/AtlasInfrastructure/Tests/AtlasInfrastructureTests/AtlasActionPlanRegistryTests.swift`。

**Modify:** `Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasScaffoldWorkerService.swift`、`Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/AtlasFileOrganizerScanner.swift`、`Packages/AtlasProtocol/Sources/AtlasProtocol/AtlasProtocol.swift`、`Packages/AtlasApplication/Sources/AtlasApplication/AtlasApplication.swift`、`Apps/AtlasApp/Sources/AtlasApp/AtlasAppModel.swift`、对应 scanner/protocol/app model 测试。

**Interfaces:**

- Domain：`AtlasExecutionSelection` 含 `planID: UUID`、`planDigest: String`、`selectedEntryIDs: [UUID]`；`AtlasRegisteredPlan` 含 `plan: ActionPlan`、`policyRevision: Int`、`digest: String`、`operations: [AtlasFileOperationIntent]`。
- Registry：`register(plan: ActionPlan, operations: [AtlasFileOperationIntent], policyRevision: Int) throws -> AtlasRegisteredPlan`；`resolve(_ selection: AtlasExecutionSelection) throws -> [AtlasFileOperationIntent]`。初版内存保存，N4 负责持久化与加载。
- Protocol 升至 `0.4.0`；计划响应改为 `.preview(AtlasRegisteredPlan)` / `.fileOrganizerPlan(AtlasRegisteredPlan)`；变更命令改为 `.executePlan(selection: AtlasExecutionSelection)`、`.fileOrganizerExecutePlan(selection: AtlasExecutionSelection)`、`.executeAppUninstall(appID: UUID, selection: AtlasExecutionSelection)`，移除卸载可空 planID 回退。AppModel 保存返回的摘要与选择；旧协议写请求失败并要求更新/重新扫描，不能退回无摘要执行。
- `policyRevision=1`；SHA-256 用版本化规范编码，按 entryID 排序，每个字符串 UTF-8 长度前缀，固定整数编码，保留实际文件名，不做可能合并不同文件的 Unicode 归一化。摘要包括全部操作与身份。

- [ ] **写回归。** `testPlanAccepts65536EntriesWithoutTrap`、`testDigestChangesForPathDestinationIdentityOrPolicy`、`testSelectionRejectsUnknownDuplicateEmptyAndStaleIDs`、`testExecutionRejects1001Selections`；内存构造 65,535/65,536/100,000 项。scanner 测试注入上限 3，第四项出现返回超限且无可执行计划；默认常量另断言等于 100,000。字节总量溢出必须报错。
- [ ] **验红。** `swift test --package-path Packages --filter AtlasActionPlanRegistryTests` 与 scanner 测试；计数 trap 在隔离测试子进程复现或静态确认旧转换，不能为验红直接让正在使用的 App 崩溃。
- [ ] **实现计划与限制。** 移除 UInt16/XOR 身份逻辑，保留 UUID；执行请求只携带注册计划引用和选中项，服务端加载实际路径。扫描超过 100,000 全次失败；1,001 选择拒绝且零移动；同一计划重复扫描/排序不扩大选择；每次执行重新调用 N1 策略。
- [ ] **验证。** 上述测试与 `swift test --package-path Packages --filter AtlasProtocolTests` 全通过；添加更改请求路径但不更改服务端记录的用例，证明无法替换执行目标；旧协议缺摘要拒绝变更并要求重新扫描。
- [ ] **审查并提交。** 同步应用调用接口以编译通过；此任务尚不实现跨重启计划复用，重启后要求重扫，直至 N4 落盘实现完成。

## N3：立即保留部分成功，传播持久化错误

可与 N1/N2 分开实现；最终接入 N4。若 P0 独立发版，在此任务把原生变更入口默认关闭，N4～N6/R2 验收后才解除。

**Files — Modify:** `Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasScaffoldWorkerService.swift`、`Packages/AtlasDomain/Sources/AtlasDomain/AtlasActionOutcome.swift`、`Packages/AtlasInfrastructure/Tests/AtlasInfrastructureTests/AtlasInfrastructureTests.swift`。

**Create Test:** `Packages/AtlasInfrastructure/Tests/AtlasInfrastructureTests/AtlasPartialMutationTests.swift`。

**Interfaces:** `persistState() throws` 取代吞错；现有 Smart Clean 结果按每个成功路径立即追加 mapping，捕获错误时保留 accumulated result。执行响应增加显式“部分完成/状态保存失败”而不改变成功为 false 后丢弃事实；N4 再将持久证据统一到 journal。

- [ ] **写回归。** 同一 Finding 路径 A/B/C，模拟 A 成功 B 失败，断言 A 的原路径/实际 Trash 路径保留、B 有错误、C 未调用、整体为部分完成；快照保存失败不返回全部成功。临时保守恢复规则：source 不存在且 target 存在不计成功，保留恢复项。
- [ ] **验红。** `swift test --package-path Packages --filter AtlasPartialMutationTests`，确认当前实现丢失 A mapping、吞掉保存失败或同名误判导致失败。
- [ ] **实施。** 将 mapping 追加从 Finding 末尾移至单文件成功点；每次成功将已累计恢复项投影到现有快照并尝试保存，再允许下一项执行；错误向上返回包含已完成记录的结果，持久化失败停止后续变更。禁止以空映射推断“没有发生操作”。在 Worker 增加编译时安全能力开关默认关闭批量写入，测试依赖注入才能验证未开放代码；不允许用户环境变量开启。
- [ ] **验证。** 上述测试与 `swift test --package-path Packages --filter AtlasInfrastructureTests` 全通过；明确测试仍不能证明崩溃前映射已持久化。生产 Worker 直接接收变更请求也被关闭，不仅是 UI 按钮。
- [ ] **审查并提交。** evidence 标为“已减少即时丢失，跨崩溃闭环等待 N4”，不可据此声称 SEC-04 完整关闭。

## N4：逐文件日志、变更租约和状态迁移

依赖 N1/N2/N3；本任务可拆成日志存储、执行接入两次提交，接口不变。

**Files — Create:**

- `Packages/AtlasDomain/Sources/AtlasDomain/AtlasOperationRecord.swift`：状态与证据。
- `Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasOperationJournal.swift`：记录帧、同步及重放。
- `Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasMutationCoordinator.swift`：进程内租约和跨进程文件锁。
- `Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasJournalReconciler.swift`：启动核对与快照投影。
- `Packages/AtlasInfrastructure/Tests/AtlasInfrastructureTests/AtlasOperationJournalTests.swift`、`AtlasMutationCoordinatorTests.swift`、`AtlasRecoveryCrashTests.swift`（同测试目录）。

**Modify:** `Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasScaffoldWorkerService.swift`、`AtlasWorkspaceRepository.swift`、`AtlasActionPlanRegistry.swift`（同目录）；`Packages/AtlasApplication/Sources/AtlasApplication/AtlasApplication.swift`、`Packages/AtlasDomain/Sources/AtlasDomain/AtlasDomain.swift`、`Packages/AtlasProtocol/Sources/AtlasProtocol/AtlasProtocol.swift`、已有 repository/protocol 测试。

**Interfaces:**

- `AtlasOperationState`：`planned|moved|restorePlanned|restored|failed|reconciliationRequired`；`AtlasOperationRecord` 字段严格采用 spec §7.1，包括 `operationID: UUID`、`requestID: UUID`、`planID: UUID`、`planDigest: String`、`entryID: UUID`、`findingID: UUID?`、文件路径/身份、`state`、错误与序号。
- `AtlasOperationJournal.append(_ record: AtlasOperationRecord) throws`：返回前完成记录及同步；`replay() throws -> [AtlasOperationRecord]`：验证版本、序号、校验及状态转换，按帧流式读入；坏尾不直接忽略。
- `AtlasMutationCoordinator.withLease<T: Sendable>(_ body: @Sendable (AtlasMutationLease) async throws -> T) async throws -> T`；已有租约即 `busy`，文件锁获取采用非阻塞 flock；lease 不可编码，不可由调用者构造。
- `AtlasRequestStatus` 包含 requestID、执行状态与逐项结果；Worker `status(requestID: UUID) async throws -> AtlasRequestStatus`；Protocol 新增对应查询请求/响应，R2 使用它。
- Repository `loadState() throws -> AtlasWorkspaceState`；缺文件初始化空的生产状态，损坏/未来版本抛错并保留原文件，测试示例种子仅由 fixture 注入。旧调用方需要显式处理只读状态。
- Workspace schema 2；RecoveryPathMapping 新增可选 operationID/sourceIdentity/trashedIdentity；Recovery payload schema 同步升版并保持旧版解码。journalVersion 固定 1；字段缺失只能标为旧证据，不凭空补出 restored。

- [ ] **写日志与迁移回归。** 计划保存失败→零文件操作；追加 planned 失败→零移动；移动后追加失败→C 不动、A/B 未知项仍可见；尾截断/校验坏/未来 schema→原始字节不变且禁止写入；schema 1 迁移保留映射与备份；旧示例状态不覆盖损坏文件。日志目录/文件权限断言 0700/0600，链接路径拒绝。
- [ ] **验红。** `swift test --package-path Packages --filter AtlasOperationJournalTests`、`swift test --package-path Packages --filter AtlasWorkspaceRepositoryTests`。错误注入由测试存储适配器提供，不在生产开放“忽略 fsync”开关。
- [ ] **实现存储。** 相同工作区内先锁再加载/迁移；journal 每记录完整写入并同步，处理 EINTR/短写；计划与选择也必须在首条文件操作前落盘。快照作为可重建投影，保存失败不丢 journal。原来的到期过滤改为保留未核对/失败证据，正常已完成历史可归档但不删除实际文件。
- [ ] **写执行并发与崩溃回归。** 两 Worker 指向同一临时 stateDir、重复 requestID 同内容/异内容、actor await 重入、取消后下一文件不启动；测试子进程在 planned 后、move 后未写 moved、moved 后未保存 snapshot、restore 后未写 restored 处退出，重启核对。断言最多一次文件操作；move/log 间断开只能需核对，不猜成功。
- [ ] **实施并验证协调。** 租约覆盖整个批次，Helper 每次调用前写 planned，返回时验证响应身份并写 moved；相同 requestID 去重、异内容拒绝。运行 `swift test --package-path Packages --filter AtlasMutationCoordinatorTests`、`swift test --package-path Packages --filter AtlasRecoveryCrashTests` 和前述日志/仓库测试全部通过；重启扫描不得按名称自动认领 Trash 文件。
- [ ] **审查并提交。** 更新 ADR-007/008 的迁移与保留语义，记录 journal/快照非原子限制。仍等 N5/N6/R2 验收后再打开 N3 的生产能力；此任务本身不等于恢复闭环已发布。

## N5：可证明的恢复与来源丢失处理

依赖 N4。

**Files — Create:** `Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasRecoveryExecutor.swift`、`Packages/AtlasInfrastructure/Tests/AtlasInfrastructureTests/AtlasRecoveryExecutorTests.swift`。

**Modify:** `Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasScaffoldWorkerService.swift`、`Packages/AtlasDomain/Sources/AtlasDomain/AtlasOperationRecord.swift`、`Packages/AtlasDomain/Sources/AtlasDomain/AtlasDomain.swift`、既有恢复测试。

**Interfaces:** `AtlasRecoveryExecutor.restore(operationID: UUID, requestID: UUID) async throws -> AtlasRestoreResult`；`AtlasRestoreResult` 状态 `restored|alreadyRestored|sourceMissing|targetConflict|reconciliationRequired|rejected`，包含 operationID 和证据路径。依赖 N4 journal/coordinator、N1 policy/mover；不接受外部任意 source/destination。

- [ ] **写回归。** 按 spec §7.3 的来源/目标矩阵全覆盖；source 缺失+target 同名新内容→sourceMissing，target 字节不变且成功数 0；两端存在→conflict；只有已保存 restored 凭据且身份一致→alreadyRestored；旧映射 source 存在且无冲突经策略可恢复，缺凭据不支持同名幂等。
- [ ] **验红。** `swift test --package-path Packages --filter AtlasRecoveryExecutorTests`，旧恢复实现的同名分支须在回归中失败。
- [ ] **实现恢复协调。** 写 restorePlanned 后执行无覆盖移动、核验目标身份、写 restored；每一步失败保留证据。使用统一规范路径策略替换原始 home 前缀判断；恢复项仅在结果有据时归档，不在失败时移除。跨卷/身份不明拒绝自动恢复，输出核对说明。
- [ ] **验证。** 上述测试与 `swift test --package-path Packages --filter AtlasRecoveryCrashTests` 全通过；增加目标父链接替换、恢复途中取消、重复恢复请求，确认没有覆盖和重复计数。
- [ ] **审查并提交。** audit/evidence 中分别记录 restored 与 alreadyRestored；旧 schema 兼容恢复不标成和新日志同等级的证据。

## N6：真实的部分结果、恢复状态与 UI 验收

依赖 N5；R2 完成后才在生产重开受限变更。

**Files — Modify:** `Apps/AtlasApp/Sources/AtlasApp/AtlasAppModel.swift`、`AtlasWorkflowViewState.swift`、`TaskCenterView.swift`（后二者同 App 目录）、`Packages/AtlasFeaturesSmartClean/Sources/AtlasFeaturesSmartClean/SmartCleanReceiptView.swift`、`Packages/AtlasFeaturesHistory/Sources/AtlasFeaturesHistory/LedgerDetailView.swift`、`LedgerRecoveryHelpers.swift`（同 History 目录）、`Packages/AtlasFeaturesFileOrganizer/Sources/AtlasFeaturesFileOrganizer/FileOrganizerStageViews.swift`、`Packages/AtlasDomain/Sources/AtlasDomain/Resources/{en,zh-Hans}.lproj/Localizable.strings`。

**Test:** `Apps/AtlasApp/Tests/AtlasAppTests/AtlasAppModelTests.swift`、`SmartCleanWorkflowFlowTests.swift`（同目录）、`Apps/AtlasAppUITests/AtlasAppUITests.swift`、`Packages/AtlasFeaturesHistory/Tests/AtlasFeaturesHistoryTests/LedgerModelTests.swift`。

**Interfaces:** AppModel 根据 N4/N5 的真实逐项结果生成展示状态，沿用 AtlasL10n；UI fixture 通过现有 `ATLAS_UI_TEST_FIXTURE` 命名路由注入 `partialMutation`、`reconciliationRequired`、`recoverySourceMissing`，只对隔离 fixture 存储生效。

- [ ] **写回归。** Model 与真实 UI 各覆盖五态“已完成/部分完成/未执行/需要核对/来源已丢失”；A 成功 B 失败显示成功 1 且保留 B；需核对时禁止重复执行；原始源缺失仍保留证据和定位说明；1001 选择禁用执行并有原因；记录期限文案不承诺 Trash 文件保留。
- [ ] **验红。** `swift test --package-path Apps --filter AtlasAppModelTests` 和 `swift test --package-path Apps --filter SmartCleanWorkflowFlowTests`；UI 用 `./scripts/atlas/run-ui-automation.sh`，确认新增断言真实执行，NOT_RUN/ZERO_TESTS 不能算验红或通过。
- [ ] **实现可见状态。** 保留部分成功的定位/恢复入口，错误项不被整体成功覆盖；未知状态不能显示“没有发生更改”。两份文案同改，纯英文底层错误不直接作为用户主文案；受限清理范围在预览体现。N4/N5/R2 通过后才解除 N3 的编译时写关闭。
- [ ] **验证内容与渲染。** `swift test --package-path Apps`、`swift test --package-path Packages --filter LedgerModelTests`；`./scripts/atlas/copy-gate.sh`；`./scripts/atlas/export-readme-assets.sh` 后 `./scripts/atlas/readme-media-gate.sh`；实际 `./scripts/atlas/run-ui-automation.sh` 有非零用例且全部通过。本地不设 `ATLAS_ALLOW_UI_SKIP=1`；不修改门禁规则就不用额外跑媒体变异自检。
- [ ] **审查并提交。** 记录真实 UI 测试数量和截图更新，检查新错误不泄露私有完整路径到对外日志；以用户可理解的范围说明更新发布说明，不声称保证所有崩溃可自动恢复。
