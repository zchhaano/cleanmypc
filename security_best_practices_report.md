# Atlas for Mac 安全与系统稳定性审查

审查日期：2026-10-01。代码基线：`3716c48602a57d24ac2875989ad1beed53ee2405`。

## 结论

发现 6 项高风险、5 项中风险问题。需要优先处理的实际后果是：sudo 认证配置变为用户可修改、越界永久删除、应用包被拆散、有效后台服务被删除，以及清理后恢复记录丢失。没有找到足以断言会直接触发 macOS kernel panic、损坏内核或使机器无法启动的证据。应用自身崩溃、网络/蓝牙中断、应用无法启动与内核崩溃应分别看待。

原生 GUI 与遗留 CLI 的风险不同：

| 路径 | 已确认的执行边界 |
| --- | --- |
| 原生 Atlas GUI | 默认直接调用 Swift Worker；Smart Clean 用 Mole 的 `--dry-run` 扫描，再由 Swift/Helper 移入废纸篓；文件整理直接移动文件 |
| 遗留 `mo clean / optimize / touchid / uninstall` | 保留实际 `rm -rf`、`sudo`、PAM 修改、网络/服务操作；不能套用 GUI 的恢复保证 |
| 名称为 PrivilegedHelper 的程序 | 当前是通过 `Process` 启动的普通可执行文件；未发现这里使用 SMAppService/SMJobBless 提权，因此不能把全部 Helper 缺陷表述为已经成立的 root 提权漏洞 |

入口证据：[AtlasAppModel.swift](Apps/AtlasApp/Sources/AtlasApp/AtlasAppModel.swift) 第 190–205 行；[MoleSmartCleanAdapter.swift](Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/MoleSmartCleanAdapter.swift) 第 40–50 行；[AtlasPrivilegedHelperClient.swift](Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasPrivilegedHelperClient.swift) 第 53–64 行。

检查的八份关键 Shell 文件与 `Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/Resources/MoleRuntime/` 内对应副本逐字节相同。不过，“打进资源包”不代表 GUI 会调用其中的每个破坏性命令。

## 高风险

### SEC-01：Touch ID 操作破坏 PAM 文件属主和权限

**影响：用户正常执行一次配置操作后，sudo 的认证策略文件可能变为该用户可写，削弱后续提权认证边界。**

- 位置：[bin/touchid.sh](bin/touchid.sh) 第 109–112、153–155、183–205、234–244、265–269 行；[lib/core/base.sh](lib/core/base.sh) 第 558–564 行。
- 证据：`create_temp_file` 以普通用户身份 `mktemp`；多个分支随后执行 `sudo mv "$temp_file" "$PAM_SUDO_FILE"` 或替换 `sudo_local`，没有恢复 `root:wheel` 和只读权限。Sonoma 分支的一些写入带 `chmod/chown`，但迁移、关闭、旧版启用分支并不一致。
- 触发：关闭已经启用的 Touch ID、迁移旧配置或走旧版启用路径。
- 验证：抽取真实 `disable_touchid`，将路径指向临时目录，用受限模拟 `sudo` 只允许该目录内的 `mv`。执行后得到 `owner=chao mode=600`。没有修改 `/etc/pam.d`，也没有实际提权测试。
- 风险解释：普通用户持有认证文件写权限本身就是严重边界错误；被该用户运行的恶意程序可能利用它修改认证链。具体提权效果仍取决于目标 macOS/PAM/MDM 配置，不把模拟测试等同于已完成提权。
- 修复：在受信任目录创建 root 所有的暂存文件，写入及校验后，以正确属主、权限原子替换；所有分支共用同一实现；保留可验证的备份和失败回滚。不能在 `sudo mv` 后才依赖下一次 sudo 调用修复权限。

Apple 公布的 [OpenPAM 配置加载实现](https://github.com/apple-oss-distributions/OpenPAM/blob/main/openpam/lib/openpam_configure.c) 从策略路径读取认证链；这类配置属于认证边界，不能当成普通用户设置文件处理。

### SEC-02：Shell 删除保护可被父目录符号链接和非规范路径绕过

**影响：看起来在缓存目录内的删除操作，可以实际删除其他位置的数据；若进入 sudo 分支，影响扩大到该权限能够修改的系统配置。**

- 位置：[lib/core/file_ops.sh](lib/core/file_ops.sh) 第 67–178、190–193、253、314–325、377 行。
- 证据：只对 `[[ -L "$path" ]]` 的最终组件处理符号链接，保护判断使用原始字符串；删除最终仍把原始路径传给 `rm -rf`。`safe_sudo_remove` 同样只拒绝最终组件是链接，没有检查祖先组件。
- 验证：真实验证函数拒绝 `/etc/pam.d/sudo`，却允许 `//private/etc/pam.d/sudo`，也允许“临时目录中的链接 → /private/etc”下面的 `pam.d/sudo`。仅对这些系统路径调用了验证函数，没有删除或写入。另用纯临时目录中的 `alias/marker` 实际验证了 `safe_remove` 会删除链接目标目录内的 marker。
- 触发：缓存或开发工具目录有父级链接、外部路径配置提供非规范路径，或检查与执行之间目录被替换。并不要求攻击者改动最终文件本身。
- 修复：在受允许根目录内按路径组件验证，拒绝不允许的祖先链接；统一处理重复分隔符和系统路径别名；默认拒绝根目录本身。高权限执行应使用基于目录描述符的操作或等价的竞态防护，仅先调用一次 `realpath` 还不足以解决检查后替换问题。
- 限制：操作系统权限、SIP、只读卷仍可能阻止部分删除；本发现不意味着可以绕过 SIP。

### SEC-03：原生递归整理会拆散应用包和其他文件包

**影响：用户整理一个包含应用包的目录，可能把包内可执行文件或资源移走，造成应用无法启动或运行异常；其他目录型文件包也存在类似风险。**

- 位置：[AtlasFileOrganizerScanner.swift](Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/AtlasFileOrganizerScanner.swift) 第 12–14、34–50、77–86 行；[AtlasScaffoldWorkerService.swift](Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasScaffoldWorkerService.swift) 第 754–810 行；[AtlasPathValidator.swift](Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasPathValidator.swift) 第 47–55 行。
- 证据：递归枚举仅配置 `.skipsHiddenFiles`，没有 `.skipsPackageDescendants`，也不检查包属性；目录本身被忽略，但目录内文件会生成独立整理项。执行端接受用户主目录、`/Applications` 等来源，随后逐文件 `moveItem`。目的地在主目录的限制不能防止破坏来源包。
- 验证：编译原扫描器逻辑，使用临时 `Sample.app/Contents/MacOS/Sample`；递归扫描输出 `.../Sample.app/Contents/MacOS/Sample -> ~/Organized/Other/Sample`。仅扫描，没有移动实际应用。
- 触发：用户开启递归扫描，选择含 `.app` 或其他包的目录，然后执行整理；默认非递归扫描降低了发生概率。
- 修复：枚举时跳过包内部，包按完整对象处理或排除；执行时再次拒绝包内部路径。限制“整理”的来源，默认排除应用、资源库、系统服务目录；对正在使用的文档包做专门保护。

### SEC-04：原生清理的部分成功和落盘失败会丢失恢复记录

**影响：文件已移入废纸篓，但 Atlas 没有记录恢复入口，或重启后丢失记录；“执行失败”不代表没有发生文件变更。**

- 位置：[AtlasScaffoldWorkerService.swift](Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasScaffoldWorkerService.swift) 第 1022–1047、272–279、298–324、1000–1008 行。
- 证据：同一个 Finding 下，先将成功的移动记入局部 `mappings`，直到全部目标处理完才写入 `result.restoreMappingsByFindingID`。第二个文件失败时，前一个成功移动的映射被丢弃。整个批次完成前也没有持久化逐文件结果；`persistState` 遇到写入失败只记日志，调用者继续报告完成。
- 验证：抽取真实 `executeSmartCleanSelections` 和结果结构，只替换文件操作依赖，模拟 A 成功、B 失败，得到 `SIMULATED_MOVE_COMPLETED=A`、`RECOVERY_MAPPINGS=0`、`HAS_RECORDED_OUTCOME=false`。
- 触发：权限或 I/O 错误、Helper 返回错误、进程退出、存储空间不足等。已存在的部分失败测试覆盖不同 Finding，不能证明同一个 Finding 内的多路径失败安全。
- 修复：执行前写入操作日志，逐文件记录已完成结果；catch 时保留已完成映射；状态落盘失败必须返回可见的部分完成状态，并阻止继续扩大变更；启动时对未完成任务进行核对。
- 限制：成功移入废纸篓的文件通常仍能手动找回，本问题不等于当场永久删除。

### SEC-05：系统清理删除更新暂存文件，缺少更新活动互斥

**影响：清理与系统更新重叠时，可能删除更新所需的暂存文件，导致更新失败或需要重新下载。**

- 位置：[lib/clean/system.sh](lib/clean/system.sh) 第 75–115 行；入口 [bin/clean.sh](bin/clean.sh) 第 925–930 行。
- 证据：遍历 `/Library/Updates` 后，仅排除带 `restricted` 标记的项目，就执行 `safe_sudo_remove`；这里没有文件年龄条件，也没有检查更新下载、准备或安装状态。`/macOS Install Data` 分支只依据目录修改时间是否满 14 天。
- 触发：遗留 `mo clean` 的系统清理已开启，并与更新流程同时发生。后面的安装器 `.app` 分支确实有进程检查，但这个检查没有覆盖前述两个目录。
- 验证级别：代码确认；没有在真实更新期间运行删除，也没有验证无法开机的结果。
- 修复：从通用清理中移除此类由系统管理的更新状态，或要求可靠的更新状态检查、互斥及专门恢复设计。目录年龄不等于安装任务已经结束。

### SEC-06：LaunchAgent 孤儿判断读错可执行文件字段，会删除有效服务

**影响：合法后台任务可能被当成残留卸载并永久删除，导致同步、自动化、更新等功能停止。**

- 位置：[lib/clean/apps.sh](lib/clean/apps.sh) 第 604–613、640–647、709–710、735–770 行；入口 [bin/clean.sh](bin/clean.sh) 第 983–987 行。
- 证据：`_extract_program_path` 优先读 `ProgramArguments.0`，只有为空时才读 `Program`；launchd 的规则恰好是显式 `Program` 优先。`ProgramArguments[0]` 可以是自定义 argv[0]，不一定是磁盘路径。判断为孤儿后自动 `launchctl unload` 并 `safe_remove`。
- 验证：临时 plist 设置 `Program=/usr/bin/true`、`ProgramArguments=[atlas-custom-argv0]`；真实函数输出 `atlas-custom-argv0`，并将其判为孤儿，尽管真正的 Program 存在。没有加载或卸载真实服务。
- 旁路风险：第 399–597 行的系统服务清理主要依赖固定应用位置、文件名模式与 Spotlight；没有查到主应用，不能证明一个特权服务已经无用。
- 修复：遵循 launchd 对 Program 的优先级和路径语义；将“查询失败/状态未知”保留为未知；核对已加载任务、实际程序与所属应用。对待删除服务先保留配置与恢复方式，不能自动把启发式候选当成确认残留。

字段语义见 Apple 的 [launchd.plist 手册](https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5)。

## 中风险

### SEC-07：“优化”把状态未知当作可以重置网络和蓝牙

- 位置：[lib/check/health_json.sh](lib/check/health_json.sh) 第 140–144 行；[bin/optimize.sh](bin/optimize.sh) 第 165–175、492–505 行；[lib/optimize/tasks.sh](lib/optimize/tasks.sh) 第 58–69、548–569、649–693 行。
- 证据：网络/蓝牙被标为 `safe=true` 自动执行。默认路由或 `example.com` DNS 检查失败，会执行 `sudo route -n flush` 和 ARP 清理；蓝牙枚举失败时返回“未连接 HID”，进而可能结束 bluetoothd。`confirm_items` 循环当前也只是打印操作名，没有逐项确认。
- 验证：将 DNS 查询和设备枚举模拟为失败、将 sudo 替换为纯记录函数，观察到 `route -n flush`、`arp -a -d`、`pkill -TERM bluetoothd` 均进入执行路径。
- 后果：网络、VPN/远程连接或蓝牙输入/音频可能中断。蓝牙守护进程通常重启，但这不是无影响操作；也不能保证刷新路由能修复 DNS 故障。
- 修复：检测失败即跳过；区分 DNS 故障与路由故障；把服务重启移到明确的故障排查动作，展示影响并要求用户主动选择；不要将其归为默认安全优化。

Apple 的 [route 手册](https://github.com/apple-oss-distributions/network_cmds/blob/main/route.tproj/route.8) 明确说明 flush 会删除网关路由项，不只是清 DNS 缓存。

### SEC-08：遗留清理默认清空废纸篓，会消灭原生应用依赖的恢复源

- 位置：[lib/clean/user.sh](lib/clean/user.sh) 第 11–35 行；[lib/core/base.sh](lib/core/base.sh) 第 86–109 行。
- 证据：未把 `.Trash` 加入用户白名单时，常规清理直接要求 Finder `empty trash`，失败则遍历 `~/.Trash` 使用永久删除。默认白名单不包含废纸篓，操作没有独立的逐项恢复计划。
- 后果：用户此前用 Atlas、Finder 或其他工具放入废纸篓的文件可能永久丢失；Atlas 显示的恢复保留期限不能保证这些物理文件仍存在。Finder 的废纸篓操作也没有限定为“本次清理产生的项目”。
- 修复：从默认清理中移除清空废纸篓，作为单独的永久删除功能；对原生恢复项使用独立恢复存储，或明确采用尽力恢复语义并即时检测源文件状态。
- 验证级别：静态代码确认，没有清空本机废纸篓。

### SEC-09：Helper 超时不能及时结束等待；子进程输出管道也可能堵塞

- 位置：[AtlasPrivilegedHelperClient.swift](Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasPrivilegedHelperClient.swift) 第 68–93 行；[MoleHealthAdapter.swift](Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/MoleHealthAdapter.swift) 第 24–38 行；[MoleSmartCleanAdapter.swift](Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/MoleSmartCleanAdapter.swift) 第 52–80 行。
- 证据：Helper 的任务组取消不能使等待 `terminationHandler` 的 continuation 自动结束；终止子进程的代码位于任务组退出之后，因此要等进程退出才能抵达。几个适配器都先等进程退出、后读取输出，输出超过管道容量时可能相互等待。Smart Clean 有 120 秒终止计时器，但仍存在错误超时风险；Health 没有对应超时。
- 验证：原 Helper client 与真实协议类型抽取编译，模拟 Helper 只读取 stdin 后 sleep 2 秒；配置超时 0.1 秒，实际约 2.245 秒才返回。没有执行任何文件操作。
- 后果：任务或应用流程长期卡住、扫描失败；不是 macOS 内核崩溃证据。
- 修复：启动前设置进程退出处理；超时分支直接终止所拥有的子进程并完成受单次恢复保护的 continuation；同时持续读取 stdout/stderr。取消与超时必须覆盖所有挂起点。

Swift 的 [TaskGroup 文档](https://docs.swift.org/latest/documentation/swift/taskgroup/) 说明任务组退出前等待所有子任务结束。

### SEC-10：恢复逻辑可能把重新生成的文件当成恢复成功

- 位置：[AtlasScaffoldWorkerService.swift](Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasScaffoldWorkerService.swift) 第 1118–1124、1148–1158、379–380、421 行。
- 证据：仅凭“目的路径已存在、废纸篓来源已不存在”就跳过移动并判作已经恢复，没有核对文件身份或先前执行凭据；上层随后计入恢复成功并移除恢复项。
- 触发：原文件被移入废纸篓后，应用重新生成同名缓存/日志，旧文件又被清空废纸篓删除。此时新文件不是用户要求恢复的旧文件。
- 后果：界面显示恢复成功，掩盖真实数据丢失。它不会在该分支覆盖现有文件，但成功结论不可靠。
- 修复：用逐文件操作记录证明幂等恢复，必要时核对文件标识或内容；无法证明时返回“原始来源丢失/目标冲突”，保留证据供用户检查。
- 验证级别：静态控制流确认。

### SEC-11：整理条目超过 65,535 个时存在确定的整数转换崩溃点

- 位置：[AtlasScaffoldWorkerService.swift](Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasScaffoldWorkerService.swift) 第 924–939 行；[AtlasFileOrganizerScanner.swift](Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/AtlasFileOrganizerScanner.swift) 第 31–88 行。
- 证据：计划 ID 构造使用 `UInt16(entries.count)`，但扫描结果没有对应数量上限。Swift 的检查型转换在 65,536 及以上会触发运行时错误。
- 触发：递归扫描大型目录，然后进入整理计划构造。默认直接 Worker 路径会影响 App 进程；XPC 模式下影响 Worker。
- 修复：使用能够容纳计数的编码或明确的截断转换，并对大批量操作设置产品级上限、分页与进度控制；计划标识最好绑定完整操作内容。
- 验证级别：静态确认；没有故意触发本机 App 崩溃。

## 另外需要加固，但没有证明为当前可直接利用的 root 漏洞

1. [HelperActionExecutor.swift](Helpers/AtlasPrivilegedHelper/Sources/AtlasPrivilegedHelperCore/HelperActionExecutor.swift) 第 145–175 行允许 allowlist 根目录本身，且多种操作共用宽泛根目录；`removeLaunchService` 主要靠 `.plist` 扩展名判断。应改成每种动作各自的精确范围、对象类型与根目录拒绝规则。`repairOwnership` 使用当前 UID/GID，也不应在未来提权后照搬使用。
2. [AtlasSmartCleanExecutionSupport.swift](Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasSmartCleanExecutionSupport.swift) 第 83–98 行用 `path.contains` 判断缓存特征，能够将主目录内仅名称相似的路径放行。应改为组件边界和具体目录规则；当前扫描器实际会给出哪些候选，仍是利用可达性的额外条件。
3. [AtlasXPCTransport.swift](Packages/AtlasInfrastructure/Sources/AtlasInfrastructure/AtlasXPCTransport.swift) 第 83–87 行直接接受连接，没有可见的调用方代码身份检查。当前使用内嵌 XPC service，且默认 GUI 走直接 Worker，不能仅凭这里就声称任意外部进程可获得 root。若未来改为全局 Mach service/提权服务，必须先建立客户端身份及每次操作授权。
4. Swift 的“解析链接 → 检查路径 → 按路径移动”也有检查与执行之间的替换窗口；恢复中的 `isFileOrganizerRestoreTarget` 第 1206–1210 行检查原始字符串，而实际移动使用解析后的 URL，规则不一致。应统一来源、目的地、文件身份检查。

## 验证范围和修复顺序

本次以系统操作安全为目标，审查 Swift App/Worker/Helper、Mole Shell 和 Go 删除路径，结合 Apple 与 Swift 一手文档。`security-best-practices` 技能没有 Swift/macOS 专用规则，本报告中的相关结论来自实际代码、隔离验证与官方平台资料。没有进行完整依赖漏洞扫描、LandingSite Web 审计或发行产物签名实测。

执行了六组隔离验证：路径守卫与临时 marker 删除、PAM 配置替换、恢复映射部分失败、Helper 超时、LaunchAgent 字段误判、网络/蓝牙模拟；另外对原生扫描器执行了应用包候选扫描。Swift 探针采用 Swift 5 语言模式编译，符合 SPM 清单设置；没有以此宣称 Xcode Swift 6 构建通过。未运行真实清理、真实 sudo/PAM 修改、网络重置、服务卸载或全量验收。生产代码未修改。

建议处理顺序：

1. 优先隔离 SEC-01/02 的认证和高权限永久删除路径，并禁止递归整理应用包内部（SEC-03）。
2. 补齐原生逐文件恢复记录及异常持久化（SEC-04）；暂停自动删除系统更新目录与启发式判定的后台服务（SEC-05/06）。
3. 将网络/蓝牙重置和清空废纸篓改为单独的主动操作（SEC-07/08）。
4. 修复进程等待、恢复成功判据与大批量条目转换（SEC-09/10/11）。
5. 为已发现路径添加针对性的回归测试：父目录链接、PAM owner/mode、包内文件、同一 Finding 部分成功、有效 Program 与自定义 argv[0]、状态查询失败、恢复源丢失、65,536 条目。

SIP 能降低修改部分系统文件的风险，但不是本项目的完整安全网。Apple 明确列出 `/Applications`、`/Library`、`/usr/local` 是第三方软件可写的位置；用户数据、第三方服务和应用仍需要工具自身保护。参见 [Apple：System Integrity Protection](https://support.apple.com/en-ca/102149)。
