# CLI System Safety Implementation Plan

> 实施更新（2026-10-04）：代码已落地；已执行的隔离/本地验证和未执行的 VM/发布验证见 [最终验收表](../security/2026-10-01-release-acceptance.md)。关闭能力候选不代表完整功能重开。下列原始任务判据保留，涉及实际 VM、架构运行安装或新 CI URL 的步骤仍待验收。


> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消除遗留 CLI 对 PAM、系统状态、服务、废纸篓和越界文件的默认破坏风险。

**Architecture:** 先在执行端关闭危险能力；PAM 单独事务化，缓存永久删除只通过普通权限目录描述符后端。服务检测保持只读。

**Tech Stack:** macOS Bash、Bats、Go 1.25.0、Darwin/x/sys/unix。

**Spec:** [改进方案 §3～4、9](../design/2026-10-01-security-hardening.md)。依赖与发布顺序见[总计划](2026-10-01-security-hardening.md)。

## Global Constraints

- Helper 保持普通用户权限；自动清理不执行 root 永久删除；不提供绕过安全拒绝的 `--unsafe` 或环境开关。
- Go 保持 `go.mod` 的 1.25.0，不新增第三方依赖；macOS 14+ 才考虑重开 `sudo_local` 写入。
- 生产测试不修改真实 PAM、路由、蓝牙、用户废纸篓或服务；真实系统操作只在可回滚的测试虚拟机执行。
- 每次根目录 Shell 变更同时同步 `Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/Resources/MoleRuntime/`；不直接单独编辑副本。
- 非零拒绝或部分完成必须传到调用层；不增加已释放字节，不因 `|| true` 变成成功。

## Review Focus

1. 旧配置与非交互 `--yes`：C1 确认不能绕过后端关闭。
2. 主目录/缓存父目录为链接或执行中被替换：C3 哨兵测试。
3. PAM 原文件链接、多硬链接、权限异常：C2 拒绝且保留原件。
4. 名字含空格/中文/换行、长路径与特殊设备：C3 JSON 完整传输且特殊对象不操作。
5. 发行包缺少新二进制、内嵌旧脚本：C1/C3 失败即停止，无旧 `rm` 回退。

## C1：关闭危险路径并同步内嵌运行时

**Files — Modify:** `bin/touchid.sh`、`bin/clean.sh`、`bin/optimize.sh`、`bin/uninstall.sh`、`lib/core/file_ops.sh`、`lib/core/base.sh`、`lib/clean/system.sh`、`lib/clean/apps.sh`、`lib/clean/user.sh`、`lib/check/health_json.sh`、`lib/optimize/tasks.sh`、`lib/manage/autofix.sh`、`lib/uninstall/batch.sh`。

**Create:** `scripts/atlas/sync-mole-runtime.sh`、`scripts/atlas/mole-runtime-files.txt`、`Docs/security/2026-10-01-hardening-evidence.md`。

**Test:** 扩展 `tests/cli.bats`、`tests/core_safe_functions.bats`、`tests/clean_system_maintenance.bats`、`tests/clean_apps.bats`、`tests/clean_user_core.bats`、`tests/optimize.bats`、`tests/manage_autofix.bats`、`tests/uninstall.bats`；新增 `tests/mole_runtime_sync.bats`。

**Interfaces:**

- 保持现有 `safe_remove` / `safe_sudo_remove` 调用形式，暂时返回非零拒绝，调用者输出明确“未执行”。只读扫描不受影响。
- 新增内部 `register_owned_temp(path)` / `cleanup_owned_temp(path)`：仅接受本进程创建且身份一致的临时文件/目录；不能作为任意删除 API。
- `sync-mole-runtime.sh --write` 按清单单向复制；`--check` 逐字节及文件集合比对，漂移或缺失返回 1，清单错误返回 2；检查模式不写文件。

- [ ] **写回归。** 使用命令记录器代替 sudo、launchctl、route、arp、pkill、osascript 和系统删除：旧白名单未包含 Trash、检测器失败、直接调用优化任务、autofix、`--yes` 等输入均断言危险调用计数为 0；PAM/更新/服务/Trash 临时哨兵内容不变。卸载被拒绝前不得停止应用。temp 清理只删除登记对象，替换链接后拒绝。
- [ ] **验红。** `bats tests/cli.bats tests/core_safe_functions.bats tests/clean_system_maintenance.bats tests/clean_apps.bats tests/clean_user_core.bats tests/optimize.bats tests/manage_autofix.bats tests/uninstall.bats`；旧实现应触发新断言，不允许访问真实受保护路径。
- [ ] **实施关闭与调用点核对。** 删除自动系统更新/服务/网络蓝牙/Trash 操作路径；执行函数也拒绝。用 `rg` 核对 `bin/`、`lib/`、`cmd/` 中的 `rm`、`RemoveAll`、sudo 和 Finder 删除；证据表逐项标注缓存数据删除、用户明确 Trash、进程私有临时回收或本轮禁用，关闭绕过 wrapper 的永久数据删除。只保留现有只读诊断；不新增确认即可重开的分支。
- [ ] **实施并验证同步。** 从目前实际内嵌集合建立清单，明确不存在于 App 的构建/测试文件不纳入；同步不清空资源目录。`bats tests/mole_runtime_sync.bats` 要覆盖修改/缺失/额外可执行脚本三个漂移及 `--check` 不写文件。执行 `./scripts/atlas/sync-mole-runtime.sh --write` 后 `--check` 返回 0；重跑上述 Bats 全通过。
- [ ] **审查并提交。** 更新 `Docs/ATTRIBUTION.md`、`Docs/THIRD_PARTY_NOTICES.md` 说明派生 Shell 安全行为变化，在 evidence 文档记录暂时不可用功能；独立提交 C1。

## C2：限定的 PAM 事务写入

依赖 C1；只有 R4 的真实 VM 验证通过后才接通生产修改入口。

**Files — Create:** `lib/manage/pam_transaction.sh`、`tests/pam_transaction.bats`、`scripts/atlas/verify-pam-vm.sh`。

**Modify:** `bin/touchid.sh`、`lib/manage/autofix.sh`、运行时清单与副本、`tests/cli.bats`。

**Interfaces:** `apply_touchid_transaction enable|disable` 返回 0 表示变更及验证完成，非零表示拒绝、已回滚或需人工核对；错误码在 stderr 中区分。生产目标固定 `/etc/pam.d/sudo_local`，备份固定 `/var/db/atlas/pam/`；测试低层文件函数依赖注入，发行入口不接受 PAM 路径覆盖。

- [ ] **写回归。** enable/disable/重复执行、非标准主 sudo include、第三方 sudo_local 行保留、空文件移除、链接/多硬链接、已有用户属主配置、写满、rename 失败、post-check 失败。命令记录断言暂存文件的 `root:wheel`/`0444` 设置发生在 rename 前，失败修复不调用第二次 sudo；原件和备份内容可校验。
- [ ] **验红。** `bats tests/pam_transaction.bats tests/cli.bats tests/manage_autofix.bats`；新事务缺失或旧写入顺序导致失败，测试全部指向临时目录。
- [ ] **实现事务。** 固定操作和路径、受信任目录/普通文件验证、root 私有备份目录 `0700`、备份文件 `0600`；单次提升会话内完成暂存/校验/元数据/替换/失败回滚。只增加或移除准确匹配的 `pam_tid.so` 规则，不重排其他规则；遇未知或已有不可信配置拒绝，不自动“修复”。主 `/etc/pam.d/sudo` 始终不写。
- [ ] **验证。** 上述 Bats 全通过；同步资源并检查一致性。编写 VM 脚本前置条件与恢复步骤，脚本默认只打印检查项，真实执行需显式 `--execute` 且仅在预置 disposable VM marker 存在时运行。VM 真实 owner/mode 与 sudo 认证交给 R4，不用 mock 结果代替。
- [ ] **审查并提交。** evidence 标为“事务代码完成，入口仍关闭，等待 VM”；C2 代码提交不自动重开 Touch ID。

## C3：普通权限、限域的缓存删除后端

依赖 C1。该任务包含必要的安装/发布接线，缺任意一项都不能开放删除。

**Files — Create:** `cmd/safe-remove/main.go`、`internal/safefile/request.go`、`internal/safefile/policy_darwin.go`、`internal/safefile/remove_darwin.go`、`internal/safefile/policy_darwin_test.go`、`internal/safefile/remove_darwin_test.go`、`tests/safe_remove_backend.bats`。

**Modify:** `lib/core/file_ops.sh`、`Makefile`、`install.sh`、`.github/workflows/release.yml`、`tests/installer.bats`、`tests/core_safe_functions.bats`、运行时清单/副本及实际调用方的拒绝统计。

**Interfaces:**

- JSON stdin：`{"version":1,"scope":"userCaches","relativePath":"vendor/item","expected":{"device":123,"inode":456}}`；禁止任意 root、绝对路径、空相对路径。stdout 是结构化结果，stderr 为有界诊断。
- Go：`type FileIdentity struct { Device uint64; Inode uint64 }`；`type RemoveRequest struct { Version int; Scope string; RelativePath string; Expected FileIdentity }`；`type RemoveResult struct { Status string; RemovedEntries int; ErrorCode string }`；`func Remove(ctx context.Context, req RemoveRequest) (RemoveResult, error)`。给 JSON 字段显式 tags。
- `Status` 固定 `completed|rejected|partial`；退出码 0 仅 completed、2 请求/策略拒绝、3 部分失败、4 后端 I/O 错误。Shell 只能对 0 计成功；部分删除只报告已确认数，不声称回滚。
- 生产从当前账户记录获取主目录并固定 scope；测试内部构造受控目录与 UID provider。root 运行拒绝。Shell 收集扫描时身份；缺后端/缺身份拒绝，不退回旧命令。

- [ ] **写边界与竞争测试。** `TestRejectRootAndTraversal`、`TestRejectAncestorSymlink`、`TestConcurrentAncestorSwapPreservesOutsideSentinel`、`TestRejectMountAndSpecialFiles`、`TestIdentityChangeRejects`、`TestPartialDeletionIsReported`。用确定性 hook 在验证/打开/遍历间交换父目录；外部 sentinel 始终完整，合法缓存普通文件能删除；根目录自身及未选兄弟不删除。以临时根验证空格/中文/换行与缺失后端；真实挂载隔离用例交 R4。
- [ ] **验红。** `go test ./internal/safefile ./cmd/safe-remove` 与 `bats tests/safe_remove_backend.bats`；记录新保护在旧后端上不成立，不能通过 mock 掩盖真正文件操作。
- [ ] **实现描述符后端。** 逐组件 no-follow 打开可信根；fstat 核对身份，递归拒绝链接/特殊对象/跨文件系统；基于已打开目录删除，保证 fd 在全部错误/取消路径关闭。计划中的对象身份是授权依据，路径只作定位。不得依赖 `realpath + rm`，不得接受外部传入 fd/任意 scope。失败时保留准确部分计数。
- [ ] **完成所有分发入口。** Makefile 生成 `bin/safe-remove-go`、`bin/safe-remove-darwin-arm64`、`bin/safe-remove-darwin-amd64`；release tar/上传清单、安装器二进制映射与校验同批修改。只从本项目对应版本产物解析，不因沿用上游仓库 URL 下载不存在/不匹配的新资产。裸脚本安装缺该程序时仍可只读扫描，写操作拒绝。GUI dry-run 资源路径不因此自动启用 CLI 删除。
- [ ] **验证与提交。** `go test -race ./internal/safefile ./cmd/safe-remove`、上述 Bats 和 `tests/installer.bats`、`tests/core_safe_functions.bats` 全通过；缺架构/损坏资产测试拒绝安装或写操作；同步副本检查通过。审查后仅开放 `userCaches`，其他 CLI 删除仍拒绝；在 evidence 记录范围与竞态残余边界，独立提交。

## C4：服务检测遵循 launchd 语义，保持只读

依赖 C1。

**Files — Modify:** `lib/clean/apps.sh`、`tests/clean_apps.bats`、运行时对应副本。

**Interfaces:** 保留 `_extract_program_path(plist)`，显式 `Program` 优先；新增 `classify_launch_item(plist)` 输出 `present|missing|unknown`。三态结果只用于报告，不能调用 `launchctl unload/bootout` 或文件删除。

- [ ] **写回归。** `Program=/usr/bin/true` + 自定义 argv[0] 为 present；只有绝对 ProgramArguments[0] 时按该路径检查；相对程序、无字段、无权限/解析失败为 unknown；Spotlight 无结果不证明孤儿；missing 也不执行服务卸载/删除。
- [ ] **验红。** `bats tests/clean_apps.bats`，确认旧优先级至少令自定义 argv[0] 用例失败。
- [ ] **实现三态解析。** 按 Apple launchd 字段语义提取，无法完整解释的相对路径/上下文保守归 unknown；删除原二值“查询失败就是孤儿”的分支。系统服务启发式仅列待核对候选。
- [ ] **验证。** 上述 Bats 全通过；为所有分类断言模拟 launchctl 和 remove 调用计数都是 0。同步 runtime，`./scripts/atlas/sync-mole-runtime.sh --check` 返回 0。
- [ ] **审查并提交。** evidence 记录 SEC-06 靠“正确诊断 + 不自动删除”关闭，而非声称已证明所有孤儿判断准确。
