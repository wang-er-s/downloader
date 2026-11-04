# Android 引擎设计

## 接口与所有权

依赖 contracts-store。使用[源设计](../../../.agents/specs/download-manager/design.md)中 downloader/android_engine 命令通道及事件通道、protocolVersion=1 和 EngineCommand/Receipt/Snapshot/Ack。不把 Repository 变成原生专用协议。

Kotlin 前台 dataSync 服务持有网络、检查点和独立执行日志；共享 AppStore 不被原生直接写入。MainActivity 只处理通道和系统结果，不持有执行生命周期。复用 Android/Java 标准网络与持久化能力，不新增完整网络框架。

## 执行与协议

inspect 无副作用并返回原生当前会话；命令以固定执行键/commandId/期望版本校验。进程级 ownerSessionId 用于拒绝旧 Intent，Activity 重建不换成重启下载。幂等结果、暂停/终态回执和材料引用持久提交后再交付 Dart，确认后按引用释放。

流式 HTTP/HTTPS、重定向校验和 64 位计数；续传实际响应进入写入前校验 206、Content-Range 和验证器。失败保留材料。START_NOT_STICKY、无 boot 自动下载、无自动重试；系统超时及时停止并异步保存，不在 onTimeout 主线程等待网络。

## 配置与兼容

按实际 target 36 核验 INTERNET、前台服务/类型及通知权限、exported=false、cleartext 与 HTTPS 验证。候选最低 API 29 沿用已审核设计；若 SDK/依赖要求调整先报告。不可通过降 target、全盘权限或后台启动绕过系统限制。

## 文件边界与回滚

仅写应用持久暂存；预留同一执行日志保存 PublishOperation，file-storage 接入后才能发布用户目标。协议和原生调用方一起改，回滚不清日志或业务数据，不编辑生成注册文件。

## 首轮协议/日志检查点（2026-11-04，非完整引擎）

已接入 MainActivity 的 MethodChannel/EventChannel，进程对象持有随机会话和串行通道队列，Activity detach 只解除监听。inspect 返回 protocolVersion=1、当前会话、sequence=0 与日志回执；当前没有 worker/事件生产者。ack 只推进匹配完整执行键的已有回执高水位，超前确认拒绝；所有显式材料释放暂拒绝 materialReleaseUnavailable，不删除材料。传输方法解析命令后明确拒绝 transferUnavailable，旧会话拒绝 staleSession；尚未实现 Dart AndroidEngine，不能当作完整 DownloadEngine 调用。enqueue 的请求扩展约定为顶层扁平 command + input=EngineTask.toJson()，嵌套 key 必须匹配。

独立 android_execution_v1.db 使用 Android SQLiteOpenHelper，保存 executions/commands/receipts；执行登记和未知结果、不可变回执分配与命令结果、ack 更新分别在真实 SQLite 写事务中串行提交。inspect 非破坏，保留最新及未确认历史；本轮连已确认历史也保守留库。命令重复同载荷回放、不同载荷拒绝，NULL 结果拒绝自动重试。失败保留原始异常，回滚异常附加到原异常；不删库重建，不打开 AppStore。恢复引用仅记录在不可变回执中；实际材料归属登记、清理、发布扩展及完整失败回执需随 worker 下一轮实现。

当前原生日志不具备核验 AppStore 业务已提交的能力：ack 是调用方提交后的可信边界，Repository 必须先完成 AppStore 同事务业务/确认提交；本轮拒绝全部释放引用，避免在该边界未接入前删除材料。没有前台服务、HTTP、自动传输、暂停/取消成功路径。

## Dart 桥接检查点（2026-11-04，传输仍未接入）

新增 `AndroidEngine.open(store: ...)` 实现现有 DownloadEngine；仅 Android 可打开，`isAndroid` 为最小主机测试注入。监听既有事件通道时显式传 protocolVersion=1，命令显式映射扁平执行键/commandId/会话/期望版本；enqueue 的 input 保留完整 EngineTask JSON。不会生成或重绑命令身份，也不会在打开、inspect、重连或 close 时自动 enqueue/resume/retry。close 仅释放 Dart 事件订阅。inspect 严格使用共享 DTO 解析，空快照保留会话，未知版本、错误类型与初始读取错误均失败，不伪造空集合。首次业务订阅前缓冲事件和错误；事件拒绝非递增序号和未由显式 inspect 确认的会话变化。显式 inspect 可同步当前会话/序号，同会话不降低序号，迟到旧 inspect 不覆盖较新同步；序号缺口保留原值供 Repository 对齐。

ack 先在真实 AppStore 短事务读取并核对完整持久 ReceiptAck，不能把 commitReceipt=false 或调用参数当作提交证明；若现存业务任务的同执行回执版本相同，再非破坏 inspect 核对完整回执内容（缺版本也拒绝）。inspect 让出执行权后再次读取持久确认行和业务任务，对现存同版本完整回执重新比较，防止确认行或同确认行下的业务回执期间被替换。较新业务回执/已移除任务按实际留存确认行重放，绝不删除任务或确认行。材料释放原样交给原生校验，当前 materialReleaseUnavailable 仍传播，Dart 无本地文件释放路径。

平台与解析错误封装为 AndroidEngineException.failure（稳定 DownloadFailure）；仅放行已知结构化 reason，不转发原始 PlatformException 消息、诊断路径或任意 details；业务确认读取异常返回 persistenceFailure。该桥接和 host messenger fake 不证明原生执行成功：服务/HTTP/真实暂停取消、原生事件生产、真实 Android SQLite 与端到端设备验收继续 BLOCK。下一步仍是原生服务、HTTP 安全响应/持久暂存及设备矩阵，不勾完整 PRD 验收。

## HTTP 核心局部检查点（2026-11-04，未接服务）

新增内部 `HttpTransfer(Context.filesDir)` 构件，调用方必须是后续原生服务，绝不使用 Dart stagingLocation 作为根目录。当前 API 接收 File 仅为内部原生/真实 JVM 测试入口；拒绝非 canonical 根、symlink 暂存目录和根别名，依赖 Android 私有 sandbox 排除同权限恶意 native 写入者，不声称抵御同 UID 并发替换目录。随机 UUID 分配 `.facts`/`.part`，CREATE_NEW + NOFOLLOW_LINKS 排他创建，先 force 执行身份/意图，再创建 payload；保留所有原文件，不接受任何已有 partial 路径。facts 是诊断材料，不是 ExecutionJournal 恢复证明；目录项 fsync 与崩溃归属恢复未验收。

使用默认 HttpURLConnection/HTTPS TLS，identity、连接15s/读取30s；每跳重新校验无认证 http/https，拒绝 fragment/非法 port，至多10跳和 visited 检测。只接受初次200；非200、编码、长度和IO错误保留真实 cause 与 material。64位累计、未知total=null，实际写入后发单调时间样本；进度force记录最多每秒，SHA-256仅随写入增量更新，不反复扫描。已知长度EOF不匹配拒绝 staged；output force/close与facts force/close失败均不能返回成功。完整结果只称 staged，绝不称 completed/已发布。

Stop.request(PAUSE/CANCEL)仅请求并disconnect；调用者须等待 run 真正退出，文件关闭及终态facts成功后才能提交回执。取消暂保留材料，不等于取消清理完成；后续Service需串行协调命令、停止与journal回执，并在明确归属释放后才对外完成cancel。网络读被停止中断可形成停止结果，输入close、文件/检查点错误仍传播，不能用finally认证失败检查点。输出关闭后固定一次终态停止原因，facts与返回结果使用同一快照；此边界之后到达的停止请求由后续Service按已完成的暂存结果与取消优先意图协调，不回改既有终态。

续传本轮明确 unsupported：resume() 返回 stateConflict/restartRequired，不打开或修改原件，不发HEAD/Range。完整安全GET/ETag/Content-Range/prefix认证与candidate恢复日志未实现；原生通道继续 transferUnavailable。Service、权限、事件/ExecutionJournal联动、恢复/清理和目标发布留后轮；此构件不得直接接为生产DownloadEngine。

## 材料安全门检查点（2026-11-04，Service仍未接通）

- 独立执行库升级到v2，保留原库名称及v1 executions/commands/receipts内容，仅新增materials：完整执行键、command_id、排他payload/facts路径。SQLiteOpenHelper事务内执行1→2迁移，未知版本拒绝，失败保留旧版本和历史，不删库重建。
- HttpTransfer构造现在必须显式提供onAllocation；运行前先调用该回调，成功返回后才CREATE_NEW facts/part并请求网络。生产内部入口为ExecutionJournal.newTransfer(command,session)，使用原生Context.filesDir及registerMaterials验证会话、完整命令载荷、pending结果、最新代次/期望版本、UUID双文件与私有父目录。命令必须已register；每命令只登记一次分配，已有意图不能授权重下。主机核心测试显式用no-op回调，仅诊断测试，不是生产恢复授权。
- 可审查内部调用链：register(command,session) → newTransfer(command,session).run(key,url,stop) → 事务登记材料 → 排他创建与真实HTTP/停止关闭屏障 → 调用方complete提交真实checkpoint。newTransfer本身不调度、不完成命令、不自动网络重试；它也不替代未来协调器当前进程用户授权令牌。
- inspectMaterials仅非破坏读取归属意图；无文件不推定可重新分配，有文件不推定可恢复/可删除。facts仍仅诊断。未实现目录fsync，崩溃可能丢失目录项；数据库意图存在不保证文件存在，未知孤儿保留，不能猜删除。
- 本检查点不接Service/通道；transferUnavailable、材料释放拒绝及resume restartRequired保持。尚缺多次worker回执分配/EngineEvent、当前进程队列授权、串行协调与两worker、暂停命令等待、持久取消优先及清理协议、重启waitingRecovery对齐、FGS权限/通知/timeout与设备证据。不得勾PRD或宣称前台服务已完成。

## 材料门独立复核补充（2026-11-04）

独立复核修复 newTransfer 原先只绑定 key、允许 run 替换 URL 的缺口：工厂深复制并重新解析完整命令，固定授权 URL，run 在创建目录前拒绝替换 URL；材料事务仍在延迟执行时核验 pending/当前代次/版本，重复调用同一工厂回调不能再次分配。补充主机 URL 替换零分配测试，以及 instrumentation 的输入变更隔离、同 worker 重用和迟到旧代次拒绝断言。后者仅编译，未在设备运行。

此门只保证分配事务当时的授权：登记提交与创建/网络之间仍需后续 Service 单执行协调队列，串行处理 stop 命令和终态；不能视作活动暂停、取消优先或重启恢复已验收。目录 fsync、prefix 认证、设备 SQLite/迁移故障实测均未完成；保留材料且无自动重试。独立 JVM 19项（协议5＋HTTP14）与 AndroidTest Kotlin 编译通过；PRD保持未勾选。

## Service 生命周期扩展（本轮实施）

独立日志v3新增worker_authorizations，以enqueue command为主键保存session、完整执行归属、一次性分配状态、当前回执版本与停止意图。接受enqueue的命令结果与worker授权分开：接受原子保存queued及授权；后续分配须核对完整命令、当前进程session、当前执行/代次、授权版本、无stop且未消费，再消费授权并登记材料。worker回执推进授权版本，不修改不可变enqueue结果；pause/cancel另登记命令与持久stop意图，最终回执与其命令结果共同提交。旧库pending命令保持原材料门，不自动升级为worker授权。

进程串行协调队列排序调度/stop/worker终态；独立双worker池执行HTTP，分配和进度经队列落库。Service只消费当前进程显式enqueue产生的一次性启动令牌，Intent不含可重放命令；空/旧Intent不调度。pause等待真实run退出；cancel保持cancelling及cleanupFailure，材料不释放。安全续传、用户目录发布、受控清理仍拒绝，PRD保持未勾选。

## Service 扩展独立检查边界

worker事实、stop与pause结果现在在事务内完整核对命令/会话/执行键/最新代次/授权版本，取消stop不能回退为pause或发布；失败pause重放仍失败。事件订阅者失败不回滚持久操作，inspect可重放。ServiceReady前已停止的接受Future也有确定结束。具体socket/超时与队列持久错误采用类型分类，不匹配异常字符串。

本轮Service仍BLOCK：idle stopService和新enqueue/旧Service.onDestroy存在竞争；token消费到主线程startForeground之间缺启动授权代次重验；需要实例化生命周期握手。timeout/destroy停止信号仍受日志队列和HttpTransfer同步disconnect约束，终态落库失败仍缺保存恢复入口。HTTP非200/响应校验无类型IOException的精确分类须后续核心扩展。28项JVM及100项Dart通过不替代10项仅编译的SQLite instrumentation和API29/30/33/35/36设备验收。完整PRD不勾选。

## 五项阻断修复方案（2026-11-04）

统一ServiceLifecycle管理当前进程token、实例及代次。同步短临界区跨主线程和协调队列重验实际启动/前台/worker授权，idle停止带代次且只stopSelf所属实例，destroy/timeout仅失效所属授权并立即发布停止标志。Stop以原子优先级发布CANCEL>PAUSE，disconnect独立执行且不持锁；不承诺平台连接立即中断。

终态保存失败保留已停止checkpoint及固定命令，不占worker槽；同一enqueue/pause命令的显式重试只补本地日志提交，inspect仍纯读取且不生成虚假版本。进程终止则仅以已落库事实为准。HttpTransfer按journal/network/HTTP validation/file阶段保留typed code和原cause，文件关闭失败不能认证暂停或暂存。

## 修复独立续审结论（2026-11-04）

A–E源码局部通过。实际startService/startForeground抛错时同步撤销grant，foreground失败不等待日志队列即可安排epoch约束的idle停止；timeout退休整个所属实例并无参stopSelf，避免旧startId遗留该实例的较新请求。持久cancel在终态补存失败期间仍按完整命令重放原cleanupFailure，不撤销取消意图、不隐式重新运行HTTP。新增失败启动/多start实例/取消重放回归，补存拒绝身份变化及同命令并发结果一致。

独立44项JVM、102项Dart及实际SDK编译/debug构建通过；11项SQLite instrumentation仅编译。没有剩余本轮源码阻断，设备Service回调/IPC延迟、SQLite、权限与timeout、强杀重开及平台矩阵仍BLOCK；安全续传、受控清理/发布、fsync和真实大文件未据此验收。完整PRD保持未勾选。

## 恢复材料安全门第一段（本轮内部设计）

本轮不开放对外resume调度。原生日志v4新增resume_checkpoints和recovery_operations，保留v1/v2/v3历史；生产newTransfer必须接入独立的after-force检查点回调，记录完整命令/执行键/原生源文件、当前回执版本、认证offset、total、最终URL、强ETag和明确版本的prefix摘要。进度onSample仍不认证offset。无强ETag、旧facts或未知材料不生成可恢复声明。

摘要使用64KiB固定块、带domain分隔的SHA256链及有界tail快照（native-prefix-v1-65536），不克隆provider状态、不冒充普通SHA256；恢复线性读取认证prefix，每64KiB检查Stop。内部ResumeTransfer只接原生日志读出的完整checkpoint，不接channel路径/URL。实际GET带Range/If-Range，响应206/ETag/Content-Range/长度/total全部核验后，先持久候选意图，再CREATE_NEW+NOFOLLOW复制并重验prefix及写入candidate；原源文件永不截断。短EOF不认证candidate为完整，不自动清理旧材料。用户resume协调授权、受控清理/发布另轮闭合，当前通道仍restartRequired。

第一段实现补充：v4另有recovery_attempts一次性请求意图，先于实际GET提交，结果不明不得同命令重发；candidate操作记录只在响应安全门通过后、输出创建前提交。恢复core可由内部newRecovery固定命令/ref构建，但尚无公共调度调用方。已force源检查点和私有candidate均保留；candidate本轮不提升为新的恢复源，不提供失败候选自动继续/清理。对外resume仍restartRequired，完整worker/session/stop/receipt授权闭合另轮处理。独立58项主机JVM及14项instrumentation编译不替代设备验收。

独立复核补充：最终proof须等payload与facts均真实关闭成功，周期proof先双force；facts关闭失败只保留较早proof。持久cancel后不推进proof，同offset/算法/URL/total/ETag变化拒绝；工厂、GET前、候选登记和staged重验冻结owner、完整源worker与proof/current receipt版本，不由旧proof授权新事实。候选close失败不staged，认证中CANCEL不触发GET；首异常保留，typed disconnect关闭错误仅suppressed。独立摘要边界向量、真实HTTP/文件回归及SDK构建局部PASS，公开调度与设备验收仍BLOCK。

## 显式resume接线前置（本轮方案）

公开入口暂不解除restartRequired。完整接线须原子区分冻结source proof/version与新worker当前授权version，不能复用v4要求sourceproof=current的内部工厂直接开放。本轮先闭合恢复核心的真实停止和candidate认证：同一个Stop贯穿prefix认证/复制/网络，用户停止用明确内部Stopped事实而非资源restartRequired；candidate在既有operation归属下新增独立v5候选proof，周期payload/facts双force后认证、终态等两者真实close后认证。候选proof显式按恢复command/operation查询，不混入v4 source proof选择，不因此授权下一次网络。

新增候选proof本轮仅保留可核验的offset/算法/强ETag/URL/total/完整执行键与来源operation/固定source ref/version；不能假称已具备新worker或跨进程用户resume授权。若剩余时间不足以同时闭合接受事务/退休旧session/回执补存，保持公开拒绝并将这些列为最小下一步。

本轮检查点结果：v5只新增候选事实表（recovery_candidate_files预登记双文件、candidate_checkpoints冻结source与恢复command关联），不重写v4源材料门，也不选择候选作为公开current branch。ResumeTransfer区分真实Stopped与不安全资源，candidate周期双force/final双close证据可支撑下一内部core继续；公开worker接受/跨session退休/停止回执补存仍未闭合，保持resume拒绝。63项主机JVM和15项SQLite仅编译不改变平台BLOCK。

独立前置复核：70项JVM（协议5＋HTTP20＋协调器15＋生命周期7＋恢复23）、静态分析和debug APK通过，15项SQLite仅编译。Stopped不能遮蔽真实FILE关闭/NETWORK断连失败；final双close及proof回调后重读Stop，late CANCEL不proof/staged；等待头部和prefix复制后的断连停止用确定latch验证。内部Stopped.bytes仅诊断，不是下载增量或认证偏移。v5仅局部PASS，公开resume原目标未交付。下一轮需同时交付原子acceptResume冻结源版本N与新worker版本N+1、当前进程显式授权/旧授权退休、Coordinator真实恢复worker、stop/receipt/终态补存和确定current branch，不再以额外helper替代生产接线验收。

## 公开恢复生产接线（本轮v6设计）

acceptResume在同一事务核对真实Runtime session、完整命令/head/最新generation、原生input与非取消/非publishing状态，冻结选中branch的完整源proof和历史版本；queued回执和新worker授权与接受结果同时提交。v6用resume_sources冻结每个worker的source JSON及root ref，active_branches显式保存同执行当前已认证branch，retired_workers独立记录旧session授权退休，finished字段不伪造。Coordinator确认当前进程该执行无Work才调用接受；inspect/open不退休不调度。

复用同一Work/ServiceLifecycle/两worker池；enqueue运行HttpTransfer、resume运行ResumeTransfer。恢复工厂复用v5真实GET/candidate回调及文件门，另提供绑定新worker/head的validator，不放宽原v4内部工厂。candidate双force/双close后更新active branch，旧材料保留；停止、receipt、terminalSavePending与原worker统一。初始Stopped只用于停止事实，不使用诊断bytes。终态回执从已认证branch诚实提供resumeRef；publishing/cancelling不授予继续。

## v6 独立复核结论（2026-11-04）

公开 resume 生产源码局部 PASS；provider 502/EOF 中断后的恢复检查完成正式报告，不把中断当作通过或源码失败。审查修复持久 PAUSE/CANCEL 与迟到 staged 竞争：staged 事务重验持久 stop 并转 Stopped；持久 CANCEL 不认证新 proof。历史 finished worker 重放使用原 receipt 的派生恢复字段，仍精确比较完整非派生 checkpoint/worker/pause result，避免新 active branch 污染旧终态幂等。

Coordinator 真实 socket/file/core 回归已覆盖公开 pause→resume→再 pause/resume、prefix/copy 各 PAUSE/CANCEL、关闭/认证提交失败及持久 cancel 竞争。独立80项 JVM（5+20+25+7+23）、静态分析与 debug APK 通过；Dart 未改沿用前轮独立102项，18项 SQLite instrumentation 仅编译。完整任务保持 BLOCK/in_progress、PRD 不勾选；设备 SQLite/Service/权限/强杀重开与 API 矩阵、受控清理/发布、fsync及真实大文件仍待验证。下一步先闭合持久取消意图、所有归属材料的可重放受控释放与停止后清理，再进入 file-storage；不删除未知孤儿，不凭路径或普通 ack 授予删除。

## v7 显式取消与受控清理（本轮最小生产闭环）

取消独立于恢复 worker：Coordinator 在 Runtime 同一串行队列先调用 beginCancel，原子登记完整命令、cancelling 接受事实、全部原件/候选 UUID 双文件归属快照和 pending 清理操作，再请求 CANCEL。活动 Work 必须真实退出并完成终态日志保存后才调用清理；无 Work 的旧进程/paused/failed 只退休旧授权并执行本地清理，绝不创建网络 worker。清理期间串行排他，当前执行 cancelling 拒绝 resume。重开只读，只有相同完整 cancel 的显式重放恢复 pending 清理。

v7 新增 cancel_cleanups 与 cancel_cleanup_members，保留 v1–v6 所有行，DDL/版本沿用 SQLiteOpenHelper 原子迁移。commands.result 保留原不可变接受回执；cancel_cleanups.result 是首次实际停止、清理及终态提交成功后保存的不可变完成回执（仍用公共 cancelling 状态，error=null，绝不制造 completed）。瞬时清理失败不写完成结果，保留 pending/成员清单，显式重放可继续；历史 v6 已对外返回 cleanupFailure 的命令仍保留原失败语义，需新当前 session/版本 cancel 创建 v7 操作，不能改历史结果。

删除前整集合验证原生 canonical 私有根/父目录、UUID .part/.facts 配对、NOFOLLOW 普通文件及完整执行/来源归属；任一失败零删除。每成员删除后持久 done，已登记 missing 幂等，IO/持久失败保留未完意图，不宣称文件集合原子。清理完成后仍保留材料/证明历史行供诊断；持久 stop/retired 阻止迟到 callback 重新认证。

非空 ack 分支继续保守拒绝：当前接口没有可由原生日志验证的发布完成证明，且没有独立的确认重下业务意图字段；不能把普通 paused/failed 或任意旧 ack 当清新材料授权。原生显式 cancel 意图提供本轮唯一释放入口；Dart 真实 AppStore 提交核对保持，原生不访问业务库。真实设备/完整 PRD 仍 BLOCK。


## API37 SQLite runner 与夹具实际验证（2026-11-04）

本轮将无依赖Instrumentation runner改为标准逐case start/pass/failure状态及20项总数；单项失败继续运行，原stack与关闭/loopback异常保留。正常finish只表示runner结束，验收依赖Gradle case状态与XML，不能将adb shell退出0或0 tests当通过。后台loopback异常归属当前case并等待线程退出，避免未捕获异常中止后续测试。

生产授权门未改变：无worker的旧head命令仍先staleReceipt，取消checkpoint不从branch推导恢复能力；夹具分别改为现有门的精确错误并核对无副作用、显式传入Coordinator同款unsupported。网络sample没有固定read长度，测试达到8192/16384预定累计值才暂停，仍精确检查原offset及完整恢复断言。

emulator-5554 API37最终实际执行20项Android SQLite，XML为20/0失败/0错误/0跳过，v1-v7迁移、回滚、归属和清理均在真实Android SQLite上执行。证据/tmp/android-sqlite-runtime-final.log（Gradle退出0）、final-results.xml；真实失败second/third日志与XML保留。完整API29/30/33/35/36真机矩阵、Service/通道及其他PRD边界仍BLOCK，不能因API37模拟器局部PASS勾选完整验收。详见implement末节。
