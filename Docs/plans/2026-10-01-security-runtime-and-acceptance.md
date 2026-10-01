# Runtime Safety and Release Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让进程/XPC 在异常下有界完成，并用真实执行的门禁验证安全改造进入发行产物。

**Architecture:** 一个共享进程执行器负责进程及管道生命周期；XPC 自己管理至多一次完成和读取重试；安全门禁覆盖根脚本、内嵌副本、Swift/Go/Shell 及发布产物。

**Tech Stack:** Swift/Foundation/Darwin、XCTest/XCUITest、Go、Bats、GitHub Actions、macOS 测试 VM。

**Spec:** [改进方案 §8～10](../design/2026-10-01-security-hardening.md)；[总计划](2026-10-01-security-hardening.md)。

## Global Constraints

- 原生最低版本保持 macOS 14；SPM 保持 Swift tools 5.10，Xcode 保持 Swift 6.0；Go 保持 `go.mod` 的 1.25.0，不新增第三方依赖。
- Helper/Health/Smart Clean 超时分别为 30/15/120 秒，TERM 宽限 1 秒，stdout/stderr 上限为 8/1 MiB。
- Helper 保持普通用户权限；不扩大为全局 Mach/root 服务。
- 生产测试不修改真实 PAM、路由、蓝牙、用户废纸篓或服务；真实系统操作只在可回滚的测试虚拟机执行。
- `swift test` 不覆盖 XCUITest；UI ZERO_TESTS 不可豁免，本地/候选机不设 `ATLAS_ALLOW_UI_SKIP=1`。

## Review Focus

1. 子进程不读 stdin、同时大量写两路输出：R1 不死锁，超限失败且缓冲有界。
2. 进程忽略 TERM、后代继续持有管道：R1 只结束本次进程组，能返回且不等待无限 EOF。
3. 退出/取消/超时/迟到 XPC 回复同时到达：R1/R2 一次完成，不 double resume。
4. 请求已经执行但回复丢失：R2 不重发变更，查询 N4 原 requestID 的事实。
5. CI 早期步骤失败、零测试、漏打包或脚本副本漂移：R3/R4 必须验红并记录实际执行到达门禁的证据。

## R1：共用的有界子进程执行器

**Files — Create:** `Packages/AtlasProcessSupport/Sources/AtlasProcessSupport/AtlasProcessRunner.swift`、`AtlasProcessTypes.swift`（同目录）、`Packages/AtlasProcessSupport/Tests/AtlasProcessSupportTests/AtlasProcessRunnerTests.swift`。

**Modify:** `Packages/Package.swift`、`Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasPrivilegedHelperClient.swift`、`Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/MoleHealthAdapter.swift`、`MoleSmartCleanAdapter.swift`（同目录）、`Packages/AtlasInfrastructure/Tests/AtlasInfrastructureTests/AtlasHelperClientTests.swift`。

**Interfaces:**

- 新增 `AtlasProcessSupport` library/test target，无业务层依赖，Infrastructure/CoreAdapters 显式依赖。
- `AtlasProcessRequest: Sendable` 字段 `executableURL: URL`、`arguments: [String]`、`environment: [String: String]`、`stdin: Data`、`timeout: Duration`、`terminationGrace: Duration`、`stdoutLimit: Int`、`stderrLimit: Int`。
- `AtlasProcessResult: Sendable` 字段 `exitStatus: Int32`、`stdout: Data`、`stderr: Data`；`AtlasProcessRunning.run(_ request: AtlasProcessRequest) async throws -> AtlasProcessResult`，默认实现 `AtlasProcessRunner`。
- 类型化错误区分启动失败、超时、取消、输出超限、I/O 失败；非零正常退出通过 exitStatus 交调用方解释。超时/输出上限不得返回成功解析用的截断 JSON。

- [ ] **写回归。** 测试脚本仅创建临时文件/测试子进程：瞬时退出、无输出 sleep、不读 stdin、大于 pipe 容量但低于上限的双路输出、stdout 8 MiB+1、stderr 1 MiB+1、忽略 TERM、子进程持有管道。覆盖启动前取消、stdin 写入中取消、退出与超时竞争；记录父/子 PID 并确认旁边无关测试进程未被停止。
- [ ] **验红。** `swift test --package-path Packages --filter AtlasHelperClientTests` 的超时回归先对现 client 失败；新 runner 测试通过独立 watchdog 避免测试自身无限挂起。测试使用可注入时钟作确定性竞态断言，另保留真实 0.1 秒超时 / 0.05 秒宽限 / 2 秒外层上界的集成用例。
- [ ] **实现执行器。** 启动前注册所有退出/读写事件；持续消费两路管道、异步写输入；基于单调时钟统一 deadline 和一次完成状态。使用 Darwin `posix_spawn` 建本次独有进程组，关闭不继承的 fd；TERM 后 1 秒 KILL，只作用于自己创建的组。父退出后管道未关闭仍受 deadline 约束，清理事件监听与 fd；不能通过不受控后台 Task 遗留无限等待。
- [ ] **接入并验证。** Helper 30 秒、Health 15 秒、scan 120 秒；共享 8/1 MiB 限制和 1 秒宽限。Health 调用链改 async，取消各自的 waitUntilExit/退出后 readToEnd 和任务组超时。`swift test --package-path Packages --filter AtlasProcessRunnerTests`、Helper tests 和 CoreAdapters tests 全通过；输出超限/超时有单独可见错误，不当作空扫描成功。
- [ ] **审查并提交。** 检查取消后进程所有权与 fd 回收、SIGPIPE/EINTR、退出码解码及 Swift 6 Sendable；记录逃离进程组的后代限制，不声称能终止任意进程树。

## R2：XPC 一次完成、变更去重和 Helper 证据

超时/重试部分依赖 R1 的完成模式但不使用进程执行器；状态查询依赖 N4，Helper 文件限制依赖 N1/N2。

**Files — Create:** `Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasXPCRequestCompletion.swift`。

**Modify:** `Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasXPCTransport.swift`、`AtlasPrivilegedHelperClient.swift`（同目录）、`Packages/AtlasProtocol/Sources/AtlasProtocol/AtlasProtocol.swift`、`Helpers/AtlasPrivilegedHelper/Sources/AtlasPrivilegedHelperCore/HelperActionExecutor.swift`、`Packages/AtlasInfrastructure/Tests/AtlasInfrastructureTests/AtlasXPCTransportTests.swift`、`AtlasHelperClientTests.swift`（同目录）、protocol/helper 测试。

**Interfaces:**

- `AtlasXPCRequestCompletion.finish(_ result: Result<Data, Error>) -> Bool`：仅第一次 true；原子状态同时处理取消、连接错误、超时和 reply。实例每请求创建，完成后释放 callback/计时器引用。
- `AtlasCommand.isReadOnlyForRetry: Bool` 明确 allowlist：healthSnapshot、inspectPermissions、appsList、settingsGet、N4 新增 requestStatus；其他命令默认 false，新增命令不能自动获重试权限。
- 使用现有 request envelope 的 UUID，重试读取保持同 ID；变更失败返回结果未知及 requestID，随后只调用 N4 `status(requestID:)`。
- `AtlasHelperAction` 新增 `operationID: UUID?`、`planID: UUID?`、`planDigest: String?`、`policyRevision: Int?`、`expectedIdentity: AtlasFileIdentity?`；旧 JSON 可解码但缺证据的变更拒绝。响应必须匹配原 action.id、operationID、路径与动作；不接受另一个操作的成功回复。

- [ ] **写回归。** XPC 永不回复、reply 与 error 各先到一次、超时后迟到 reply、取消时 connection invalidated；continuation 只完成一次且引用释放。executePlan/restoreItems/settingsSet 发送计数为 1；丢失回复后查询状态不重复移动；只读请求按现有有限重试预算执行。新增未知 command 默认不重试。
- [ ] **验红。** `swift test --package-path Packages --filter AtlasXPCTransportTests`，使用可取消 callback transport 测试替身，不制造永不释放的 async continuation；当前任务组超时/全请求重试逻辑应不通过。
- [ ] **实现请求状态机。** 去掉依赖任务组退出的超时等待；finish 后释放/失效本次连接状态，迟到事件忽略；取消时不再睡眠重试。副作用不明确的请求一律不重试；requestStatus 对 unknown 继续显示需核对，不能生成新 requestID 自动再执行。
- [ ] **加固 Helper 并验证。** 在 N4 租约内写 planned 后传递证据；Helper 重跑 N1 策略、核验当前身份及本地可信计划/恢复记录，再进行受限动作。Release 仅解析 bundle 内候选路径，环境覆盖限 Debug；测试仍可通过构造器显式注入假 helper。用匹配/不匹配 operationID、路径改写、缺字段、removeLaunchService/repairOwnership 请求覆盖拒绝。`swift test --package-path Packages --filter AtlasXPCTransportTests`、Helper client/protocol tests、`swift test --package-path Helpers` 全通过。
- [ ] **审查并提交。** 普通 Helper 的本地证据验证不得为了读取日志再次争用 Worker 已持有的排他锁；通过只读已落盘不可变计划记录/单次请求证据读取完成，不能引入自死锁。记录 XPC timeout 不是服务端取消保证，独立提交。

## R3：安全回归门禁与 CI 实际覆盖

完整范围依赖 C1/C3/N6/R2。若单独发布 P0，先接入当时已实施任务的回归及“其他能力保持关闭”断言，随后随每项实现扩展清单；不可把尚未实现任务的用例记为通过。已有危险能力关闭和对应测试在此前各任务中就必须生效，不等待最终 CI 接线。

**Files — Create:** `scripts/atlas/security-regression.sh`、`scripts/atlas/security-gate-selftest.sh`、`Docs/security/security-regression-cases.md`。

**Modify:** `scripts/atlas/full-acceptance.sh`、`.github/workflows/atlas-acceptance.yml`、`.github/workflows/release.yml`、`scripts/test.sh`（补齐必要依赖缺失时的明确结果）、C1 evidence 文档。

**Interfaces:** `security-regression.sh --component shell|swift|go|all`；默认 all。只有组件非零测试且通过才输出 `ATLAS_SECURITY_GATE=PASS component=... tests=...`；缺依赖/零测试/未执行输出 `ATLAS_SECURITY_GATE=NOT_RUN` 并非零退出；失败输出 FAIL。脚本不执行真实 sudo 或安装。

- [ ] **写门禁自检。** 临时仓库副本中注入 runtime 漂移、新测试失败、缺 bats、Swift filter 零用例、Go 包无测试、某前序组件失败；每种均非零，不发全局 PASS。成功 fixture 返回实际计数。运行 `./scripts/atlas/security-gate-selftest.sh` 初始应缺门禁或不能正确验红。
- [ ] **实现门禁。** 用清单固定 SEC 用例集和命令，调用 C1 `--check`；Bats TAP、Swift XCTest 和 Go JSON 测试输出分别统计实际用例数，未适配输出格式时失败而非猜通过。既有 full acceptance 已运行的完整 Swift 套件可复用其明确日志/计数，不无条件重复跑所有测试；安全子集本地可单独运行。
- [ ] **核对 workflow 实际历史后接线。** 在实施时执行 `gh run list --workflow atlas-acceptance.yml --limit 20` 与 `gh run list --workflow release.yml --limit 10`，记录观察结果及实际到达步骤；无访问权限则记录未核实，不能说 CI 已保护。workflow paths 增加 `bin/**`、`lib/**`、`tests/**`、`cmd/**`、`internal/**`、`go.mod`、`go.sum`、`Makefile`、`install.sh` 和安全清单；新门禁在 acceptance 与对应 CLI/native release 构建产物之前运行。安装 Go/Bats/shellcheck 等必要依赖，缺失硬失败。
- [ ] **验证门禁而不修改真实工作树。** `./scripts/atlas/security-gate-selftest.sh` 全部变异验红；`./scripts/atlas/security-regression.sh --component all` 所有组件非零用例通过；full acceptance 仍保留 UI 三种零覆盖判据。仅在真的改了媒体门禁规则时追加 `./scripts/atlas/readme-media-gate-selftest.sh`。
- [ ] **审查并提交。** 更新 acceptance 步骤计数与相关说明，保留 CI 环境豁免仅适用于 AX/双 timeout 的规则；将“GitHub runner 必然没 AX”改为以实测为准。记录新 workflow 首次实际跑到门禁及变异自检的 run URL；接线完成但未运行时标记 pending。

## R4：测试 VM 与候选版本发布验收

完整功能候选依赖全部代码任务；P0 候选只验收已实施范围，未实施能力必须实测关闭并在表中标明。此任务是验收与功能开关重开，不自动授权真实发布。

**Files — Create:** `Docs/security/2026-10-01-release-acceptance.md`；在需要真实挂载测试时新增 `scripts/atlas/verify-filesystem-vm.sh`，与 C2 VM 脚本使用同样的只读默认/显式执行保护。

**Modify:** evidence 文档、C2/C3/N3 对应的编译时能力开关、`Docs/Execution/MVP-Acceptance-Matrix.md`、`Docs/ATTRIBUTION.md`、`Docs/THIRD_PARTY_NOTICES.md`。

**Interfaces:** 验收表每项存储提交 SHA、平台/架构、测试命令、实际数量、结果、日志位置、未覆盖边界；缺任何必需证据保持功能关闭，不能用 `ATLAS_ALLOW_UI_SKIP=1` 补过本地缺失覆盖。

- [ ] **准备可回滚 VM 与矩阵。** macOS 14 和当时实际支持的当前 macOS 各一份干净快照；记录可用架构，arm64/amd64 至少分别完成构建与安装资产校验，没有对应真实运行环境则标记未实测并限制发布声明。PAM 验收前保留独立管理员恢复会话，所有文件样本属于测试账户。
- [ ] **验证系统安全。** 在 VM 运行 C2 `verify-pam-vm.sh --execute`：enable/disable/重复执行/失败回滚后检查 root:wheel/0444、下一次 sudo 认证与原配置恢复；主 sudo 文件摘要不变。模拟正在更新、有效/未知 LaunchAgent、蓝牙查询失败和 DNS 失败，跑对应 CLI 流程，核对更新目录、服务、路由和蓝牙均无写入/停止。构造挂载点、祖先链接、身份替换，缓存删除不跨边界。VM 回滚后复验只读状态。
- [ ] **验证原生版本与故障恢复。** `swift test --package-path Packages`、`swift test --package-path Apps`、`swift test --package-path Helpers`、`swift build --package-path XPC`、`swift build --package-path Testing`；`./scripts/atlas/build-native.sh` 验证 Xcode Swift 6，Helper 另执行 `swift build --package-path Helpers -Xswiftc -swift-version -Xswiftc 6`。执行 N4 崩溃/磁盘写入故障矩阵和 Direct/XPC 两种模式，真实 UI 用例必须非零且通过。
- [ ] **验证最终发行产物。** 在专用候选 VM 执行 `./scripts/test.sh`（仅 Shell/Go）、安全门禁、`./scripts/atlas/full-acceptance.sh`；注意该脚本含 `KEEP_INSTALLED_APP=1 verify-dmg-install`，会改 `/Applications`，不能拿日常开发机当纯测试运行。核对 zip/dmg/pkg 内 Helper、runtime 副本和 CLI 新资产；签名检查被跳过不能记为已验证。新增能力开关开启后的同一候选提交必须重跑相关安全子集和安装冒烟，不用关闭状态测试结果替代。
- [ ] **出具验收和回退结论。** 逐项填写 SEC-01～SEC-11：已验证/能力关闭/未验证；原生变更仅在 N4/N5/N6/R2 闭环后重开，PAM 与缓存删除分别独立重开。保留 journal/备份，不降级覆盖 schema 2；任何门禁或真实系统验证失败就关闭对应能力并前向修复。更新 attribution 与用户可见功能范围说明后提交候选，不执行 push/merge/发布。
