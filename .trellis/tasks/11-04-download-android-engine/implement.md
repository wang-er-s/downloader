# Android 执行实施计划

## 前置

contracts-store 的模型和协议测试通过后激活；无需等待 PluginEngine，不与其同时写共享文件。

- [ ] 阅读 MainActivity、manifest、Gradle 及生成边界，确认最低 SDK/target 与 Java 配置。
- [ ] 实现会话握手、类型校验、稳定命令、原生日志及非破坏性 inspect/ack。
- [ ] 实现前台服务、持久暂存、HTTP/HTTPS 与重定向、未知总长字节及安全续传。
- [ ] 接入 AndroidEngine，暂停/取消等待真实停止并保存回执，断连不等于取消。
- [ ] 配置最小权限和服务，处理通知拒绝、后台启动与系统超时；不加自动启动下载路径。
- [ ] 进行协议、原生和设备故障测试，记录 file-storage 所需日志/发布扩展边界。

## 检查

flutter analyze、flutter test；在 android/ 下运行 ./gradlew :app:testDebugUnitTest，实际任务存在时执行相应 instrumentation 测试；flutter build apk --release 验证构建。release 当前 debug 签名只能作本地验证，不宣称完成分发签名。

受控 HTTP 服务核对 Range/ETag/字节和请求次数。设备矩阵覆盖 API 29/30/33/35/36：切后台、滑走 Activity、重连、强杀、重启、通知拒绝、超时。无用户操作重开后新请求为零；旧会话/旧代次/超前 ack 均无副作用。暂停回执和确认前后分别中断验证重放。

## 停点与回滚

不因单个模拟器通过宣称全部平台通过；缺设备记录未测，不能完成本任务验收。保留未完成日志和材料；协议变化同步 Dart、Kotlin、测试和源规范，不删库、不回退其他任务变更。

## 激活与本轮实施边界

2026-11-04 已按既有用户授权激活。contracts-store 已归档并通过 48 项基础测试；PluginEngine 的审查后代码与规范已保存为 1cec368、ec68fc8，插件仍 BLOCK/in_progress，没有归档。父任务明确本 Android 子任务不依赖 PluginEngine 平台验收，且插件写入者已经退出，保持一个工作区一个写入者。

为避免一次跨越全部原生生命周期而再次超时，首轮集中交付协议与独立执行日志的可测试检查点：先完整核对实际 DTO、调用方和 Android 工程，完成空 inspect 的会话握手、严格载荷/执行身份校验，以及原生持久回执、命令和确认的最小基础与回归。随后继续接入前台服务/传输和实际 Dart 适配，不将首轮检查点声称为完整 AndroidEngine；不以假网络执行、伪造暂停成功或吞掉未实现方法凑齐接口。

本机 Flutter 发现仅有 macOS/Chrome；可以检查已有 Android SDK/AVD 并执行真实编译与可运行测试，不将模拟器或缺设备标记成真机通过。不改用户 .pi/agents/docs、既有 PluginEngine/vendor、共享 DTO/AppStore/schema、Apple/Windows 配置，不自动更换 SDK 或依赖版本。子代理不暂存/提交/归档/修改 task.json；本轮交接后由父代理安排独立检查并继续剩余步骤。

## 首轮实际验证记录（2026-11-04）

- 前置已完整读取 implement.jsonl 六项、源设计570行、实际 DTO/DownloadEngine/AppStore 与调用方；单仓库 frontend 索引适用，`.trellis/spec/guides/index.md` 不存在，未创建占位。
- 已完成协议解析、MainActivity inspect/ack 接入、独立原生 SQLite 日志基础及五项 JVM 协议测试。三项真实 Android SQLite instrumentation 测试已添加：重开/重放/确认、身份/载荷/触发器回滚、跨连接竞争；未执行设备测试，不能记为持久化或并发验收通过。
- `flutter analyze` 通过，日志 `/tmp/android-engine-analyze.log`；相关 `flutter test test/features/downloads/contracts_test.dart test/shared/data/app_store_test.dart` 47项通过，日志 `/tmp/android-engine-flutter-test-retry.log`。第一次测试受工具50秒超时中止，重跑正常退出0。
- 现有 Android Studio JDK21 下 `./gradlew -Pandroid.builder.sdkDownload=false :app:testDebugUnitTest :app:compileDebugKotlin` 成功（91 tasks，2m47s）；五项原生JUnit测试通过，日志 `/tmp/android-engine-gradle-no-sdk-download.log`，XML在 `build/app/test-results/testDebugUnitTest/`。
- 现有 Kotlin 编译器结合 SDK36 android.jar、Flutter embedding 及 Lifecycle 实际编译 MainActivity、三类原生实现和 instrumentation 测试通过，日志 `/tmp/android-engine-native-compile-full.log`（成功为空）。独立执行五项纯JVM断言也通过 `/tmp/android-engine-jvm-direct.log`；首次独立JUnitCore缺Hamcrest，不作为通过证据，随后Gradle正常JUnit执行通过。
- 环境发现 SDK34/36/36.1、既有 AVD Pixel_10_Pro_XL（API37.1），adb无已连接设备。doctor报缺cmdline-tools及license未知，日志 `/tmp/android-engine-doctor.log`。未启动模拟器，不宣称API29/30/33/35/36设备通过。
- 构建副作用必须保留：首次默认Java8 Gradle wrapper下载后被工具超时中止；使用既有JDK21的首次Gradle在固定插件配置阶段自动安装Platform35，发现安装准备后终止，但105–109行证明安装已完成。未修改SDK版本配置、未移除该组件；后续显式禁用sdkDownload。原日志 `/tmp/android-engine-gradle.log`、`/tmp/android-engine-gradle-jdk21.log`。
- 本任务仍 in_progress。下一轮继续原计划服务/HTTP/持久暂存/错误回执/材料归属与受控释放、Dart适配、权限和系统时限、设备矩阵；未改任务状态或勾完整验收。
- 最终源码（含拒绝同执行键以新commandId重复enqueue）再跑 `./gradlew -Pandroid.builder.sdkDownload=false :app:testDebugUnitTest :app:compileDebugAndroidTestKotlin` 通过；实际包含 app 原生编译、五项JUnit及三项SQLite instrumentation测试编译，日志 `/tmp/android-engine-gradle-final.log`。Instrumentation 自带无依赖 runner，未来连接设备后以 `:app:connectedDebugAndroidTest` 运行；当前仍未执行真实SQLite。未添加 Dart桥，因此没有新增 Dart通道fake测试。

## 独立检查记录（2026-11-04，首轮局部检查点）

- 独立审查九文件、check.jsonl 六项、源设计协议/持久化章节及实际 DTO/DownloadEngine/AppStore 和调用方。发现 Kotlin 身份字符串/文件名校验比共享 DTO 宽松；已拒绝控制字符、尾点/尾空格及 Windows 保留文件名，并在原五项 JVM 测试中补身份、文件名与子目录回归。仅修改 EngineProtocol.kt、EngineProtocolTest.kt 与本事实记录。
- 独立执行 `cd android && JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew -Pandroid.builder.sdkDownload=false :app:testDebugUnitTest :app:compileDebugAndroidTestKotlin`：BUILD SUCCESSFUL in 35s，97 tasks；JUnit XML 五项、0 failures/errors/skipped。日志 `/tmp/android-engine-check-gradle.log`。`git diff --check` 通过，日志 `/tmp/android-engine-check-diff.log`。未重复 Flutter 检查；复核既有 analyze clean 与相关47项通过日志，本次仅改 Kotlin 校验。
- `/Users/wang/Library/Android/sdk/platform-tools/adb devices -l` 无设备；未启动 AVD。真实 Android SQLite 三项仅编译，持久化/跨连接竞争/回滚仍待设备运行；未知库版本、磁盘异常、Activity 重连与真实通道亦未运行验收。测试直接构造 NativeCommand，不能代替 enqueue 全载荷和通道端到端验证。
- ack 原生仅核对现存回执及所有权、高水位且拒绝全部材料释放；后续 Dart AndroidEngine 必须核验实际 AppStore 已提交完整确认及现存同版本业务回执，不可仅信任调用方传入 ack。当前没有 Dart 适配、worker、服务、网络、权限接入，不计为本轮伪缺陷，也不标整个任务完成。
- 本轮局部结论：协议校验/编译/JVM PASS；真实 SQLite 与端到端仍 BLOCK。指定新检查点目录不可访问；备用 protected.json 九项（.pi agents 与 docs）hash 全部匹配，不能声称完整新保护基线已复核。空 staging；未 stage/commit/archive。既有 Platform35 自动安装事实保持记录。

## Dart AndroidEngine 桥接实施记录（2026-11-04）

- 本轮仅新增 `lib/features/downloads/data/android_engine.dart`、`test/features/downloads/android_engine_test.dart`，追加本任务 design/implement；完整保留既有原生检查点和父代理同步文档。未修改公共 DTO/DownloadEngine/AppStore/schema、Kotlin/Gradle、依赖、配置或任务状态。
- 既有 MethodChannel/EventChannel 已桥接，命令扁平映射、完整 enqueue input、严格 inspect、稳定失败转换、事件校验与仅释放 Dart 订阅的 close 均已实现。传输仍真实返回 transferUnavailable；不会自动生成 commandId、重绑旧会话/版本或自动开始传输。
- ack 对照注入的真实 SQLite AppStore 完整确认行；同版本现存业务回执与 inspect 完整内容比较，缺少匹配版本也拒绝。inspect 后二次核对确认，旧确认、commitReceipt=false、任务已删、完整载荷冲突、原生材料释放拒绝和确认失败保留业务行均有测试。
- `flutter analyze` 通过（No issues found），日志 `/tmp/android-engine-bridge-analyze.log`；`flutter test` 全部80项通过（基础48 + 新增32），日志 `/tmp/android-engine-bridge-test.log`。`dart format` 与 `git diff --check` 通过，日志 `/tmp/android-engine-bridge-format.log`、`/tmp/android-engine-bridge-diff.log`。未改原生，未重复 Gradle。
- 首次全量测试72通过、4失败：新增测试夹具未预存任务，AppStore.commitReceipt 对不存在任务正确返回 false；修正为先保存任务并断言真实事务提交成功。随后76项通过；追加业务读取失败、inspect期间确认被替换、事件协议/原生错误、跨平台输入后最终80项通过。没有放宽 AppStore 或 fake 提交结果绕过问题。
- 所有新增 Dart 通道测试使用 Flutter messenger fake，确认边界使用真实 sqlite3 内存 AppStore；只能证明桥接映射和业务安全边界，不能声称 Android 原生、SQLite设备运行、服务/传输或端到端设备验收。原生事件尚无生产者；序号缺口需由后续 Repository 对齐，桥接保留真实序号，不自动更换会话。
- 下一步：原生前台 dataSync 服务、HTTP/重定向/安全续传、持久暂存和真实停止回执、材料归属与受控释放、系统权限/时限及 API29/30/33/35/36 设备矩阵。任务继续 in_progress，未勾完整 PRD，未 stage/commit/push/archive。

## Dart 桥接独立检查（2026-11-04，局部检查点）

- 本轮以 HEAD `0225253f87bb985599aa835f75cbef985752419d` 和检查点 `android-engine-bridge-review-3b_54jca` 为基线；完整核对 check.jsonl 六项、PRD/design/implement、源设计完整协议/启动订阅/Android/持久化章节、实际 DownloadEngine/DTO/AppStore、EngineProtocol/AndroidEngineChannels/ExecutionJournal 调用链。当前应用尚无 Repository 调用方，不能把接口实现当作业务接入或端到端验收。
- 修复事件换会话后永久拒绝：事件本身仍拒绝非当前会话，只有调用方明确 inspect 成功才同步会话及序号基线；同会话不降低已收到的序号，较早并发 inspect 的迟到响应不覆盖较新同步。不自动 inspect、重绑命令、请求传输或 retry。初始业务监听前暂存事件和 stream 错误，close 后忽略迟到交付。此记录补充 task design 中“不自动更换会话”的含义：显式 inspect 可以重新同步。
- 修复 ack inspect 竞争：只再次核对 ReceiptAck 不足；真实 AppStore 允许任务删除后同执行身份重建、保持确认行但换掉同版本完整回执。现在 inspect 后同时重读确认和现存业务任务，对现存同版本完整 receipt 再与原生快照比较。确认被更高版本替换、缺回执或冲突均不发 ack；任务已删、新代次或已有较新业务回执仍按实际保留确认行重放，不删除业务数据。
- 新增14项有意义回归（桥接共46项）：初始事件/错误缓冲、显式换会话/基线、同会话 inspect 竞争、迟到旧 inspect、同 ack 下业务 receipt 替换、inspect 期间删除/升级版本/代次、pause/cancel 错执行/状态/版本、enqueue/resume 返回兼容、close 竞争、序号缺口和 stream 错误/close 时序。业务确认使用真实 sqlite3 内存 AppStore，通道仍为 messenger fake。
- 最终独立 `flutter analyze` 通过，No issues found，日志 `/tmp/android-engine-bridge-check-analyze-final.log`；`flutter test` 94/94（基础48 + 桥接46）通过，日志 `/tmp/android-engine-bridge-check-test-final.log`。`dart format` 已执行，日志 `/tmp/android-engine-bridge-check-format.log`；`git diff --check` 通过，日志 `/tmp/android-engine-bridge-check-diff.log`。首次并行 Flutter 命令在生成目录 `.packages` 删除发生竞争使 analyze 未执行，随后 `flutter analyze --no-pub` 及顺序完整 `flutter analyze` 均通过；未修改依赖/SDK/平台配置。首次新增停止回执测试因 fixture 嵌套 PublishOperation key 同时不匹配得到 protocolMismatch，修正为合法异执行回执后通过，未放宽解析器。
- 编辑工具实时返回 Dart clean；本会话没有可调用的独立 LSP diagnostics 工具，`command -v lsp` 未找到，不能称完整 LSP 检查已执行。原生文件未变，复用首轮 Gradle五项JUnit通过、三项Android SQLite instrumentation仅编译的独立检查证据，不重复原生构建。
- 当前原生错误仅 protocolMismatch/stateConflict/persistenceFailure，transferUnavailable/materialReleaseUnavailable 均真实失败；后续网络、权限、HTTP、超时等传输错误映射尚未实现，不泛化为错误矩阵全部 PASS。原生尚无事件生产者，真实通道、Android SQLite运行、服务/HTTP/安全续传/真实暂停取消/设备生命周期继续 BLOCK；fake 与主机 SQLite 只证明本轮桥接边界。
- 修改范围仅 android_engine.dart、android_engine_test.dart 和本 implement.md。检查点 manifest34项、protected10项初始全部hash匹配；最终除这三个授权文件外均应保持基线hash。未 stage/commit/push/archive，更未更改 task.json；父代理安排下一轮服务/HTTP及设备验证。

## HTTP/私有暂存核心实施（2026-11-04，局部未验收）

- 仅新增 `HttpTransfer.kt` 与 `HttpTransferTest.kt`，追加本任务 design/implement；未改 Dart/DTO/AppStore/schema、通道、ExecutionJournal、Service/manifest/Gradle、插件/源规范、.pi/docs及任务状态；未 stage/commit/push/archive。父代理继续独立check与Service集成。
- 真实HTTP GET、默认HTTPS TLS代码路径、identity/超时、逐跳校验/10跳上限/循环检测、64位真实字节及未知total/单调样本、已知长度EOF校验、增量SHA-256、最多每秒force进度、排他私有持久暂存、先force归属意图、停止关闭barrier已实现。失败保留材料与原cause；不能把staged当发布成功。
- Stop的PAUSE/CANCEL只停止并保留数据，cancel清理未实现；调用方必须等待run终止且提交ExecutionJournal回执后才回应通道。resume明确restartRequired；没有完整恢复日志或安全206，本轮不接通道，transferUnavailable保持。facts为诊断材料而非可信恢复证明，进程重开不自动执行。
- 最终顺序运行 `cd android && JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew -Pandroid.builder.sdkDownload=false :app:testDebugUnitTest :app:compileDebugAndroidTestKotlin` 成功，日志 `/tmp/android-engine-http-gradle-final.log`；13项JUnit通过（原5+新增8），Android instrumentation仅编译。`flutter analyze`成功，日志 `/tmp/android-engine-http-analyze.log`；未改Dart，未重复94项Dart测试。`git diff --check`通过，日志 `/tmp/android-engine-http-diff.log`。
- 新增测试全部真实JVM loopback ServerSocket：精确bytes/散列和独立新文件、未知长度完成前增长/单调时间、相对重定向/循环/11跳/认证及file非法跳转、短EOF保留材料、pause和cancel实际停止、symlink根/目录拒绝及外部sentinel不变、403/真实连接拒绝、停止后检查点消费者失败不报paused/staged。大于4GiB只验证Content-Length=4294967419的64位解析与短EOF（实际5字节），未做真实大文件传输/大偏移续传。
- 首次在仓库根误执行gradlew得到127；随后Android目录构建发现jdk HttpServer不在Android单元测试编译surface（日志 `/tmp/android-engine-http-gradle.log`），改用真实ServerSocket受控HTTP实现后通过，未改Gradle或依赖。
- 未测/未实现：真实HTTPS服务/证书矩阵、15s/30s超时持续时间、force/close磁盘故障注入、目录fsync/崩溃恢复归属、恶意同UID并发目录替换、真实Android SQLite/通道/前台生命周期/设备矩阵/目录发布。未安装SDK/更改许可证/启动设备，不勾完整PRD验收。

## HTTP 核心独立检查（2026-11-04，局部 PASS）

- 以 HEAD `56d490f` 和父备份 `android-engine-http-review-cv4dts85/manifest.json` 为基线，检查前591文件 SHA-256 全匹配；读取 check.jsonl 六项、PRD/design/implement，并直接分段读取源设计的 URL、HTTP、恢复、材料与 Android 契约。核对 EngineProtocol、ExecutionJournal.complete 与通道调用链：HttpTransfer 仍只有测试调用方，通道仍 transferUnavailable，未接 Service 或共享业务库。
- 修复 HttpTransfer 终态竞态：原先 facts 和返回值各读一次可变 stop.reason，晚到停止可能导致记录 staged、结果 PAUSE。现在输出关闭后固定同一终态快照；此边界后的停止需由 Service 协调，不能据 Stop.request 已返回就提交暂停/取消回执。同步本任务 design。
- 新增3项有独立意义的真实 loopback 回归：服务器扣住 EOF 至双 barrier 结束，150ms 内 run 不完成，然后跨线程 request 与 run 各在3s内退出并核对关闭facts/实际材料；gzip及负数/非法/溢出 Content-Length 在写入前拒绝；chunked 解码后的正文超过声明长度时拒绝 staged、保留材料。后一用例是冲突响应的保守拒绝，不声称能检测 HttpURLConnection 已按固定长度截掉的 HTTP 帧外字节。
- 独立运行 `cd android && JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew -Pandroid.builder.sdkDownload=false :app:testDebugUnitTest :app:compileDebugAndroidTestKotlin` 最终 BUILD SUCCESSFUL（7s，97 tasks）；JUnit XML 为协议5 + HTTP11 = 16项，0 failures/errors/skipped。日志 `/tmp/android-engine-http-check-gradle.log`。
- 顺序运行 `flutter analyze`：No issues found（10.8s），日志 `/tmp/android-engine-http-check-analyze.log`；Dart未改，未重复94项Dart测试。`git diff --check` 通过，日志 `/tmp/android-engine-http-check-diff.log`。未暂存、提交或改任务状态；最终只修改允许的HttpTransfer、其测试和本任务design/implement，保护文件哈希复核匹配。
- 本轮局部 PASS，无剩余局部阻断；Android完整验收仍 BLOCK。真实设备的 HttpURLConnection/TLS/停止延迟（包括连接及响应头阻塞）、默认TLS证书失败、磁盘force/close故障尚未注入；3项真实Android SQLite测试仅编译，不能计运行通过。当前大长度证据仅 Content-Length=4294967419、实际5字节短EOF，不是真实>4GiB传输。facts仅诊断，目录fsync、重启材料归属和崩溃恢复未实现；私有sandbox排除同UID恶意目录替换，不能称完全TOCTOU安全。
- 下轮门槛：Service脱离Activity/Dart、串行命令与终态及取消优先协调；等待实际退出/关闭/持久日志再交付回执；安全Range/强验证器/prefix与candidate恢复；归属登记和受控清理；通知/权限/系统时限、禁止自动传输及API29/30/33/35/36设备矩阵。不得直接把此构件接为已验收生产DownloadEngine或勾完整PRD。
