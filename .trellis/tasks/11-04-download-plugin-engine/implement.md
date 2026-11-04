# 插件补丁实施计划

## 依赖与顺序

contracts-store 的协议/存储测试已通过（48 项），并以 e58df05、1edb779 提交、归档；本任务已于 2026-11-04 激活。用户已授权按既定规划直接实施、检查、提交并推进，无需逐次确认。该任务与 android-engine 可独立，但默认顺序推进，一个工作区只有一个写入者。

- [x] 获取并核对固定 9.5.9 归档；保存许可证、校验及补丁说明，配置显式 path 依赖。
- [ ] 搜索所有回执 pop、异步状态写入、终态/恢复材料清理调用方，补齐持久 read/ack 和受控释放；测试不保留旧破坏路径。
- [ ] 增加不依赖总长的累计字节事件，校准恢复偏移和时钟窗口。
- [x] 桌面实际 GET 写前验证，阻止 isResume=false/FileMode.write/deleteTempFile 静默降级。
- [ ] 实现 PluginEngine、幂等命令、inspect/ack 以及启动关联；保护 iOS 后台临时文件。
- [ ] 做故障注入和本地可控 HTTP 测试，记录桌面及 iOS 原型结论，再交给仓库/文件任务。

## 验证

flutter analyze、flutter test，以及补丁自身相关测试；新增测试文件创建后在本计划记录实际路径。macOS 用 flutter build macos --release 验证原生集成；Windows 必须在 Windows 机器 flutter build windows --release 并运行测试；iOS 可先 flutter build ios --no-codesign 验证编译，后台/强退/恢复必须实体设备执行。

必须断言：三处回执交付中断可重放；重复/旧 ack 不丢新材料；零重试 failed 保留引用；无长度响应中途字节增长；续传不安全时原部分文件散列不变；桌面重开无自动请求；iOS 关联不重复提交且按系统事件落盘。

## 风险与停点

没有设备、Windows 环境或 iOS 安全续传证据时保持未验收，记录命令/环境/错误，不将 fake 通过当作平台通过。不得未经确认采用“总是从头重下”或忽略 iOS。回滚只处理本任务的补丁和适配，不覆盖其他任务已用的 schema。

## 开工交接

- implement/check 上下文已增加 [持久化契约](../../spec/frontend/persistence.md)，复用实际 ExecutionKey/EngineCommand/Receipt/Ack 与 AppStore 边界，不重建业务事实库。
- 精确基础依赖保持 sqlite3 3.5.2、path_provider 2.1.6；不升级 SDK、不加依赖覆盖。上游插件引入及任何必要配置变更需记录实际原因和检查结果。
- 源设计当前 570 行、55,463 字节，超过注入上限；实施和审查代理必须分段完整读文件，不能只依赖自动上下文。
- 首个子任务只验证当前主机真实 SQLite；本任务所有尚未运行的原生、Windows 和 iOS 真机条目保持未验证，不借用前一任务结果宣称平台通过。

## 2026-11-04 实施证据与有限恢复交接

上次实施运行达到 1800000ms 超时；父代理已确认没有残留构建/测试进程，并备份本任务 304 个文件、哈希及 tracked diff 至 `/var/folders/gf/v79lfxb56kn2yhvdvyvtm6_80000gn/T/plugin-engine-timeout-checkpoint-htgd5kfh`。本次仅核对既存日志、记录与交接，不修代码、不新增测试、不重跑构建/测试/强杀实验。任务仍为 in_progress，PRD 中涉及完整平台契约的验收保持未勾选。上方未勾条目包含已实现的桌面部分，不能据此误读为没有实现，也不能用桌面证据勾选完整 iOS 验收。

### 来源与变更清单

- 官方 `https://pub.dev/api/archives/background_downloader-9.5.9.tar.gz` 已下载至 `/tmp/downloader-background-9.5.9.tar.gz`，实际 `shasum -a 256` 结果为 `ae55e127f87397b372578fc9474568b879fa78326103c342e00160558d08e527`。直接从归档提取至 `third_party/background_downloader`，保留 LICENSE 和上游文件；当前 294 个 vendor 文件。来源及局限见 `PATCHES.md`，归档基线差异见 `downloader.patch`（989 行）。
- Vendor 相对归档的全部差异：`PATCHES.md`、`downloader.patch`、`pubspec.yaml`、`lib/background_downloader.dart`、`lib/src/execution_journal.dart`、`lib/src/file_downloader.dart`、`lib/src/base_downloader.dart`、`lib/src/desktop/desktop_downloader.dart`、`lib/src/desktop/download_isolate.dart`、`lib/src/desktop/isolate.dart`、`ios/background_downloader/Sources/background_downloader/BDPlugin.swift`、同目录 `ExecutionJournal.swift`、`TaskFunctions.swift`、`UrlSessionDelegate.swift`、`test/execution_boundary_test.dart`。其他 vendor 文件为上游原件，不能把随包附带的旧 test_output 当本任务证据。
- 应用新增 `lib/features/downloads/data/plugin_engine.dart`；新增 `integration_test/plugin_engine_test.dart`、`integration_test/plugin_engine_process_test.dart`、`integration_test/plugin_engine_process_check.py`。
- 配置变更：`pubspec.yaml`/`pubspec.lock` 引入显式 path 插件及 Flutter SDK integration_test（上游补丁使用 crypto）；保持 sqlite3 3.5.2、path_provider 2.1.6、Flutter 3.44.8/Dart 3.12.2，无 dependency_overrides。`analysis_options.yaml` 仅排除 vendor 独立 example 应用，补丁生产 Dart 与新测试仍实际分析。
- 平台配置：`ios/Runner.xcodeproj/project.pbxproj` 三处部署目标 13.0 → 已批准的 14.0；`macos/Runner/DebugProfile.entitlements` 和 `Release.entitlements` 仅新增客户端联网。没有修改 Android 执行配置、页面或用户目录发布。
- Flutter 自动刷新 `.flutter-plugins-dependencies`、iOS GeneratedPluginRegistrant 及 ephemeral Swift Package 引用/构建产物；这些为忽略的生成项，未手写生成注册文件，git 当前没有额外 tracked 生成文件变更。Windows 未构建。
- 未更改共享 DownloadEngine、领域 DTO、AppStore 或 schema；新增 PluginEngineException 携带既有 DownloadFailure，插件内部 JSON 显式映射为现有 DTO。`.pi/agents/*` 与 `docs/` 为用户已有内容，未修改/暂存/回退。未暂存、提交、推送、归档或修改 task.json。

### 实际接口、日志及确认边界

- `PluginEngine implements DownloadEngine`，`open(required AppStore store, Directory? journalDirectory)` 注册监听后启动插件，关闭 doTrackTasks、doRescheduleKilledTasks、markDownloadedComplete、autoCleanDatabase，任务 retries=0；拒绝 Android/Linux。空 inspect 返回 ownerSessionId/sequence；执行键派生稳定插件 taskId；命令串行、持久 commandId/payload/result，不明结果不自动重提。旧会话/代次/期望版本或同 commandId 改载荷拒绝。
- 独立 `commands.sqlite`，user_version=1、synchronous=FULL，仅保存 executions/commands/acknowledgements 执行事实。AppStore 仍是业务事实库；原生不会写其业务表。
- Vendor 按每执行目录持久保存完整、递增 `<receiptVersion>.json`，Dart 先写并 flush `.pending` 再 rename；Swift 原子写入并 synchronize，同一 NSRecursiveLock 串行版本分配与合并。`.pending` 不参与 inspect。iOS Dart 检查点通过 recordExecution 平台方法进入同一个原生锁；桌面传输 isolate 在 SendPort 通知前持久化，材料引用/offset/hash 与快照同处日志。
- iOS legacy popLocalStorage 改为非破坏读取；原 BaseDownloader final 清理与桌面提交恢复时先移除 resumeData 路径对适配器材料关闭。普通 failed/paused 不清材料。iOS 同步 didFinishDownloadingTo 在回调返回前登记并移动完成临时文件到持久 staging；当前未证明磁盘写入失败时的系统材料保全。
- `acknowledge` 实际查询注入 AppStore.readAcknowledgements，要求与已提交完整 ReceiptAck 相等，再核对执行版本/归属。确认水位另存执行库；只回收已确认旧版本，保留最新快照。普通暂停/失败 release 列表为空；桌面仅当前取消/发布确认的明确引用可释放、且核对私有目录。iOS 不猜删系统私有 resume data，材料保守保留。
- EngineSnapshot 现有 DTO 只有 receipts，适配器在该集合同时保留最新活动快照与待确认历史；没有擅增 activeReceipts 字段。事件 sampleMonotonicMs 来自适配器本会话 Stopwatch，恢复后消费者仍须按恢复/状态边界重置速度窗口；当前没有 Repository/速度 UI 验收。

### 已保存命令与原始日志（本次未重跑）

| 命令 | 实际结果 | 原始日志 |
| --- | --- | --- |
| `flutter analyze` | No issues found，包含生产补丁 Dart | `/tmp/downloader-analyze.log` |
| `flutter test --reporter expanded` | 48 项基础测试通过 | `/tmp/downloader-tests.log` |
| `flutter test third_party/background_downloader/test/execution_boundary_test.dart --reporter expanded` | 12 项真实 HTTP/桌面传输测试通过 | `/tmp/downloader-http.log` |
| `XCODE_XCCONFIG_FILE=/tmp/downloader-host-build.xcconfig flutter test integration_test/plugin_engine_test.dart -d macos --reporter expanded` | 1 项真实 macOS 引擎/SQLite 集成测试通过；有 foreground app open returned 1 提示，但测试实际执行通过 | `/tmp/downloader-integration.log` |
| `python3 integration_test/plugin_engine_process_check.py` | 真实应用 SIGKILL 后重开 waitingRecovery，新请求数 0；inspect 阶段 1 项通过 | `/tmp/downloader-process.log`；证据目录见下 |
| `flutter build macos --release` | 原定 macOS10.15 被 Xcode27.2 SDK 支持下限12拒绝 | `/tmp/downloader-build-macos.log` |
| `flutter build ios --no-codesign` | 已批准 iOS14 被 Xcode27.2 SDK 支持下限15拒绝 | `/tmp/downloader-build-ios.log` |
| `XCODE_XCCONFIG_FILE=/tmp/downloader-host-build.xcconfig flutter build macos --release` | 编译通过，41.9MB；有 objective_c/sqlite3 双架构 framework 名称警告 | `/tmp/downloader-build-macos-host.log` |
| `XCODE_XCCONFIG_FILE=/tmp/downloader-host-build.xcconfig flutter build ios --no-codesign` | 无签名编译通过，17.4MB | `/tmp/downloader-build-ios-host.log` |

临时 `/tmp/downloader-host-build.xcconfig` 内容为 `MACOSX_DEPLOYMENT_TARGET = 12.0`、`IPHONEOS_DEPLOYMENT_TARGET = 15.0`。它只用于当前主机编译，不改变仓库原定最低目标，不证明 iOS14/macOS10.15 兼容，也不证明 iOS 真机运行。曾有并行 Flutter 命令导致 ephemeral Packages 删除失败的中间尝试，已随后顺序执行 iOS 构建成功；最终日志不能替代最低目标未通过事实。

12 项 HTTP 测试：200、416、错误 Content-Range 起始、弱 ETag、变化 ETag、缺失 ETag、Range 长度错误、同长度内容损坏、材料缺失共 9 个拒绝场景；另外安全强验证器 206 精确追加、未知长度慢响应 EOF 前递增累计字节、真实暂停/继续。拒绝发生于原部分文件打开/删除/写入前，已有文件长度与 SHA-256 不变，未确认从零请求数为 0。未知 total 保持 null；没有用 fraction 反推字节。

真实集成测试覆盖：重复 enqueue/pause 幂等；不同载荷 commandId、旧会话、错误代次、错误期望版本拒绝；持久后未业务提交、读取后未业务提交、业务提交后未 ack 分别关闭/重建适配器；SQLite trigger 注入 commit 失败原子回滚，未提交 ack 拒绝；重复/旧 ack 保留新 failed 回执及材料；零重试恢复失败仍有 resumeRef；显式取消释放。三处故障注入为实际持久日志/真实 AppStore 的适配器重建，不能描述成三处全部 OS 强杀。

单独真实进程证据：`/Users/wang/Library/Containers/com.example.downloader/Data/tmp/plugin-engine-process-bjinau22/prepare.log`、`inspect.log`、`ready`、`verified` 及执行库/日志。Python 外部 HTTP 服务确认只有初次一个请求；精确匹配本工作区新启动的应用 executable 后 SIGKILL，重开 inspect 无网络、状态 waitingRecovery。之前成功证据另在同父目录 `plugin-engine-process-8gphquhs`；初次尝试因 sandbox 外目录不可写失败，最终改用应用 sandbox 临时目录后通过。

### 独立 check 必看与仍未验收

- iOS 真机挂起/系统终止/用户强退/设备重启、私有 resume data offset 语义、安全恢复防止系统未经确认从零传输均无设备证据；当前 URLSession 仍拥有恢复请求，补丁不能保证拦截系统内部所有降级。这是实质安全验收阻断，不能以编译或 Dart 测试标通过，不改变需求、不宣称四平台完成。
- Windows 无真实机器构建/运行；iOS14/macOS10.15 最低版本无可用 SDK 验证。只有当前 macOS 主机的真实运行结果。
- iOS 明确保守保留私有材料；尚未完成原生显式材料释放/旧 preferences 安全回收的完整平台证明。请独立检查 legacy read/ack/清理所有旁路与并发回调、完成临时文件保护失败路径。
- 桌面 checkpoint 每秒重新流式 SHA-256 全部部分文件；内存流式但累计成本随文件增长，超过4GiB吞吐、哈希期间暂停延迟与进程突然中断的 hash/offset/文件一致性尚未测量。不要将基础 DTO 64 位测试当成大文件性能验证。
- 请 check 核对命令日志不明结果语义、旧代次回调隔离、ack 与最新快照/仍引用材料的关系、路径归属核验，以及原生/桌面落盘失败是否保持失败可追踪；本次按有限恢复要求不修任何新发现代码问题。
- 用户目录发布、授权、业务 Repository/速度窗口与 UI、Android 执行均留后续子任务。不会因本次局部通过推进 task.json 为完成。

## 2026-11-04 独立 2.2 完整范围审查

结论为 **BLOCK**，保持 in_progress 和既有未验收 checkbox。本轮直接修复局部代码/测试，但不把常规测试通过当作完整平台或持久并发契约通过。

- 完整读取 check.jsonl 全部5个有效引用（含源设计1–180、181–360、361–570）、PRD/design/implement、frontend Quality Check、实际 DTO/DownloadEngine/AppStore/schema；审查全部13个 vendor 源码差异、应用适配、集成/进程脚本及配置。packages 仅 frontend，没有创建 guides/index.md。
- 已修：续传校验请求末尾与已知总长，拒绝长度自洽的短206/总长变化；关闭/检查点失败不返回暂停/完成成功；pause 收到 failed 必须以异常完成。
- 已修：桌面队列取消先落回执，适配 worker 保留到真正退出，pause/cancel/resume 等待旧 worker 退出，resume 先登记 queued，收敛同一适配器的版本写入交叠。
- 已修：执行身份与未知结果命令在同一 SQLite 短事务登记；ack 核对现存同版本完整业务回执；材料释放同时核对规范化路径、真实父目录及 symlink；重开不把历史字节当新单调时钟样本；失败 pending 使用唯一文件名，重试保留原证据。
- 更新测试：vendor 15项（11种不安全恢复、精确206、未知长度、实际暂停继续、失败pending保全）；macOS 1项集成内新增路径穿越/文件与目录symlink、同版本不同回执、旧样本、强制排队取消和命令登记事务失败断言。

本轮实际执行结果（Flutter 命令顺序运行）：

- `flutter analyze`：No issues，`/tmp/downloader-check-analyze.log`。
- `flutter test --reporter expanded`：48项通过，`/tmp/downloader-check-tests.log`。
- `flutter test third_party/background_downloader/test/execution_boundary_test.dart --reporter expanded`：15项通过，`/tmp/downloader-check-http.log`。
- `XCODE_XCCONFIG_FILE=/tmp/downloader-host-build.xcconfig flutter test integration_test/plugin_engine_test.dart -d macos --reporter expanded`：真实macOS构建/集成1项通过，`/tmp/downloader-check-integration.log`；仍有foreground open returned1提示，测试实际运行通过。
- `python3 /tmp/downloader-refresh-vendor-patch.py`：固定归档SHA核对、patch重建并应用到全新归档，294个vendor文件中除两份补丁说明外逐字节相同；13个源码差异、1110行patch，日志`/tmp/downloader-check-patch.log`。
- `git diff --check`通过，staged为空；未修改task.json/归档/提交，未动用户.pi/agents与docs。

仍有明确阻断，不作通过结论：

- **P1 日志并发丢成功写入**：`flutter test /tmp/downloader_journal_race_test.dart --reporter expanded` 故意诊断失败。4个真实isolate各100次调用生产ExecutionJournal.record，同目录400次均返回成功，仅114个版本（丢286）；`/tmp/downloader-check-journal-race.log`。单适配器worker join不等于日志跨isolate互斥；需明确单写owner/多实例约束或串行提交门。没有以POSIX File.lock冒充isolate锁（SDK明确它为process级），按停点未另搭日志框架。
- **P1 强杀后手动恢复缺口**：独立读实际`plugin-engine-process-bjinau22/execution`证据，v5 detached=true，checkpointOffset/downloadedBytes=8192而材料24576；`/tmp/downloader-check-recovery.log`。现有本地长度严格相等守卫会在GET前拒绝。原进程测试只证明无自动下载，未证明手动继续；安全修复需处理已提交prefix/未提交tail的材料归属，不能为通过直接截断原证据。
- **P1 iOS实质未验收**：系统私有resume data是否未经确认从零传输、挂起/系统终止/强退/重启、offset、完成临时文件磁盘失败保全均无真机证据；didFinishDownloadingTo的登记/移动失败返回后系统临时文件可能消失；原生材料与legacy preferences保守保留不等于完整释放。没有Swift修改，本轮未重复iOS编译，沿用前次host override只编译通过的有限证据。
- **P2 大文件checkpoint成本**：每秒在传输协程全文件SHA-256，累计成本随下载平方增长；暂停/取消消息可被事件循环接收，但退出/终态仍等待当前扫描及finally再次全文件扫描。没有>4GiB真实执行/吞吐/延迟证据，不用DTO测试代替；需增量/分块检查点设计决定。
- Windows实机及iOS14/macOS10.15最低版本仍未验；本轮macOS集成使用临时macOS12 host override，不改仓库最低版本。未重复无关release构建或SIGKILL试验。

完整中文报告由宿主保存到指定subagent-artifacts输出路径；父代理可同步上述局部事实和阻断项到规范，但不得据此归档任务或宣称平台验收完成。

## 2026-11-04 针对性 P1-A/P1-B 实施修复

本轮在独立check落盘代码之上修复，不覆盖其短206/总长、持久失败、worker join、命令事务、完整回执校验及材料归属等修复。未改共享领域DTO/DownloadEngine/AppStore/schema、Swift、SDK、系统权限、仓库最低目标或task.json；未动用户.pi/agents及docs，未暂存/提交/归档。

### P1-A：已修复并发日志成功写入丢失

- `third_party/background_downloader/lib/src/execution_journal.dart` 增加每执行目录 `writer.sqlite` 私有跨isolate串行门；vendor显式依赖精确 sqlite3 3.5.2，继续复用现有版本，不升级SDK、不使用overrides。每个独立连接 busy_timeout=30000、BEGIN IMMEDIATE 保护 latest读取→merge→连续版本→flush pending→发布→COMMIT；失败保留唯一pending，拒绝覆盖已有版本。进程退出由SQLite/OS释放锁，不存在永久用户态锁。
- 新 `reclaim` 与写入使用同一门串行，保留最新快照。PluginEngine桌面ack调用它；iOS继续使用原生NSRecursiveLock，Dart不在原生锁外删除历史，保守保留。没有修改Swift。
- 将真实诊断纳入 `third_party/background_downloader/test/execution_journal_race_test.dart`，4个实际Isolate各100次调用生产record；额外断言400个唯一payload与连续1..400完整回执。修前独立日志success400/records114/lost286是实际失败，现修后success400/errors0/records400/lost0。

### P1-B：已打通保留tail的用户手动安全续传

- `desktop/download_isolate.dart` 对持久 requiredStartByte 的prefix进行hash认证；允许原文件有额外未提交tail，但不把实际长度伪装为checkpoint，不截断原件。GET仍请求认证偏移，并保持强ETag、206、完整Range/总长/长度的写前验证；错误响应/坏prefix保留原件且无从零请求。
- 仅安全响应之后，登记 `recoveryOperation={id,source,candidate,offset,phase:copying}` 和全部 `ownedMaterials`，再排他新建私有candidate并流式复制已验证prefix。复制完成重新验证后登记phase=ready及新resumeData，然后只在新文件追加。原件及其tail始终保留。复制失败不进入传输finally，避免把原tail错误升级为认证材料；中断候选已登记可定位，重试新建候选并保留旧引用。
- PluginEngine明确取消/发布释放当前resumeRef时处理整个登记私有集合；先全部校验路径/真实父目录/symlink归属再删除，普通暂停/失败不释放。集成回归增加登记保留tail/未创建中断copy引用的释放断言，并保留check原来的恶意路径回归。
- vendor新增6个checkpoint8192/file24576生产路径回归：safe206、200、416、changed ETag、badRange、badPrefix；成功文件逐字节正确，原件长度/hash不变，不安全响应不创建staging，无未经确认从零请求。原15项保持通过，总21项。
- 真实进程测试/外部服务器已升级为等待恢复→用户手动继续→正确Range206→完整2MiB逐字节验证；服务端同时统计手动标记前后的请求。最终真实SIGKILL证据为checkpoint8192、原件65536字节，重开自动请求0，手动Range=bytes=8192-；完整文件正确，原件长度/hash保持。证据目录 `/Users/wang/Library/Containers/com.example.downloader/Data/tmp/plugin-engine-process-geklcqgf`（prepare.log、inspect.log、执行日志、manual-request、verified）。

### 本轮变更及顺序验证

实际变更：vendor execution_journal.dart、desktop/download_isolate.dart、pubspec.yaml（sqlite3精确3.5.2）、新 execution_journal_race_test.dart、既有 execution_boundary_test.dart；应用 PluginEngine ack/回收必要接入；既有 macOS integration/process Dart/Python 测试；本任务design.md/implement.md、vendor PATCHES.md/downloader.patch。`flutter pub get`成功，根lockfile无需新增版本解析；没有原生release/iOS重新构建。

| 命令 | 结果 | 日志 |
| --- | --- | --- |
| `flutter pub get` | 成功，既有精确版本保持 | `/tmp/downloader-p1-pub.log` |
| `flutter test third_party/background_downloader/test/execution_journal_race_test.dart --reporter expanded` | 1项通过；实际400成功/400唯一连续版本/0错误/0丢失 | `/tmp/downloader-p1-race.log` |
| `flutter test third_party/background_downloader/test/execution_boundary_test.dart --reporter expanded` | 原15+新增6，共21项通过 | `/tmp/downloader-p1-http.log` |
| `flutter test --reporter expanded` | 基础48项通过 | `/tmp/downloader-p1-tests.log` |
| `XCODE_XCCONFIG_FILE=/tmp/downloader-host-build.xcconfig flutter test integration_test/plugin_engine_test.dart -d macos --reporter expanded` | 真实macOS/SQLite集成1项通过，含owned集合释放及原check断言 | `/tmp/downloader-p1-integration.log` |
| `python3 integration_test/plugin_engine_process_check.py` | 真实SIGKILL后自动0请求、手动正确Range、原件不变、完整内容正确 | `/tmp/downloader-p1-process.log` |
| `flutter analyze` | No issues found | `/tmp/downloader-p1-analyze.log` |
| `python3 /tmp/downloader-refresh-vendor-patch.py` | 官方归档hash核验，patch应用到全新归档逐文件一致；295文件、14源差异、1388行patch | `/tmp/downloader-p1-patch.log` |
| `git diff --check` / `git diff --cached --name-only` | 通过 / 空 | 工具返回 |

Flutter命令顺序执行。macOS只使用既有临时host override（macOS12/iOS15），仓库最低目标仍macOS10.15/iOS14。曾新增测试编辑脚本因精确文本不匹配中止，未产生对应变更；实际成功断言与最终21项日志为准，不把未落盘测试计入。

P1-A与桌面P1-B针对本轮已执行场景通过，仍须父代理独立check。中断copy登记/重试保留实现已落地，但未另做复制中途OS强杀故障实验；本轮真实SIGKILL发生在原下载传输阶段。P2全文件checkpoint哈希O(n²)/大文件延迟未解决。iOS系统私有未经确认从零恢复、真机生命周期/材料释放、Windows实机及原定最低版本仍未验收。不会据此勾选完整平台验收或完成任务。

## 2026-11-04 收窄独立复核 P1-A / P1-B

局部结论：前轮桌面P1-A/P1-B复核通过；未发现新的实质P1代码阻断。整个任务仍BLOCK/in_progress：既有P2全量hash成本和iOS/Windows/最低版本未验收范围不变。复用前轮完整规范阅读，重新读最新任务设计/实施修订、交接、所有P1源码与进程/定向/集成测试，没有再次扩散iOS研究或原生构建。

- P1-A：独立sqlite3连接BEGIN IMMEDIATE确实包住读合并/连续版本分配/flush/rename，reclaim同门；失败pending保留，发布后COMMIT失败时已存在JSON仍是下一次版本依据，不降版或重用。无持久用户态锁；同一SQLite文件使用OS/SQLite锁。独立4真实isolate实跑再次success400/errors0/records400/连续唯一版本。文件发布与SQLite提交不是文件系统原子事务；没有据此声称机器断电/每个窗口OS强杀全部做过。
- P1-B：认证持久prefix，GET从该偏移；安全响应后先登记candidate/owned集合，再排他创建、复制、复核prefix、ready后追加。复制失败分支在传输finally外，不能认证原tail。新增小故障注入在首个异步复制边界将candidate替换为目录，断言失败保留copying意图、原resume checkpoint/原tail及旧candidate引用；重试新candidate正常完成。不是复制中途OS强杀。
- ack：仍检查完整AppStore确认及同版本业务回执、当前取消/发布版本，普通paused/failed不清。集合先全校验再删；集成补充最后一个owned成员为外部路径时，前面的合法材料一件未删。既有恶意resume路径/symlink、旧ack、命令回归保留。不同文件实际删除仍可能发生IO失败后的部分完成，调用报错且未推进ack水位，可按登记集合幂等重试，不宣称跨文件删除原子。
- 最小修复：writeLocked回滚改为best-effort，避免ROLLBACK错误覆盖原出版/COMMIT异常；无新协议/SDK/原生修改。
- 独立审查升级进程脚本：只杀本checkout新启动精确PID；重开等待1秒后写手动标志再resume，远端同时断言请求相位[False,True]和实际Range；Dart逐字节核对完整2MiB，Python核对原tail hash/长度。读取既存geklcqgf证据与日志确认自动0、手动8192、原件65536不变；本轮没有重复SIGKILL实验。

本轮顺序独立命令：

- `flutter test third_party/background_downloader/test/execution_journal_race_test.dart --reporter expanded`：1项，400/400且0错误/丢失；`/tmp/downloader-recheck-race.log`。
- `flutter test third_party/background_downloader/test/execution_boundary_test.dart --reporter expanded`：最新22项通过（初始独立21项亦通过）；`/tmp/downloader-recheck-http.log`。
- `flutter test --reporter expanded`：48项通过；`/tmp/downloader-recheck-tests.log`。
- `XCODE_XCCONFIG_FILE=/tmp/downloader-host-build.xcconfig flutter test integration_test/plugin_engine_test.dart -d macos --reporter expanded`：1项真实macOS集成通过（仍有open returned1提示，实际测试通过）；`/tmp/downloader-recheck-integration.log`。
- `flutter analyze`：No issues；`/tmp/downloader-recheck-analyze.log`。
- `python3 /tmp/downloader-refresh-vendor-patch.py`：官方SHA核对，更新patch从全新归档重建295文件/14源码差异/1438行patch逐字节一致；`/tmp/downloader-recheck-patch.log`。
- `git diff --check`通过，暂存为空，task.json仍in_progress；未改用户.pi/agents/docs，未暂存/提交/归档。

仍保留：复制阶段OS强杀未额外执行；P2每秒全文件SHA-256累计O(n²)/大文件与暂停延迟；iOS私有resume安全/真机生命周期/材料释放；Windows实机与macOS10.15/iOS14最低版本。可向父代理交接局部修复事实用于规范同步，不可宣称整个子任务验收或归档。

## P2 修复计划（已实施并通过局部独立复核）

独立收窄复核已确认两项桌面 P1 通过；源设计和 frontend/plugin-engine.md 已同步已实现范围与未验收限制。仍按本任务修复 P2，不跳转/归档，不改变平台范围。

- [x] 使用固定块 SHA-256 链与有界尾部代替每秒/停止时全文件扫描，保留 legacy SHA-256 prefix 校验。
- [x] 审查 transferBytes、materialMatches、forkCheckpoint、finally 及 resumeRef 所有调用方；flush 成功且字节/长度一致才持久新检查点。
- [x] 覆盖分块/旧格式/损坏/未提交 tail/写入失败，重复运行真实 HTTP 与 macOS 集成；做 >4GiB 实际传输与暂停成本证据，无法执行则明确原因。
- [x] 更新 vendor 可重放补丁、当前任务事实与独立复核；P2 实施后仍不借此接纳 iOS/Windows/最低版本。

## 2026-11-04 P2 增量认证实施与真实大文件证据

局部实施结果：移除桌面每秒/停止时全部历史文件SHA256扫描，改为固定1MiB块摘要链与有界尾部。整个子任务仍BLOCK/in_progress；本次不改PRD整项验收，不接纳iOS/Windows/最低版本。父代理独立P1复核已落盘的best-effort rollback、复制首异步边界故障/重试、owned集合最后非法项保护均保留。

### 实际改动与内部协议

- 新 `third_party/background_downloader/lib/src/desktop/material_digest.dart`；修改同目录 `isolate.dart`、`download_isolate.dart`。没有修改应用适配器、共享DTO/DownloadEngine/AppStore/schema、Swift、SDK/依赖版本、系统权限/配置/最低目标、源设计/frontend规范或其他子任务。
- 仅使用现有crypto公开SHA256 API。新materialHash=`bd-chain-sha256-v1:`+64字符小写hex；确切seed/block/end域分离、固定块、uint64BE总长度与tail构造已写task design.md。snapshot不消费运行状态；持有固定1MiB Uint8List及32字节链，没有随文件增长的proof数组或持久hash序列。旧无前缀64字符普通SHA256仍从磁盘校验，并在同一次读取重建新状态；未知版本拒绝，resumeRef仍为不透明引用。
- 新下载沿output.add成功写入提交队列的字节维护状态；周期checkpoint在flush成功后用stat核对实际长度、字节计数和digest.length完全相等，再一起持久offset/hash。停止等待close成功后以运行状态/stat落库，不重读文件。flush/close/长度失败保留上次认证检查点/材料，失败checkpoint标记禁止finally补认证。EOF和完成复制前flush失败也禁止提升检查点。
- 恢复仍实际读取磁盘prefix校验；安全GET后重建当前摘要状态。fork复制意图、candidate排他创建、原tail保留、复制失败不进入传输finally、owned集合确认释放未放宽。恢复/复制为常数次O(n)读取，周期与停止不读历史文件。非适配器上游无journal任务仍按既有恢复边界重建prefix，没有为本任务强制其具备日志。
- 新测试 `vendor/test/material_digest_test.dart`（4项）、`vendor/test/large_download_checkpoint_test.dart`（显式可选大文件），扩展既有 `execution_boundary_test.dart` 将6类tail场景同时覆盖legacy和v1，HTTP总28项。大文件测试不在应用默认test/目录，避免默认48基础每次传输4GiB。更新vendor PATCHES.md/downloader.patch、本任务design.md/implement.md。无依赖解析/生成注册文件变更。

### 顺序运行命令与日志

| 命令 | 实际结果 | 原始日志 |
| --- | --- | --- |
| `flutter analyze` | 最终No issues found | `/tmp/downloader-p2-analyze.log` |
| `flutter test --reporter expanded` | 基础48项通过 | `/tmp/downloader-p2-tests.log` |
| `flutter test third_party/background_downloader/test/material_digest_test.dart third_party/background_downloader/test/execution_boundary_test.dart third_party/background_downloader/test/execution_journal_race_test.dart --reporter expanded` | 33项通过：摘要4+HTTP28+竞争1；竞争400成功/400版本/0错误0丢失 | `/tmp/downloader-p2-focused.log` |
| `XCODE_XCCONFIG_FILE=/tmp/downloader-host-build.xcconfig flutter test integration_test/plugin_engine_test.dart -d macos --reporter expanded` | 真实macOS/SQLite集成1项通过，保留既有全部P1断言；foreground open returned1提示仍在但测试实际执行通过 | `/tmp/downloader-p2-integration.log` |
| `flutter test third_party/background_downloader/test/large_download_checkpoint_test.dart --reporter expanded` | 真实>4GiB HTTP/文件执行1项通过 | `/tmp/downloader-p2-large.log` |
| `python3 /tmp/downloader-refresh-vendor-patch.py` | 固定归档hash校验、全新归档应用patch后逐文件一致 | `/tmp/downloader-p2-patch.log`（最终数量见日志） |

所有Flutter命令顺序运行，没有并行Flutter构建；大文件测试后台启动仅为保持进度沟通，完成前没有启动另一Flutter命令。没有重跑iOS/release或无关平台；macOS仍只使用既有host override12/15，仓库10.15/14不变。执行git diff --check通过、暂存为空；对父代理checkpoint protected.json逐项SHA256校验，用户.pi/agents两文件+docs七图共9项完全不变。

### 最终真实 >4GiB 指标与证据界限

最终 `/tmp/downloader-p2-large.log` 输出：`bytes=4303945728 served=4304142336 transferMs=28621 pauseMs=8 checkpointMicros=6184 diskRebuildMs=26575 rss=127139840 peakRss=372981760 digestBufferBytes=1048576 contentVerified=4303945728`，测试总耗时约82秒。
实际HTTP循环发送64KiB确定性内容，真正写入非稀疏私有文件；当生产字节checkpoint超过4GiB后触发暂停。文件实际长度/持久offset均4303945728（严格大于4294967296）；发送但尚未消费的网络字节不冒充下载offset。传输约28.621秒，暂停请求至生产路径实际停止并落持久paused约8毫秒；在同一大文件上调用生产flush/stat/digest/journal检查点6.184毫秒，不包含磁盘历史读取。
测试随后逐64KiB从磁盘核验每块内容SHA256，累计contentVerified精确等于offset，再从实际磁盘独立线性重建v1摘要并验证持久值（约26.575秒）。这两次验证读是显式测试/恢复校验，不是生产周期或停止扫描。摘要只持1MiB尾部/32字节链，HTTP及内容核验块64KiB，无全文件缓冲；RSS为当时127139840、进程峰值372981760字节，峰值含Flutter测试运行时/编译及HTTP缓冲，不能宣称整个进程只占1MiB。
唯一私有测试目录 `/var/folders/gf/v79lfxb56kn2yhvdvyvtm6_80000gn/T/download-real-4gib-MHrDcs` 在finally仅清理本测试创建内容，没有删除旧诊断或用户材料；原始日志保留。前一次同类试跑亦通过（4314759168字节/29.668秒/暂停37ms/检查点20.622ms），最终结论以最终日志为准。

### 测试覆盖与仍未验收

摘要4项覆盖空/1字节/1MiB前后/多块边界、不同网络切片、重复snapshot继续add一致；legacy/v1磁盘prefix与未提交tail、篡改、未知版本；flush/长度错误旧认证checkpoint不变；production checkpoint测试只允许flush/stat、禁止历史openRead。HTTP28项保留全部原22项并给6种tail场景增加新摘要格式；包括安全206/错误响应原件不变、首复制异步边界故障和安全重试。macOS真实集成保留持久/确认/恶意材料集合/worker等断言。
本轮解决周期/停止累计O(n²)扫描成本，并提供本主机实际>4GiB证据；仍待父代理独立check。没有宣称所有IO故障或机器断电窗口均实测：flush/length注入为生产检查点单元路径，close错误由代码传播与保留旧checkpoint控制，未单独做真实设备磁盘故障。复制中途OS强杀仍未额外执行。iOS私有resume未经确认从零行为、材料释放/临时文件失败/真机生命周期，Windows实机、macOS10.15/iOS14最低版本仍未验收；整个任务保持BLOCK。未暂存/提交/归档/改task.json。

## 2026-11-04 P2 收窄独立复核

局部结论：P2周期/停止全历史SHA扫描问题复核通过，未发现新增P1或待修的本范围实质代码缺陷。整个任务仍BLOCK/in_progress；不以本地性能或criterion-1报告替代PRD/平台验收。复用前轮完整源规范/DTO/AppStore阅读，重新读取最新6条check.jsonl、frontend/plugin-engine.md完整88行、PRD及任务P2设计/实施、全部新摘要与相关生产/测试代码及46行实施报告。frontend/source仍记P2待修由父代理后续同步，本轮未修改这些规范。

- 固定块、seed/block/end域分离与uint64BE长度核对正确；snapshot不消费状态，固定1MiB尾部+32字节链没有随文件增长列表。legacy普通SHA同一次磁盘读取认证并构建v1；未知/坏格式拒绝，恢复没有跳过实际磁盘prefix校验。
- 新任务清空digest/material/checkpointFailed；output.add后的运行摘要只在flush成功且实际长度/计数/digest长度一致时提交。周期/停止无openRead；停止等close成功，flush/close/长度失败跳过finally补认证，原checkpoint/tail/owned引用保留。EOF flush与完成copy前flush失败也有失败门。恢复线性校验及复制仍保留，未放宽安全GET或ack释放。
- 本轮只新增必要测试：Python hashlib独立生成6个固定向量（0/1/1MiB±1/1MiB/3MiB+17），避免同生产算法自证；没有修改生产摘要/停止代码。
- 独立真实大文件：bytes=4315807744，served=4437573632，transferMs=29649，pauseMs=21，checkpointMicros=15028，diskRebuildMs=34306，rss=100433920，peakRss=442318848，digestBufferBytes=1048576，contentVerified=4315807744；实际HTTP/生产desktop函数/非稀疏文件，逐块核验全部落盘内容，再磁盘重建摘要通过。served未消费部分不计入offset。
- 21ms从同测试进程收到>4GiB生产checkpoint事件后设置暂停标志开始，到生产函数实际停止/回执返回；非UI→Repository→引擎端到端保证。额外checkpoint计时包含文件sink创建/关闭与flush/stat/digest/journal；独立重建34.3s是测试核验读，不是生产周期/停止扫描。RSS含Flutter/HTTP/测试分配，不能声称整个进程仅1MiB。

本轮Flutter顺序执行（大文件后台运行期间没有启动其他Flutter）：

| 命令 | 结果 | 日志 |
| --- | --- | --- |
| `flutter test third_party/background_downloader/test/material_digest_test.dart third_party/background_downloader/test/execution_boundary_test.dart third_party/background_downloader/test/execution_journal_race_test.dart --reporter expanded` | 初始33通过，增加独立向量后34通过；5摘要+28HTTP+1竞争400/400 | `/tmp/downloader-p2-check-focused.log` |
| `flutter test third_party/background_downloader/test/large_download_checkpoint_test.dart --reporter expanded` | 实际>4GiB，1项通过，指标如上 | `/tmp/downloader-p2-check-large.log` |
| `flutter test --reporter expanded` | 48通过 | `/tmp/downloader-p2-check-tests.log` |
| `flutter analyze` | No issues | `/tmp/downloader-p2-check-analyze.log` |
| `XCODE_XCCONFIG_FILE=/tmp/downloader-host-build.xcconfig flutter test integration_test/plugin_engine_test.dart -d macos --reporter expanded` | 真实macOS/SQLite 1项通过；仍有open returned1提示但实际测试通过 | `/tmp/downloader-p2-check-integration.log` |
| `python3 /tmp/downloader-refresh-vendor-patch.py` | 官方SHA及全新归档应用后298文件逐字节一致，17源码差异/1990行patch | `/tmp/downloader-p2-check-patch.log` |

未新增平台验收：iOS私有未经确认从零恢复、完成临时文件失败保全、真机生命周期/材料释放；Windows实机、macOS10.15/iOS14最低兼容；复制阶段OS强杀/断电及真实设备close/磁盘故障仍未额外执行。macOS仅用既有临时12/15 host override，仓库目标未改。用户保护9项SHA核对一致，暂存为空，未stage/commit/archive/改task.json。实际本轮修改仅material_digest_test.dart、vendor PATCHES/downloader.patch及本任务implement.md；完整报告交宿主指定路径，停止写入。

## 父代理同步与后续执行边界

已读取 P2 独立报告，按其 34 项定向、48 项基础、真实 macOS 集成和 4,315,807,744 字节大文件实测同步源设计与 frontend 插件/架构规范；周期/停止扫描成本列为已修复。既有历史实施记录保留原轮次计数，不改写为最终轮次。2026-11-04 本机设备发现仅有 macOS 和 Chrome，没有已连接的 iOS/Android 设备，也没有本机 Windows 验证环境；iOS 私有恢复与材料/生命周期、Windows 及最低版本门槛继续未验收，PRD 整项验收框不勾选。

按用户已授权直接提交并继续的规则，审查后的实现、补丁和规范允许保存为工作检查点提交；这不代表插件任务完成，不执行归档或完成日志。父任务既定依赖允许 AndroidEngine 仅依赖已完成的 contracts-store，在插件无活动写入者后独立推进；切换当前任务时保留本插件任务 in_progress/BLOCK，Repository/UI 仍等待引擎及文件安全门槛。

工作代码已保存为 `1cec368`（feat: add plugin engine and safe desktop recovery），不是完成提交。首次将上游归档纳入 Git 时，整包 cached whitespace 检查会报告原有尾随空白及 unified patch 的上下文空行；保持上游字节和补丁可重放性，不批量格式化。应用/配置 staged 差异检查通过；另外对固定 9.5.9 基线逐文件执行 no-index whitespace 检查，18 个实际差异文件（含 PATCHES.md，不含补丁文本本身）无新增空白问题。规范/链接/七段契约/49 项引用/上下文与源 SQL 对实现表结构核对通过，9 个保护文件 hash 不变。
