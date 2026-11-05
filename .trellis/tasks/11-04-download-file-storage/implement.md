# 文件适配实施计划

## 依赖与顺序

contracts-store 已通过，两个 Engine 日志/回执可接入后才能完整验收；不在本任务重写下载器。

- [ ] 逐平台核对默认位置、选择器/授权和能力；先证明默认目录必需行为。
- [ ] 接入唯一持久发布写入方，创建前保存 PublishOperation，补充阶段、身份和错误的载荷校验。
- [ ] 实现持久暂存到用户目录的流式发布、并发不覆盖命名、关闭/完整性验证和本地发布重试。
- [ ] 实现 recoverPublication 的五种结果；uncertain/授权失败不重复新建或猜测删除。
- [ ] 实现归属清理、完成文件删除和系统打开，包括 Android APK 授权交接与平台无处理程序反馈。
- [ ] 对各阶段中断、提供方身份变化和错误场景做平台集成测试并保留证据。

## 检查

flutter analyze、相关 flutter test 和原生/平台测试。四平台默认目录及至少一个平台支持的自选位置必须真实写入/重开；Android 测 MediaStore/SAF，Apple 测 sandbox/bookmark/外部提供方，Windows 测 Known Folder 和锁定文件。

故障注入点：prepared/creating、创建成功但句柄未保存、copying、最终操作完成但 published 未保存。断言只复用已证明归属的目标或返回 uncertain，不创建第二项；同名外来文件不被覆盖/认领/删除。验证双份空间不足、授权撤销、并发重名、取消重试、文件被外部删除和无处理程序。

## 停点与回滚

测试能编译不等于目标提供方支持；无法验证身份的目录明确记录限制，不擅自更换任务目标。保留原暂存、操作日志和用户文件，不能通过清空目录使测试通过。

## 激活与实现边界（2026-11-05）

用户已要求 Android 实机测试由其负责，优先完善其余功能；父任务已记录该推进调整。现有引擎持久日志/回执生产边界可供接入，Android 与插件平台未验收事实继续保留；本任务直接进入实施，不等待 Android 设备矩阵。先完成可被 Repository 使用的真实 FileStorage、持久发布恢复和平台目录/打开接线，复用现有 DTO/引擎日志，不重写下载器。实现后独立检查、同步规范并按既有授权提交；不得把能力错误或测试替身当默认目录实现。

## 2026-11-05 实现与收尾证据（部分交付，未完成任务验收）

已提供真实生产入口：platformFileStorage/defaultDownloadDirectory、NativeFileStorage、执行侧 SqlitePublicationJournal、PluginEngine 发布源授权/完成回执/取消门控；Android FileStorageChannel、ExecutionJournal 发布授权/回执/清理前门控；Apple 与 Windows 的原生目录、选择授权、发布、恢复、删除、打开接线。共享 DTO/API、AppStore 四表及网络/停止/恢复核心未改，没有新增依赖。保护清单10个文件（.pi及docs）与超时检查点的SHA-256全部一致，未暂存/提交。缺失的 .trellis/spec/guides 已记录；已按任务manifest及trellis-before-dev加载规范。

本轮按顺序完成以下 Flutter 检查，退出码均为0；日志为 /tmp/storage-final-<名称>.log，退出码单独保存为同名.exit：

- analyze：`flutter analyze`，无问题。
- unit：`flutter test`，102项通过。
- native：`XCODE_XCCONFIG_FILE=/tmp/storage-host.xcconfig flutter test integration_test/file_storage_test.dart -d macos`，9项通过。真实默认Downloads/Downloader、SQLite、并发同名不覆盖、完整字节/close、源保留、create返回丢失uncertain、最终操作返回丢失与回执补存、外来替换/symlink、缺失文件/未知日志版本，以及新增取消清理/cleaned提交失败/已published拒删/队列串行。故障注入在真实原生调用后抛错，没有使用fake文件系统作为平台证据。
- engine：相同临时host override运行 `flutter test integration_test/file_storage_engine_test.dart -d macos`，4项通过。真实HTTP→PluginEngine→发布→completed回执→重开幂等，另3项为create未知/copy已知/无发布的原cancel重放。每个case只产生1次GET，取消前后完整源逐字节相同；已published清理拒绝。

原生检查：

- Android：`JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew :app:compileDebugKotlin :app:testDebugUnitTest :app:compileDebugAndroidTestKotlin`，最新退出0，JVM XML统计93项、失败/错误/跳过均0；包含最新URI无identity保守恢复与已公开条目避免重复制修正。未运行任何Android设备矩阵；93项主要为原引擎回归，不冒充新增MediaStore/SAF运行覆盖。日志 /tmp/storage-final-android.log。
- macOS：本轮9+4真实集成都重建了当前原生源码；仅临时host12.0。此前直接xcodebuild host12也成功；仓库10.15未提高，当前Xcode不支持10.15的问题未重复实验。
- iOS：`xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug -sdk iphoneos -derivedDataPath /tmp/storage-ios-derived IPHONEOS_DEPLOYMENT_TARGET=15.0 CODE_SIGNING_ALLOWED=NO build`，最新退出0，日志 /tmp/storage-final-ios-host.log；仅当前SDK、临时host15无签名编译，仓库14及设备/提供方未验收。
- Windows：无Windows SDK/运行环境，未构建，不把macOS结果作为Windows证据。
- 初轮曾因Swift十进制0600权限值导致复制失败，已修为0o600；上述当前真实集成通过。Android初次shell使用JVM8失败，后续明确JBR执行通过；不隐藏早期环境失败。

### 历史收尾余项（由后续独立检查与 completed 释放章节逐项更新）

1. 当时完整源释放未闭合；当前已实现Plugin v2/Android v8的completed显式ack释放，最新独立证据见文末，Repository协调仍待接线。
2. 当时Windows同步HandleCall阻塞UI；当前已改窗口持有worker和回复队列，handle不覆盖发布仅源码修复，仍无Windows环境构建运行。
3. 当时Apple linkat/路径unlink及Windows路径发布存在竞态；当前Apple改fd/O_EXCL、未知最终identity uncertain，Windows改核验handle发布。Apple/SAF现存目标删除安全拒绝及用户目录临时副本保留仍为功能缺口。
4. Android MediaStore/SAF的新建/身份/并发及拒绝分支没有本轮提供方自动化运行证据；已核对系统源码并编译，但尚需定向自动化断言，实机由用户负责。URI无identity时返回uncertain而非补建，原源保留。
5. 自选目录跨进程bookmark/SAF持久授权、授权撤销/陈旧bookmark处理、系统成功打开/APK安装交接、无处理程序、磁盘不足、Windows锁定、Apple外部提供方不可用没有完整实际覆盖；不勾选PRD全部验收。
6. 清理/回执底层异常到结构化错误及错误持久化尚需一次完整边界复核（部分原生/回执异常只留下阶段，未保证每种错误都落日志）。

当前下一步以文末余项和[文件契约](../../spec/frontend/file-storage.md)为准。Repository可按factory、completed同事务ack与cleanup→原cancel重放协议继续接入，不能把完整任务标完成；无需Android矩阵阻塞其他功能。本历史检查点未提交/归档。

## 独立源码检查（2026-11-05，任务仍 in_progress）

本节替代前节的旧安全/线程描述。已修：Windows窗口持有串行worker与主线程结果队列，析构join后释放messenger；发布用验证源handle的FileRenameInfo且ReplaceIfExists=false。Apple发布改为核验源fd→O_EXCL新最终fd流复制，落独立最终identity；最终创建结果未取得/持久前丢失则uncertain，不能再建第二项。Apple现存目标cleanup/delete及SAF路径documentId删除安全拒绝，绝不通过检查后路径unlink删除外来替换；保留用户目录临时副本及私有完整源。这是明确的功能阻断而非通过全部清理验收。

早期同根PluginEngine共用队列/execution.lock现已由文末独立SQLite异步门替换；双Engine copy屏障竞争仍通过。清理/删除保存结构化DownloadFailure，诊断落库失败不覆盖原始异常；Android同样保持首异常并追加suppressed诊断。

独立证据写至 /Users/wang/.pi/agent/sessions/--Volumes-exstorge-Flutter-downloader--/subagent-artifacts/outputs/b100934f-a6b9-452a-9e99-23de21bd22c4/download-file-storage-independent-check.md，当前日志 /tmp/storage-independent-*.log 与 *.exit。真实文件9项、引擎4项（加入跨实例屏障）、102项Dart、93项JVM均按受影响范围重新执行；Windows没有SDK，不宣称构建。Android以JBR、-Pandroid.builder.sdkDownload=false和--rerun-tasks执行compileDebugKotlin/testDebugUnitTest/compileDebugAndroidTestKotlin，97个Gradle任务实际执行，未运行模拟器/矩阵。macOS临时host12、iOS临时host15仅证明当前host编译/运行。最终exit及平台边界以独立报告为准。

本次源码检查当时余项中的completed私有源释放和跨isolate门，已由后续章节局部闭合；Repository接线仍待完成。Apple/SAF现存目标正常删除、Windows环境、Android提供方、授权/空间/系统打开、iOS/最低版本及完整结构化异常边界继续阻断完整PRD。不勾选PRD/task.json，不等待Windows或Android实机阻塞其他开发。

## 本轮 completed ack 私有源释放（局部交付，PRD 仍 in_progress）

已接通 PluginEngine 与 Android 原生 acknowledge 的完整源释放生产路径，现有 resumeRef/releaseResumeRefs 承载 opaque 引用，不改共享 API/AppStore 四表。Plugin v2 与 Android v8 保留历史迁移；释放意图、逐成员 done 和最终确认分离持久化。Android 桥拒绝没有当前 completed/完整发布快照的显式释放。Plugin 完整源与旧 ownedMaterials/resumeData 成员一起回收，用户发布文件/用户目录临时副本保留。普通确认/旧确认/未提交或路径伪造确认不删源。

macOS 真实引擎集成已加入 AppStore 同事务 completed+完整 ack、普通 ack 保源、旧/伪造/未提交 ack 拒绝、删除后 done 保存失败且旧成员尚在、重开续删与再次重开幂等、已发布文件字节保留、GET=1。另加执行日志 v1→v2/迁移失败/未知版本保留历史回归。原生 Android 追加 completed ack 故障重放与 v7→v8/失败保留 instrumentation 夹具，只编译未设备运行；旧20个夹具的 v7 期望及模拟降级新表清理更新为 v8。

串行门现使用异步获取的独立 SQLite 写事务，新增真实跨 isolate 竞争及同 isolate 异步等待测试。Apple/SAF正常删除仍未闭合，最小方案和不可承诺的恶意逐 syscall 边界写入 design 末节。Windows/iOS/Android设备及最低版本不新增通过声明。实际命令和case数量以本轮输出报告及 /tmp/storage-release-*.log、*.exit 为准；完整PRD不勾选、不提交、不归档，父代理独立检查和spec sync后再决定提交。

## completed 释放独立复核（局部 PASS，完整任务 BLOCK）

独立检查修复 Plugin completed 释放两项：晚成员为目录等非普通类型时整集合先验拒绝，不先删完整源；等待 idle/目录查询及成员删除期间重读完整已提交 ack、当前回执及业务 completed/发布身份，取消竞争不继续释放。真实 HTTP 集成新增目录替换零删除、等待期间业务 cancelling 零删除、全部删除/done 后最终 ack 插入失败并重开重放断言。SQLite gate 用嵌套 finally 保证回滚异常也关闭连接，并增加 owner 异步异常后再取锁成功回归。未降低 Apple/SAF 用户目标删除信任边界。

独立日志 /tmp/storage-check-release-*.log/.exit：focused 57项（55桥+2真实锁）、macOS engine 5项、macOS native 9项、analyze 均 exit0；使用临时 host12，不证明最低10.15。Android 从 android 目录以 JBR 和 -Pandroid.builder.sdkDownload=false 编译 Kotlin/unit/androidTest exit0，97任务4执行93 UP-TO-DATE（unit 为缓存）；另对 :app:testDebugUnitTest --rerun-tasks 强制重跑 exit0、91任务实际执行，6份XML共93项且失败/错误/跳过0。22项instrumentation只编译，未运行设备。首次误在仓库根找 gradlew 返回127，改到android目录后通过；不把失败算通过。

完整PRD仍未勾选：Apple/SAF现存目标/临时副本正常删除、Windows真实环境、Android提供方及设备矩阵、iOS/最低版本、持久授权撤销/外部提供方/空间不足/系统打开及APK、Repository接线和结构化异常全边界仍待完成。核对611文件快照及tracked.diff：变化限授权清单，.pi/docs保护不变，HEAD6b1f4cb、暂存空。快照之外的ExecutionJournalTest变化仅自动格式化，没有新增设备通过声明；保留所有既有dirty。未stage/commit/push/archive，未启动设备。

## 正式规范同步检查点

已将实际factory/default目录、执行侧唯一发布日志、Plugin v2/Android v8迁移、completed同事务完整ack及释放重放、异步SQLite门与平台缺口同步到[文件契约](../../spec/frontend/file-storage.md)，并更新frontend索引/架构/持久化/插件规范及源设计。任务manifest加入真实新规范引用。此轮仅文档检查，不重跑产品测试；独立报告证据沿用上文精确数量，PRD仍BLOCK/in_progress。
