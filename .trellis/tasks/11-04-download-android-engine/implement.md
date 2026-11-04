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

## 材料登记前置检查点（2026-11-04，Service目标未完成）

- 为避免越过材料安全门，本轮按授权降为真实内部路径检查点；未实现/接通Service、worker协调或真实事件，通道继续transferUnavailable，未改MainActivity/manifest/Dart/共享DTO/业务库/源规范/依赖/任务状态。HttpTransfer只新增必须显式提供的分配回调，先原生日志事务再创建facts/part；原force/close及首异常传播保持。
- ExecutionJournal v2仅新增materials；1→2迁移不改v1三表，原库保留。newTransfer使用原生filesDir注入registerMaterials，核对当前会话、已登记pending命令完整载荷、最新执行代次和expectedReceiptVersion、私有UUID材料对；每命令最多一次分配，未知意图不自动重试。inspectMaterials只读取，不触发网络、不授权恢复或释放。
- 新增2项主机真实核心断言：登记故障在创建/网络前传播同一首异常，回调看到两个尚未创建的定位；真实HTTP服务确认请求发生于分配完成与排他创建之后。原HTTP11项保持，总JUnit18项（协议5+HTTP13）0 failures/errors/skipped。
- 新增3项Android SQLite instrumentation：已登记材料/停止关闭后真实paused回执与重开保留、重复/旧会话/越界分配拒绝；材料INSERT故障无文件且命令未知不重提；v1迁移保留回执/幂等结果与迁移失败保留user_version=1和历史，修复冲突后重开迁移。合计6项仅编译，未连接设备运行，不计通过。测试暂停为预先停止、无网络路径，不冒充设备活动传输暂停。
- 最终 `cd android && JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew -Pandroid.builder.sdkDownload=false :app:testDebugUnitTest :app:compileDebugAndroidTestKotlin` 成功，日志 `/tmp/android-engine-service-gradle-verified.log`；顺序flutter analyze成功（`/tmp/android-engine-service-analyze-final.log`），diff --check成功（`/tmp/android-engine-service-diff.log`）。Dart未改，未重跑94项。
- 根目录首次误运行gradlew退出127，已纠正android目录。附加assembleDebug尝试两次各60s超时，中止时未得到成功结果；不计构建通过，日志 `/tmp/android-engine-service-gradle-final.log`、`/tmp/android-engine-service-assemble.log`。未安装SDK/改许可证/启动AVD。父提供的/tmp/android-engine-http-review-cv4dts85/manifest.json本会话不存在；通过git状态/差异核对保护文件无新增修改，保留既有.pi两文件和docs。未stage/commit/push/archive，暂存区为空。
- 残留：尚无串行协调/最多两worker、当前进程用户提交队列令牌、多版本worker回执/EngineEvent、真正pause命令等待、取消先持久意图及取消优先/清理、重启waitingRecovery本地对齐、Service/FGS权限通知/timeout。resume保持restartRequired，ack拒绝材料释放，staged不标completed。没有目录fsync，崩溃可丢目录项；意图仅说明归属分配，不认证bytes/prefix。未知孤儿不删。安全206、发布、磁盘force/close故障、进程强杀及API29/30/33/35/36设备矩阵均未实现/未测，不勾PRD。

## 材料门独立复核补充（2026-11-04）

独立复核修复 newTransfer 原先只绑定 key、允许 run 替换 URL 的缺口：工厂深复制并重新解析完整命令，固定授权 URL，run 在创建目录前拒绝替换 URL；材料事务仍在延迟执行时核验 pending/当前代次/版本，重复调用同一工厂回调不能再次分配。补充主机 URL 替换零分配测试，以及 instrumentation 的输入变更隔离、同 worker 重用和迟到旧代次拒绝断言。后者仅编译，未在设备运行。

此门只保证分配事务当时的授权：登记提交与创建/网络之间仍需后续 Service 单执行协调队列，串行处理 stop 命令和终态；不能视作活动暂停、取消优先或重启恢复已验收。目录 fsync、prefix 认证、设备 SQLite/迁移故障实测均未完成；保留材料且无自动重试。独立 JVM 19项（协议5＋HTTP14）与 AndroidTest Kotlin 编译通过；PRD保持未勾选。

## 材料门规范同步与检查点提交

- 父代理核对自动修复后 ExecutionJournal.kt：额外变化仅 Kotlin 换行，完整命令深复制/URL固定与材料事务逻辑保持。再次执行 Gradle 单测及 AndroidTest Kotlin 编译，BUILD SUCCESSFUL（3s）；JUnit XML 协议5＋HTTP14，失败/错误/跳过均0，日志 `/tmp/android-material-parent-gradle.log`。先前误设 context-mode 超时的尝试无完成结果，不计通过。
- 同步 frontend index/architecture 与源设计中的 v2 materials、分配前登记、固定命令/URL、测试数量及设备未测边界；验证链接、围栏、尾换行和 diff --check。检查点仅纳入四个 Kotlin 实现/测试文件、任务 design/implement、上述三份规范；排除既有 .pi 配置与 docs 图片。不归档，不勾 PRD。
- 下一轮目标为真实 Service/协调器入口：捕获已校验当前会话命令，串行登记/终态、最多两活动 worker、已持久取消意图优先、pause 等待真实退出及持久回执、事件持久后交付；重开只读取，不重传。安全 resume 与受控材料释放未闭合前继续明确拒绝，不用伪成功补齐。

## Service／协调器实施检查点（2026-11-04，未完整验收）

- 生产调用链已接通：AndroidEngine MethodChannel → 进程串行TransferCoordinator → 当前进程一次性Service启动令牌 → exported=false/dataSync/START_NOT_STICKY DownloadService → 双HttpTransfer worker → ExecutionJournal → 主线程EngineEvent。Activity detach仅解除监听；inspect、旧/null Intent、重开日志均不调度。服务权限/启动拒绝及timeout有失败回执；POST_NOTIFICATIONS仍须用户授权，没有新增权限请求UI。低于API26显式拒绝，不改最低SDK。
- 日志v3新增worker_authorizations；enqueue原接受结果不可变，分配在授权版本/会话/完整命令/最新代次/一次性消费/无stop检查后登记。worker事实独立推进版本，pause保存stop后等run实际退出、force/close及最终回执提交；cancel持久cancelling后停止，保留cleanupFailure及材料，不伪报清理完成。续传restartRequired、releaseResumeRefs拒绝、完整私有staged仅publishing。
- 真实验证：android目录JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew -Pandroid.builder.sdkDownload=false :app:testDebugUnitTest :app:compileDebugAndroidTestKotlin :app:assembleDebug；最终日志/tmp/android-service-gradle-delivery.log。25项JVM通过（协议5/HTTP14/协调器6，零失败跳过）；8项真实SQLite instrumentation只编译，adb devices为空。debug APK构建不等于设备运行或发布签名验收。
- 协调器测试使用真实Socket/HttpTransfer/文件，Journal为host fake：未知长度完整暂存、持久后事件、重放无重复请求、双worker上限及排队暂停；暂停真实run闸与cancel优先、unknown/旧会话/重建协调器零调度、落库失败不发事件。停止屏障用分配闸控制run，尚缺真实Android连接/响应头阻塞及磁盘force/close故障注入。新增SQLite生命周期/授权消费和v2迁移测试，未设备运行。
- Dart最小配套新增4种Service错误分类及4项AppStore+messenger测试；顺序flutter analyze与flutter test通过（98项），日志/tmp/android-service-analyze-final2.log、/tmp/android-service-flutter-tests.log；通道fake不是设备通道验收。
- 失败重跑：首次编译发现NativeCheckpoint的String暂存/error/publishing不匹配，修正内部checkpoint；首次新增协调器测试3项失败由macOS /var临时目录alias触发私有根拒绝，改测试canonicalFile后25项通过；Dart测试误调用fixture命令导致analyze失败，改用字段后analyze及98项通过。保留失败日志/tmp/android-service-gradle.log、/tmp/android-service-gradle-tests.log、/tmp/android-service-analyze-final.log。
- 基线protected.json十文件hash完全匹配；591文件manifest除授权文件外无差异，新增文件在允许原生包/测试目录。未stage/commit/push/archive、未改task.json、未勾PRD。
- 仍需独立检查v3事务及真实SQLite/服务生命周期/通道；验证权限拒绝、后台启动/timeout、Activity重连、强杀和进程重启零HTTP，尤其Service停止与紧邻新命令的竞争。安全Range/强验证器/prefix、目录fsync、恢复材料受控清理、用户目录发布、超过4GiB实传及API29/30/33/35/36设备矩阵仍未闭合。

## Service／协调器独立检查（2026-11-04，本轮仍 BLOCK）

- 已直接读取 check.jsonl 六项、PRD/design/implement 和570行源设计（分段完整读取），独立检查本轮12文件；旧frontend v2检查点不作为禁止新Service实现的要求。生产调用链确实接通，但不等于生命周期验收。
- 修复 ExecutionJournal worker/stop/finish 原先仅部分校验授权的缺口：同事务核对不可变完整命令、会话、执行归属、最新代次/版本和finished；stop命令必须已登记且未完成；持久cancel不能被pause或publishing/running回执覆盖；最终pause结果核对完整命令。enqueue接受结果保持不可变。
- 修复失败pause命令重放原先会直接成功返回failed/cancelling回执；现在仍以失败结束。修复事件消费者抛错导致持久接受后不启动/暂停结果矛盾；消费者错误诊断后由inspect重放。修复ServiceReady前已被pause/cancel的enqueue Future永久悬挂。新增具体Socket/UnknownHost/SocketTimeout及队列持久异常分类，Dart补networkUnavailable/timeout稳定映射且不转发原始消息。
- 新增3项协调器JVM回归：真实loopback拒绝连接保留材料与网络分类、分配故障后pause重放保持失败、消费者抛错不阻断持久暂停/令牌处理/等待Future。Journal仍为host fake。新增2项真实SQLite instrumentation（完整命令及取消不可撤销、未知版本保历史）；加强v1迁移失败注入至第二DDL，断言第一DDL也回滚。合计10项仅编译，未运行。
- 最终独立Gradle命令含testDebugUnitTest、compileDebugAndroidTestKotlin、assembleDebug通过，日志`/tmp/android-service-review-gradle-final.log`；JUnit XML 28项（协议5＋HTTP14＋协调器9），failures/errors/skipped均0。顺序flutter analyze与flutter test通过，100项，日志`/tmp/android-service-review-analyze-final.log`和`/tmp/android-service-review-flutter-final.log`。adb无连接设备，API29/30/33/35/36、真实SQLite/Service/通道均未设备验收。
- 保留P1 BLOCK：idle回调无条件post stopService，紧邻新enqueue可使用同一Service后被旧停止/旧onDestroy的全局restrict终止；token在queue消费后跨主线程post，启动前未重新验证，serviceReady返回false仍可先置serviceActive。需要Service实例/启动授权代次与idle停止握手的生命周期协调重构，未用fake掩盖或声称修复。
- 保留P1/P2 BLOCK：onTimeout/onDestroy的stop只能排在串行日志队列后，Stop.request内部同步disconnect且停止原因first-wins（既有HTTP核心禁止修改）；及时停止和cancel信号优先未证明。终态日志失败后finally移除内存work，数据库仍保留旧回执/材料，但没有终态保存重试入口。HTTP状态/长度/编码错误在核心中都是无类型IOException，仍可能归为fileWriteFailure；需要核心提供结构化阶段/错误，禁止按字符串判断。
- 备份路径可访问，594文件manifest差异均在允许文件，protected.json十文件hash全部匹配；既有.pi两个修改和docs保留，暂存区为空。未stage/commit/push/archive、未改task.json/PRD/源规范/依赖或SDK。部分允许Kotlin文件被现有格式工具重排。
- 下一步先关闭Service实例/idle-stop/token竞态及终态持久化失败的恢复入口，再运行真实SQLite instrumentation和设备生命周期矩阵；需另授权HTTP核心结构化错误及stop实现调整。安全续传、受控材料清理、目录fsync及用户目录发布仍未完成。局部修复测试PASS，本轮Service交付与完整Android引擎继续BLOCK，不勾完整验收。

## 五项源码阻断修复检查点（2026-11-04，平台仍BLOCK）

- 保留独立check的完整worker/stop/pause事务身份绑定、取消不可撤销、失败pause重放仍失败、ready前停止的accepted Future完成及事件消费者隔离。没有恢复旧版本。
- A/B：新增并实际接入ServiceLifecycle统一进程token、实例、idle代次和ready状态。Runtime不再维护第二份token集合或serviceActive boolean；真正startService/startForeground/worker提交/idle stopSelf均受同一授权检查。idle票据过期不能停止新enqueue；destroy/timeout只失效所属实例授权，不全局restrict。重复/空/旧Intent不创建worker。已经退休的旧Service实例拒绝绑定新授权并给出可追踪启动失败；系统随后创建的新实例可绑定，旧destroy不触碰新实例。
- C：HttpTransfer.Stop原子发布CANCEL>PAUSE，disconnect在独立daemon线程不持锁，attach后重查停止标志；系统timeout/destroy在排SQLite队列之前直接发布所属worker停止，实际网络是否及时中断仍依赖平台。user pause/cancel继续先持久stop意图再信号；Future成功仍需真实run退出/force/close及终态落库。
- D：终态失败冻结并保留Work.terminal及完整材料定位，active=false，不占HTTP worker槽；inspect在本进程有待补存时明确persistenceFailure/terminalSavePending，不改库、不发网络或虚构版本。显式重发同一完整enqueue/pause命令只补本地finish，其他命令不重新授权HTTP。ExecutionJournal.finishWorker新增同checkpoint/命令的幂等已提交结果核对，涵盖提交成功但结果丢失；版本/载荷不同拒绝。进程kill后仍只承认已持久事实，不从facts猜测staged。取消仍cleanupFailure，不代表完成清理。
- E：HttpTransfer按JOURNAL/NETWORK/HTTP/FILE阶段包typed错误，保留原cause与suppressed关闭错误；非200、redirect/编码/长度校验为httpFailure，网络/超时与fileWriteFailure/persistenceFailure分开。新增fileUse关闭门测试，关闭失败不能返回暂停/暂存成功。Dart最小新增httpFailure分类和terminalSavePending白名单；未改共享DTO/API/schema。
- 最终验证：android目录JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew -Pandroid.builder.sdkDownload=false :app:testDebugUnitTest :app:compileDebugAndroidTestKotlin :app:assembleDebug通过，日志/tmp/android-service-fix-final2.log；40项JVM（协议5+HTTP17+协调器14+生命周期4），零失败/错误/跳过。11项真实SQLite instrumentation只编译，设备为空，未执行。
- 新回归采用生产Lifecycle/Stop/Coordinator与确定的latch/回调：旧idle→新enqueue→旧destroy、新旧实例交错；post启动后取消/timeout；disconnect阻塞时CANCEL优先；真实loopback终态落库失败保留→显式本地重试→不增加HTTP且不变已提交版本；暂停终态补存；保存失败不饿死另一个真实HTTP；HTTP响应与真实文件打开/JOURNAL失败分类。Journal为host fake，fileClose故障为生产关闭helper注入，不冒充真实Android SQLite/磁盘force故障。
- 顺序flutter analyze、flutter test通过，No issues found、102项测试；日志/tmp/android-service-fix-analyze.log、/tmp/android-service-fix-flutter.log。原生首次编译因fileUse非inline闭包内return失败，改为返回helper结果以确保关闭之后返回，随后所有原生检查正常退出。失败日志/tmp/android-service-fix-first.log保留。未安装SDK/改license/启AVD。
- protected.json十文件hash匹配，594文件manifest除授权源码/测试/design外无差异；此implement记录为后续授权追加。git diff --check通过，暂存空；未stage/commit/push/archive、未改task.json/PRD。本轮以源码阻断修复检查点交接，仍需独立复核及实际Android Service/SQLite/权限/timeout/进程重启设备矩阵。安全续传、目录fsync、受控清理/发布及平台完整验收仍BLOCK，PRD保持未勾选。

## A–E修复独立续审（2026-11-04，源码局部PASS／平台仍BLOCK）

- 先读取当前implement.jsonl/check.jsonl各六项，再完整读取最新任务设计及implement新增段与实施报告；源设计与六项规范沿用上轮已完整读取且本轮不变的内容。独立复核全部本轮生产链及真实调用方，不以实施报告代替检查。
- A/B最小追加修复：ServiceLifecycle.pending与foreground在实际Android启动动作抛错时立即撤销token，不等可能阻塞的日志队列；foreground失败的Service主线程立即安排带epoch的idle停止。DownloadService.onTimeout已退休整个实例，改用无参stopSelf停止该实例所有start请求，避免较旧startId无法停止较新start请求；旧实例不能停止新owner。新增3项确定性Lifecycle回归（启动失败立即撤权、foreground失败/新epoch、同实例多start退休），不声称设备执行。
- D追加修复：已持久cancel返回cleanupFailure之后，若终态补存失败，重复同完整cancel原先会被pending分支改成stateConflict。现在保留cancel完整命令，pending期间仍重放原cleanupFailure，不修改已持久取消意图，不授权HTTP或隐式重试补存。新增回归覆盖初次取消、pending重放、enqueue显式本地补存及之后重放一致。加强已有pause补存测试：改expectedVersion/载荷/旧会话拒绝且不调用finish；两个同命令并发重试只得到同一持久结果。
- 独立结论：源码范围A–E及本轮追加问题关闭，局部PASS，无剩余源码阻断。生命周期授权统一且不在主线程等待SQLite/worker；同一monitor内仅短平台启动/前台/停止IPC及worker提交，未发现反向锁等待。IPC平台延迟及真实Service回调顺序仍需设备验收。Stop原子CANCEL优先且disconnect不持锁，紧急实例停止先发布标志再排日志；pause仍等run退出、force/close与终态事务。终态补存不占worker槽、不重新run，进程kill丢失内存终态时仅认已持久事实。
- 独立重跑完整Gradle命令（testDebugUnitTest、compileDebugAndroidTestKotlin、assembleDebug，既有JBR，sdkDownload=false）正常退出0，日志/tmp/android-service-recheck-gradle.log。JUnit XML 44项（protocol5+HTTP17+coordinator15+lifecycle7），零failure/error/skipped。顺序flutter analyze与flutter test正常退出0，No issues found、102项；日志/tmp/android-service-recheck-analyze.log、/tmp/android-service-recheck-flutter.log。11项SQLite instrumentation仍只编译，adb无设备，不记真实SQLite/Service设备通过。
- 新备份android-service-final-review-h9ncrwui可访问；597文件manifest差异仅授权原生源码/测试及本任务design/implement，protected10全匹配，暂存区为空；既有.pi/docs保留。未stage/commit/push/archive、未改task.json/PRD/frontend/source specs/共享模型/非Android实现，未安装SDK/改license/启AVD。
- 下一步由父代理同步正式规范并处理检查点提交；任务仍in_progress/PRD不勾。平台完整验收仍BLOCK：实际SQLite迁移与故障、Service/权限/timeout/主线程与强杀重开零HTTP、API29/30/33/35/36；安全Range/prefix续传、受控清理与发布、目录fsync、真实>4GiB仍未完成或未测。

## Service 检查点规范同步与提交（2026-11-04）

- 父代理读取完整续审报告，核对最终 DownloadService/ServiceLifecycle/TransferCoordinator：失败启动同步撤权、所属实例 timeout 无参 stopSelf、pending cancel 重放及冻结终态补存仍在自动格式化后的实际代码中。597文件审查基线仅7项允许差异，10项受保护文件hash一致，暂存空；JUnit XML为44项、错误/失败/跳过均0，独立最终Gradle/analyze/102项Dart日志正常退出。
- 按 trellis-update-spec 判断，本轮引入跨通道执行、v3授权表、实例握手、停止优先级、持久后事件和终态本地补存，必须更新可执行规范。architecture.md合并更新Android七节契约，index.md及源设计状态同步生产调用链；共享AppStore v1/schema不变，旧v2材料门不再作为当前引擎状态。
- 检查点提交范围仅本任务原生实现/manifest/测试、Dart桥接错误分类及测试、任务design/implement和三份规范；不包含既有.pi配置或docs图片，不改变task.json或完整PRD验收框。提交只保存已独立检查的局部成果，不归档、不增加父任务完成数。
- 下一轮优先闭合安全续传：先建立持久验证器、认证偏移与原件保留材料协议，再接实际GET写前206/Range/强验证器核验和用户显式恢复，未知旧材料继续restartRequired；受控清理与真实设备矩阵仍是独立门槛。11项Android SQLite测试目前仅编译，不能因主机44/102或debug APK通过标为设备通过。

## 恢复材料第一段计划（本轮）

先实现有界prefix摘要和原生checkpoint类型；接生产HttpTransfer after-force→ExecutionJournal v4持久回调并保留已有生命周期/终态规则；再实现内部实际GET响应门及先登记candidate的原件保留路径。新增真实loopback/文件与迁移编译回归；不开放外部resume、不修改共享DTO或能力声明。最后运行原生JUnit/AndroidTest编译、analyze，明确设备与完整resume调度仍未验收。

## 恢复材料第一段实际检查点（2026-11-04，完整resume仍BLOCK）

- 生产newTransfer现在显式接入onCheckpoint：实际写入及output.force/facts.force后才认证offset；onSample继续只计进度。暂停最终checkpoint在payload关闭及closed事实force后保存；短EOF/force前回调失败不提升最终offset，保留较早已force检查点。回调通过既有allocation队列边界串行落ExecutionJournal，不改Service/Stop/terminalSavePending/CANCEL优先代码。
- NativePrefixDigest为native-prefix-v1-65536：64KiB固定块、domain-separated SHA256链与有界tail快照；不克隆provider、不反复扫整文件、不称普通SHA256。强ETag/URL/算法/完整执行归属/认证offset和total存独立日志；无/弱ETag或旧facts不提供恢复证明。回执版本关联只更新引用，不把progress字节提升为offset；对外resumeSupport及resume命令仍保持保守拒绝。
- 日志v4逐版本保留v1/v2/v3表与历史，新增resume_checkpoints/recovery_attempts/recovery_operations。内部newRecovery只读本日志的opaque ref和固定完整pending resume命令，要求源worker真实finished且未cancel；beforeRequest一次性持久attempt阻止同命令重传，真实响应全部校验后才持久candidate intent并排他创建。inspectResume/inspectRecoveries仅原生诊断，不调度网络/创建/删除。对外Coordinator仍在register之前拒绝resume，未接完整恢复worker授权与生命周期。
- ResumeTransfer真实GET带Range/If-Range，先线性认证源prefix，再验证206/完全一致的强ETag、精确Content-Range起止/total、Content-Length（存在时）与旧total。所有响应门通过之后才登记candidate并复制已认证prefix，再次复核复制digest后追加suffix；源文件永不截断。COPY/短EOF失败保留源和已登记candidate；没有候选恢复继续/受控清理接口，本轮不将失败candidate当作新恢复源。
- 真正主机验证：android目录既有JBR执行./gradlew -Pandroid.builder.sdkDownload=false :app:testDebugUnitTest :app:compileDebugAndroidTestKotlin :app:assembleDebug正常退出0，最终/tmp/android-resume-delivery-final.log。53项JVM＝协议5+HTTP19+Coordinator15+Lifecycle7+Resume7，零failures/errors/skipped。新增9项覆盖强ETag暂停checkpoint重读、progress早于force无认证、失败保留较早offset、无/弱validator、实际206/candidate/源8192认证prefix与24576尾部hash不变、200/416/坏Range/总长/ETag/长度/overflow拒绝、copy中断/短EOF/落库回调失败无staged、symlink sentinel、无Content-Length字节与分块digest独立向量。>4GiB仅Range解析边界，不是实际大文件传输。
- Android SQLite instrumentation新增2项，共13项仅编译：生产newTransfer→真实Socket→强ETag暂停→日志重开；v3迁移及第二DDL失败回滚，保留v1/v2/未知版本断言。adb devices -l仍空；没有运行设备SQLite/Service，不能因编译声称迁移或持久化设备通过。
- flutter analyze正常退出No issues found，/tmp/android-resume-analyze.log。本轮无Dart改动，复用独立续审102项Dart通过，没有重跑或声称本轮运行flutter test。首次Kotlin编译因混合可空SQL参数arrayOf推断交叉类型失败，显式Any?后通过；失败日志/tmp/android-resume-first.log保留。其后新增回归均正常退出。
- 基线596文件manifest除6个授权已有文件外匹配；新增仅原生NativeResumeMaterial/ResumeTransfer及对应JVM测试。protected10全hash匹配，git diff --check通过，暂存空。未stage/commit/push/archive、未改task.json/PRD/frontend/source specs/共享DTO/其他平台/依赖/SDK/manifest，未安装SDK/改license/启AVD。
- 下一最小项：独立复核摘要/force时序/v4命令与材料门，之后再接完整resume调度（同执行worker、当前进程用户授权、停止/回执/幂等），以及candidate继续/废弃、受控释放和设备迁移/磁盘故障。当前核心候选完成只记录内部staged，未产生用户resume成功或completed；未实现用户目录发布、目录fsync、真实>4GiB传输。完整Android与PRD验收继续BLOCK，全部验收框未勾。

## 恢复安全门第一段独立检查（2026-11-04，内部局部PASS）

- 读取当前check.jsonl六条、PRD、任务design及implement最新完整恢复段、实施完整报告；沿用已读源设计主体并核对材料/恢复/回执相关契约。独立审查本轮9文件及生产newTransfer注入、v4事务和内部newRecovery真实GET路径。没有开放resume；Coordinator仍在register前restartRequired，Service/Lifecycle/Coordinator/Dart均未修改。
- 修复final proof过早提交：原先payload关闭后、facts.close之前就调用最终onCheckpoint；现在payload与facts均真实关闭成功后才提交最终proof。周期proof仍要求payload.force和facts.force；facts关闭失败保留更早已force proof，不提升终态offset。新增真实loopback、两阶段barrier及真实close helper故障注入，证实旧offset/digest保留、没有暂停伪成功。
- 修复初始prefix线性认证不可及时响应Stop：现在每64KiB认证块后检查原子Stop，复制原有检查仍保留；新增认证首块请求CANCEL的确定性回归，beforeRequest与candidate均零调用，原件hash不变。新增candidate真实close helper故障回归，文件错误不会标staged；disconnect错误按NETWORK包装并作为suppressed保留首Journal错误，增加对应回归。suffix计数溢出也明确归HTTP阶段。
- 强化日志门：cancel已持久后不再提升恢复proof；既有proof算法也须一致；newRecovery核对冻结载荷与NativeCommand的ownerSessionId一致，并在每次授权重查源worker完整engine/generation/version与proof receipt_version和当前执行版本一致，避免旧proof与新事实混用。新增取消proof不可提升/不可恢复的SQLite instrumentation；扩展已有生产检查点测试覆盖同offset换digest/total拒绝、factory后旧receipt proof在GET前拒绝、内部实际206→candidate→staged及同命令一次性请求拒绝。这些设备测试只编译，未运行。
- 独立用Python hashlib.sha256与struct.pack('>qI')重新计算0/1/65535/65536/65537/131072/200000字节固定向量，与实现方200000向量一致；新增边界及重复snapshot回归，分片输入不依赖同实现互证。摘要保持64KiB块+32字节chain+有界tail，不克隆provider；恢复认证/复制线性读源，不截断或提升未提交tail。
- 独立最终Gradle（既有JBR、sdkDownload=false，testDebugUnitTest+compileDebugAndroidTestKotlin+assembleDebug）正常退出0，日志/tmp/android-resume-check-gradle.log。JUnit XML 58项=Protocol5+HTTP20+Coordinator15+Lifecycle7+Resume11，零failure/error/skipped。flutter analyze正常退出No issues found，/tmp/android-resume-check-analyze.log；无Dart变更，沿用上轮独立102项，不声称本轮重跑flutter test。14项SQLite instrumentation仅编译，adb无设备；未安装SDK/改license/启AVD。
- 审查备份android-resume-review-t7zk27bu可访问；600文件manifest差异仅授权源码/测试和本implement记录，protected10全部MATCH，暂存空，diff --check通过，既有.pi/docs保留。未stage/commit/push/archive，未改task.json/PRD/源规范/frontend specs/非Android实现/依赖或SDK。
- 内部安全门局部PASS，无剩余本轮源码阻断；完整resume/引擎与设备仍BLOCK。下一最小项是将opaque proof绑定当前进程用户授权与同执行恢复worker，闭合stop/receipt/幂等及candidate继续/废弃/受控释放，不能直接放开公开resume。还需真实SQLite迁移/force-close故障、设备Service与API29/30/33/35/36、目录fsync/用户目录发布和真实>4GiB传输。私有sandbox不声称抵御同UID恶意并发替换；kill后只认已持久事实。

## 显式resume接线本轮计划

先保持58项基线安全门，补恢复candidate双force/final双close检查点、类型化停止与原件保留回归；独立日志v5只新增操作归属的候选proof及精确查询，不扫描或自动选择调度。验证该必要前置后评估完整接线；未能安全闭合的公共resume/worker授权/跨session退休必须继续拒绝，不能简删当前门。

## 本轮实际交付：candidate停止与认证前置，公开resume保持BLOCK

- 本轮没有安全完成公开resume的完整接线，Coordinator仍在register前restartRequired。未更改Runtime/ServiceLifecycle/DownloadService/Coordinator/Dart；不把删除拒绝或放松v4 sourceproof=current门当接线。必须下一轮原子区分冻结source proof/version与新worker授权version，并闭合跨session显式退休、resume终态补存及当前branch选择。
- 已交付真实ResumeTransfer前置：初始prefix/复制阶段停止抛内部Stopped(reason,candidate?,bytes)，区别于资源restartRequired；同一个Stop贯穿认证/复制/网络，CANCEL高于PAUSE。完整prefix复制后的suffix暂停等待input/output/facts真实关闭，返回带真实stop的Staged事实，不调用stagedCandidate；CANCEL不推进candidate proof。复制中断只保留已登记partial，不冒充完整prefix。
- candidate现有operation在文件创建前同事务登记payload和派生facts路径；两个文件CREATE_NEW+NOFOLLOW。新增after-force候选proof回调：周期payload.force+facts.force后保存，最终两文件close成功才保存，progress不提升proof，file/EOF/Journal错误只保留较早认证offset。使用原NativePrefixDigest的有界64KiB算法，whole-file SHA256仍覆盖复制prefix+suffix，原源和旧candidate均保留。
- 独立日志v5逐步保留v1-v4数据，新增recovery_candidate_files和candidate_checkpoints；proof绑定operation、完整resume command、冻结source ref/version、当前仍固定的expected receipt版本、完整执行归属、candidate路径/强ETag/URL/total/offset/digest/algorithm。newRecovery现有工厂真实注入候选proof持久回调，在所有原validate门后写入；inspectCandidate(key,resumeCommandId)精确branch查询，不混入inspectResume，不自动授予下一次网络。它是候选证据，不是已闭合的新worker/current branch能力。
- 验证：android目录既有JBR执行./gradlew -Pandroid.builder.sdkDownload=false :app:testDebugUnitTest :app:compileDebugAndroidTestKotlin :app:assembleDebug正常退出0，日志/tmp/android-resume-wiring-delivery-final.log。63项JVM=Protocol5+HTTP20+Coordinator15+Lifecycle7+Resume16，失败/错误/跳过0。新增5项：suffix pause候选新prefix→下一内部core Range从新offset继续并逐字节/wholeSHA256核验；facts关闭失败零final proof；复制中PAUSE/CANCEL优先typed停止；CANCEL零proof；progress回调失败只留较早双force offset且保留未提交tail。旧初始认证CANCEL回归改为检查Stopped而非restartRequired，仍在首64KiB停止、零GET。两次core测试显式host proof边界，不是公开Coordinator恢复入口验证。
- SQLite instrumentation共15项仅编译，新增v4→v5保历史和第二DDL失败回滚；加强已有真实newRecovery Socket测试：候选proof绑定/精确查询/重开/原source不隐式切branch。旧v1/v2/v3迁移fixture相应移除v5表后重建，保留旧迁移失败测试。adb无设备，不能声称真实SQLite/Service运行通过。
- flutter analyze正常退出No issues found，/tmp/android-resume-wiring-analyze.log；Dart未改，未重跑前轮独立102项flutter test。原生各轮均正常退出，无失败重跑或超时算通过。未安装SDK/改license/启AVD。
- 599文件manifest仅7个授权已有文件变化；protected10全部hash匹配。git diff --check通过、暂存空；既有.pi2修改/docs保护。未stage/commit/push/archive、未改task.json/PRD/frontend/source specs/共享模型/其他平台/依赖/SDK/manifest。任务保持in_progress、PRD未勾、完整平台BLOCK。
- 精确下一步仍需实现：v6或等效新resume worker授权/accept queued事务固定源proof与sourceversion；当前session和旧进程授权显式retire；Coordinator/Service同执行恢复worker、resume命令补存；candidate proof晋升为确定当前branch并对外诚实resumeSupport/ref。在这些一起闭合前不可开放用户resume，也未运行要求的“真实loopback经生产Coordinator resume入口”测试。本轮仅关闭candidate停止/proof前置，不宣称本轮原定公开交付目标完成。

## candidate前置独立复核（2026-11-04，局部PASS／公开resume未交付）

- 依当前check.jsonl六条、PRD、任务design/implement最新完整章节和实施完整report核验生产ResumeTransfer、v5 newRecovery注入及双文件/候选事务。此前源主体约束沿用；未开放公开resume，Service/Coordinator/Runtime/Lifecycle/HttpTransfer/Dart未改。ExecutionJournal备份差异仅自动格式化增加换行、花括号、尾逗号，已逐段核对无语义变化。
- 修复Stopped遮盖真实close错误：复制中Stopped若伴随payload/facts关闭故障，提升真实FILE错误为失败并保留Stopped诊断；Stopped若伴随disconnect故障，同样保留NETWORK错误，不能当暂停成功。已有首IO/Journal错误仍主导，后续关闭异常仅suppressed。Stopped.bytes仅认证源位置或复制诊断，不是任务新下载字节/可恢复offset。
- 修复late停止快照：最终stop改在payload/facts真实关闭、final proof回调之后重新读取；facts.close时CANCEL不能误标staged。等待响应头时先处理已观察到的停止，不把停止触发的断流/迟到200误判资源不安全；完整prefix复制与input获取之间的暂停跳过失效连接获取，仍等待双close及proof提交。
- 新增7项真实loopback/文件主机回归：复制Stopped+payload close失败、Stopped+disconnect失败、facts.close内late CANCEL、等待响应头迟到200、周期proof后的facts close失败、第二次proof commit失败、prefix复制后实际disconnect完成再暂停（latch等待、双close先于proof）。原有内部第二core从新offset Range继续、逐字节/wholeSHA256、24576原件与未提交tail、CANCEL>PAUSE及progress失败均保留。无sleep代替时序，不把host回调当生产Coordinator验收。
- v5回调真实注入且复用v4所有冻结命令/source worker/ref/version门；candidate/facts在同operation事务先登记、再CREATE_NEW/NOFOLLOW；周期双force、final双close之后才认证。offset单调、同offset digest一致、total后续固定、算法/URL/ETag不混合；phase只允许copying写proof，staged后拒绝。精确inspectCandidate不混入inspectResume，不晋升branch或调度网络。设备测试补原source total未知→实际206建立known total、跨task拒绝/跨generation返回null及重开精确查询；15项仍仅编译。v4→v5第二DDL失败回滚第一DDL/版本和保历史断言保留。
- 最终独立Gradle既有JBR且sdkDownload=false运行testDebugUnitTest+compileDebugAndroidTestKotlin+assembleDebug正常退出0，/tmp/android-candidate-check-gradle.log；JUnit XML70=Protocol5+HTTP20+Coordinator15+Lifecycle7+Resume23，failures/errors/skipped均0。首次检查编译因Throwable与StageFailure的Exception参数类型不匹配失败，已修正，/tmp/android-candidate-check-first-failure.log保留，不称全部首跑成功。flutter analyze正常退出No issues found，/tmp/android-candidate-check-analyze.log。Dart未改，沿用前轮独立102项，不称重跑；adb无设备，未启AVD/装SDK/改license。
- 备份android-candidate-review-_x4kjmd6可访问，599文件manifest差异仅允许文件（含journal自动格式化），protected10全部匹配；git diff --check干净，暂存为空。未stage/commit/push/archive或改PRD/task.json/其他规范/既有.pi/docs。PRD全未勾，任务in_progress。
- 本前置源码局部PASS；公开resume与完整引擎/设备总体BLOCK。下一轮最小接受事务应同时冻结不可变source proof/ref/历史版本N和新worker授权，queued回执推进到N+1只更新新授权版本；后续worker回调按新授权/current版本核验，不再要求历史source版本等于新head，也不能全局放宽v4门。显式新session用户命令才可记录旧授权retired/waitingRecovery，真实finished与授权退休分开，不由inspect或存在文件推断。该事务连同Coordinator/Service恢复worker、停止/终态补存、branch晋升及生产resume入口回归应作为下一交付一起闭合，避免再次只交helper。候选继续/废弃/受控释放、设备SQLite/Service/磁盘故障/API矩阵、目录fsync/用户发布和真实>4GiB仍待验收。

## v5 候选材料检查点规范同步与提交（2026-11-04）

父代理核对完整独立报告与ResumeTransfer实际差异：Stopped/close优先级、双close后late CANCEL、响应头停止和复制后已断连input门均保留。独立70项JVM（5+20+15+7+23）零失败/错误/跳过、Gradle实际正常退出并构建debug APK、analyze干净；Dart未改沿用前轮102项，15项SQLite instrumentation仅编译。前置局部PASS，不是公开resume或设备验收。

frontend architecture/index与源design同步v5双候选表、inspectCandidate分支、周期双force/final双close及错误/停止优先级；七节契约和Markdown本地链接/围栏/尾换行通过。599文件审查基线仅授权代码/测试/任务记录及本轮三份规范不同，protected10匹配、暂存为空、diff检查干净。提交仅本任务7个实施文件与3份规范，排除既有.pi和docs；不归档、不勾PRD，父任务完成数仍1/7。

下一轮必须从生产Coordinator.resume验收：acceptResume原子冻结源证明版本N、queued N+1/不可变接受结果/独立新worker授权；运行时确认无当前活动worker后仅显式新session用户命令可退休旧授权，真实finished与retired分开。沿用ServiceLifecycle及2worker，接实际恢复worker与当前branch晋升、pause/cancel、持久事件和resume终态本地补存；真实paused→resume→再次pause/continue、幂等/旧身份/未知结果及保存重试零额外GET均需回归。不能再把只加helper作为公开接线交付。

## 公开resume生产链检查点（本轮v6，完整平台仍BLOCK）

- 生产路径已接：既有channel.resume→TransferCoordinator.command(resume)→同Work/ServiceLifecycle ready/token/instance→全局两worker池→ExecutionJournal.newResumeTransfer→真实ResumeTransfer→原生日志→EngineEvent；未增加第二恢复调度器。enqueue/pause/cancel和Service实例握手保留，DownloadService/ServiceLifecycle/manifest不变。
- acceptResume同一事务登记不可变完整命令、queued N+1结果与新worker授权，并在resume_sources冻结source root ref/完整proof JSON/历史版本N。expected head与source历史版本分开；后续使用新worker/head验证，历史snapshot及原生材料归属独立重验。active_branches只在candidate认证事务中晋升，明确指定同执行当前branch，不按文件长/时间猜；其source ref对应既有operation/candidate证明。v4内部newRecovery所有旧门保留，只复用底层回调。
- v6增resume_sources、active_branches、retired_workers，保留v1-v5历史；SQLiteOpenHelper DDL/版本事务回滚。Coordinator当前进程无该key Work时才接受；新真实Runtime session显式命令可将旧未finished授权记录waitingRecovery退休，旧finished字段不伪改。inspect/open/旧Intent不退休/调度。原生input和URL由日志读取，不接受channel路径/URL作为恢复源。
- 恢复候选完整prefix双force/final双close后才持久晋升；同一Stop贯穿认证/复制/网络，用户stop先持久再信号，CANCEL不推进proof。GET前及candidate登记会再次检查持久stop并以Stopped事实退出；诊断Stopped.bytes不当进度。Stopped不能掩盖真实关闭/断连失败。恢复worker的pause/finish复用workerStop/workerReceipt/finishWorker，新worker授权而非旧enqueue；终态失败保留冻结Work，对同完整resume/pause只补本地事务，不再GET/copy/分配。正常ack不删除，release继续拒绝，cancel仍cleanupFailure，完整私有文件仅publishing。
- 回执仅由已有认证branch提供supported/opaque ref；无强ETag/缺proof仍restartRequired。HTTP不安全206门/本地prefix损坏产生stateConflict并保留restartRequired reason，不误归fileWriteFailure。Dart及共享DTO/API/schema未改。
- 直接生产Coordinator的新增7项JVM回归：真实enqueue→pause(unknown total)→安全206→再pause新candidate→再次resume→publishing，逐字节/整文件SHA256正确；原source24576含未提交tail及旧candidate均不变；resume终态保存失败→inspect保存失败→同命令补存，GET仍3/candidate仍2；200/416/ETag/Range拒绝；prefix损坏零GET；queued pause/cancel无worker/网络；同池全局2限制及重复resume不新增worker；new Runtime无命令零请求、显式当前session才恢复。Journal为明确host fake，网络/文件/HttpTransfer/ResumeTransfer/Stop/Coordinator为生产代码。
- 最终原生正常退出0：android/ JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew -Pandroid.builder.sdkDownload=false :app:testDebugUnitTest :app:compileDebugAndroidTestKotlin :app:assembleDebug；/tmp/android-public-resume-delivery-final2.log，BUILD SUCCESSFUL in 3s、144 tasks。JUnit77=Protocol5+HTTP20+Coordinator22+Lifecycle7+Resume23，failures/errors/skipped=0。17项SQLite instrumentation仅编译：新增原子接受/queued+source+授权失败回滚/版本分离/多branch再暂停继续/显式新session退休/unknown不重放，以及v5→v6第二DDL失败回滚；旧迁移fixture更新至6。adb无设备，绝未声称跑过真实SQLite。
- flutter analyze正常退出No issues found，/tmp/android-public-resume-analyze.log；Dart未改，沿用前轮独立102测试，不声称本轮重跑flutter test。失败过程保留：/tmp/android-public-resume-tests.log有2个新网络暂停测试超时及1个原基线response门SocketTimeout；新测试改为先排stop再释放真实server EOF屏障（不承诺平台disconnect即时打断）。/tmp/android-public-resume-final.log有cancel Future错误先于同queue finish的测试竞态，加queue屏障后正常。其后最新完整构建/XML覆盖全部源码；不是把超时当通过。
- 平台/验收残余：本轮已交付生产入口和核心多次恢复闭环，但尚需独立复核v6事务与native callback完整绑定；新prefix/copy阶段stop、resume force/close/Journal错误及CANCEL竞争虽有既有真实core回归，尚缺这些barrier全经Coordinator的逐项组合验证；SQLite并发接受及设备Service/权限/强杀/API矩阵未跑。known-total且已认证offset==total的暂停材料当前保守restartRequired，不自动本地发布。真实>4GiB、目录fsync、磁盘故障、受控清理和用户目录发布均未闭合。PRD未勾，任务in_progress，完整Android与平台仍BLOCK。
- 保护10项hash匹配，git diff --check通过、暂存空；只改允许原生包/测试和本任务design/implement。既有.pi两修改/docs保护；未stage/commit/push/archive、未改task.json/PRD/frontend/source specs/共享API/依赖/SDK/manifest，未开AVD/装SDK/改license。

## v6公开resume独立检查（2026-11-04，源码局部PASS／设备仍BLOCK）

- 按当前check.jsonl、PRD、设计v6完整章节、implement本轮完整记录及实施report核验；规范仍是v5已通过状态，未擅自同步。原check因provider502/EOF中断，不是源码失败结论；本恢复沿用已完成审查与80项验证，未重做旧基线/网络研究。
- 独立对照生产channel→同Runtime队列→acceptResume→同ServiceLifecycle/双worker→newResumeTransfer→真实ResumeTransfer→Journal→EngineEvent。acceptResume同事务固定历史source/ref/版本N、完整proof与queued N+1/不可变命令结果/新worker授权；worker回调用新head，历史source独立重查。原v4工厂完整门保留，完整task通过execution/原生materials/forced.key核对；不是只信FK(engine,generation)。旧session未finished仅显式当前用户resume且本进程无Work时退休，finished不伪造；inspect/open/旧intent/NULL结果不退休或联网。
- 源修复一：newResumeTransfer的staged回调原先只validate授权而未拒绝持久pause/cancel，可能在terminalStop快照之后的队列竞争把迟到candidate记staged。现与GET前/登记门一致，在同事务读取stop并返回Stopped，不能撤销持久取消/暂停。proof已有持久cancel拒绝门保持，branch仅双force/final双close后晋升。新增真实Journal instrumentation在proof与staged边界注入持久cancel，原件/phase/proof不误晋升；仅编译，未运行SQLite。
- 源修复二：已finished worker重放原终态时，原实现重新从最新active branch装饰旧checkpoint；后续resume晋升branch后会错误拒绝同checkpoint。现使用该历史receipt已提交的派生resumeSupport/ref，仍精确比较全部非派生checkpoint字段、完整worker和pause命令结果，不新分版本。已有真实Journal多branch测试补旧terminal再次重放、改变bytes拒绝及head不变；仅编译。
- 新增3项Coordinator测试（共25项）：①prefix认证/复制两个阶段分别PAUSE/CANCEL的四组合，确定latch等待持久stop再释放真实core，0/1GET及0/1partial candidate、旧proof/24576源tail不变；②复制暂停时payload关闭失败必须failed/fileWriteFailure，不能paused；③final proof提交屏障中pause后的Journal失败必须failed/persistenceFailure、持久cancel不晋升proof并保持cleanupFailure重放。Journal为host fake，真实网络/磁盘/Coordinator/Stop/ResumeTransfer；显式标注fake的持久stop检查，不能代替SQLite。ResumeTransfer只增加默认空的认证/复制观察hook以将既有真实core屏障接到生产Coordinator测试，默认运行行为不变。
- 原7项生产Coordinator恢复回归独立复跑：unknown total→pause8192→public resume→pause16384→public resume→publishing，3GET/2candidate、逐字节/wholeSHA256与原source/旧candidate不变；unsafe200/416/ETag/Range/坏prefix、queued stop、全局2/单执行1、旧session/NULL/重复与terminalSavePending本地补存均保留。resume桥接确有ExecutionException解包，早先因截断输出误判已更正，未改该桥接。
- 最新源码最终Gradle：既有JBR、sdkDownload=false运行testDebugUnitTest+compileDebugAndroidTestKotlin+assembleDebug，正常退出0、BUILD SUCCESSFUL in5s，/tmp/android-public-resume-check-gradle.log。XML80=Protocol5+HTTP20+Coordinator25+Lifecycle7+Resume23，failure/error/skipped全0；18项instrumentation仅编译。flutter analyze正常退出No issues found（1.4s），/tmp/android-public-resume-check-analyze.log；Dart未改，沿用独立102项，不称重跑。adb无设备，未启AVD/装SDK/改license。
- 两份审查备份均可访问。与最初592文件manifest比较，仅允许的ExecutionJournal/ResumeTransfer/Coordinator测试/SQLite测试及本implement变化；Journal自动格式化/语义修复均在授权范围。两份protected10逐项使用实际文件路径核对全MATCH（含untracked docs图片），暂存空、diff --check干净、PRD/task.json无diff；未stage/commit/push/archive或碰其他规范/任务/既有.pi/docs。
- 本轮公开resume生产源码局部PASS，无剩余本轮实质源阻断；Android平台/完整PRD仍BLOCK且全不勾、任务in_progress。host fake不能证明真实SQLite事务/并发接受/迁移或Android MethodChannel/Service执行；仍需API29/30/33/35/36、权限/强杀重开/TLS、真实磁盘force-close、目录fsync/受控清理/用户发布/真实>4GiB验收。known-total且offset==total材料仍保守restartRequired，未偷偷从零或本地发布；多Session数据库及同UID恶意写入不在当前单进程私有sandbox证明范围。

## v6 规范同步与检查点提交（2026-11-04）

- 父代理已读取恢复检查完整报告，核对最终 JUnit XML80（5+20+25+7+23）零失败/错误/跳过、Gradle正常成功与analyze日志；原592文件审查清单仅5项审查授权差异，protected10全部匹配，暂存为空。
- frontend index/architecture 与源 design 已同步公开 resume 生产链、v6 三表/迁移、冻结 source N 与 worker N+1、显式旧授权退休、branch晋升、持久stop/staged门、历史终态幂等和resume本地补存；任务 design 记录复核结论。
- 本轮按既有直接提交授权仅提交本任务原生实现/测试、任务 design/implement 和三份规范；排除既有 .pi agent 修改与 docs/。这是检查点，不勾PRD、不归档，父任务仍1/7。
- 下一轮先核对既有取消/ack调用方，设计停止后且归属明确的材料释放、持久清理意图和部分删除幂等；普通ack不释放、旧确认不删新材料、失败保持可追踪与可重放，不从未知路径猜删。设备矩阵与真实SQLite验收继续BLOCK。

## v7 生产取消与归属清理检查点（本轮，等待独立复核）

- 已接生产 channel.cancel→同 Runtime 串行 Coordinator→beginCancel 持久意图/完整原生归属快照→CANCEL→真实 run 退出与终态提交→finishCancel 整集合预检/逐成员清理→持久成功回执；无 Work 的 paused/failed/旧进程显式取消只本地退休旧授权和清理，不创建 Service/GET。未知 NULL 命令不重执行，完整重复命令只等待原退出或恢复本地清理。非 cancel 的 terminalSavePending 必须原 enqueue/resume/pause 显式补存，再以真实新 head 取消，拒绝由未核验 cancel 触发补存。
- 日志 v7 新增 cancel_cleanups/cancel_cleanup_members，保留 v1–v6。commands.result 冻结接受事实；清理完成结果单独不可变，瞬时清理/最终保存失败保留 pending 与完整成员及 done 标记，登记 missing 可重放。v6 历史 cleanupFailure 不重写，需要当前 session/head 新 cancel；旧确认不授予新材料删除权。全部原件/facts、已登记 candidate/facts 来自原生日志并重核完整 key/源归属。全集合 canonical 私有目录/UUID配对/NOFOLLOW普通文件检查先于任一删除，未知孤儿不碰。
- 实际 stop/close/Journal 错误保留到终态 error，初次 cancel 不伪成功，finishCancel 拒绝带真实停止错误的 head。持久 cancel 阻止迟到 proof/staged，finished/retired 阻止旧 callback 再认证；终态补存及历史分支幂等既有测试保留。事件只在数据库提交后发出。非空 ack 继续保守拒绝：缺原生日志可核验的发布完成/确认重下意图，当前 publishing 只是私有 staged。Dart 与共享 AppStore/接口未改，原生仍是可信调用方边界。
- 最终 android/ 既有 JBR 执行 ./gradlew -Pandroid.builder.sdkDownload=false :app:testDebugUnitTest :app:compileDebugAndroidTestKotlin :app:assembleDebug 正常退出0，BUILD SUCCESSFUL，/tmp/android-cleanup-verified-final.log。86项JVM（Protocol5+HTTP20+Coordinator28+Lifecycle7+Resume23+Cleanup3）全0 failure/error/skipped。新增生产 active cancel 真socket等待退出后删除/重复等待与重放、queued零worker取消/意图与清理失败重试、无Work旧Runtime显式取消零launch并保留未知孤儿；核心覆盖最后一项非法/文件与目录symlink零删除、部分删除IO故障和missing幂等。Coordinator Journal明确为host fake，不当SQLite证据。
- Android SQLite instrumentation从18增至20，仅编译未运行：v6→v7保留/第二DDL失败原子回滚；真实表级清理意图触发器失败零删除/旧回执保留、原件与copying candidate完整集合/源归属、stop未finished拒绝、重开零清理、symlink零删除、最终receipt触发器失败pending与missing重放、commands接受结果不变及重复完成结果。既有迁移fixture更新至v7。尚未新增v7跨连接清理竞争设备断言；Runtime生产串行边界为当前排他依据。
- flutter analyze正常退出No issues found，/tmp/android-cleanup-analyze.log。Dart未改，未重跑前轮独立102项。adb devices -l无设备；未启AVD/安装SDK/改license。早期Kotlin SQL混合参数类型编译失败（first/second日志）已修正，fourth日志新增测试因非canonical临时根/非法空URL夹具2失败，修正夹具后最终86通过；不将这些失败或超时记成功。
- protected.json 10项实际SHA256全MATCH（含既有.pi修改与docs图片），git diff --check通过，暂存空；未stage/commit/push/archive/改task.json/PRD/源规范/frontend规范/Gradle/manifest/共享模型/其他平台。新增与修改仅授权Kotlin包/JVM/androidTest及本任务design/implement。
- 本轮是可审查生产取消最小闭环，不是完整Android验收。完整PRD/平台仍BLOCK；需要独立审查及设备SQLite/Service/通道/权限/kill/API29/30/33/35/36、真实force/close/磁盘故障、目录fsync与同UID并发替换保证、真实>4GiB和用户目录发布。非空release ack分支未开放；v7跨连接清理竞争/所有generation组合及取消close错误完整入口矩阵未逐项新增，保留既有核心安全回归。

## v7取消与受控清理独立复核（2026-11-04，源码局部PASS／设备与完整PRD仍BLOCK）

- 已按check.jsonl六项、PRD、任务design/implement及完整实施report独立审查本轮九文件和真实调用链；源规范仍为已通过v6，未同步或改PRD/task.json。核对自动格式化之外的语义差异，未放开非空release ack、发布或确认重下分支。
- 修复cleanupMembers的恢复归属缺口：此前先按resume命令key跳过，可能遗漏source root属于本key但命令key冲突的已登记candidate。现任一归属边关联本key就必须双向一致；candidate_checkpoints若存在，其resume/source/facts须与operation一致。扩展既有SQLite测试，验证beginCancel嵌套事务在归属失败时全回滚、零删除，finishCancel重新核验后才删除；这20项instrumentation仍仅编译。
- 修复活动cancel完整重放用Map.equals误拒绝Int/Long等价载荷，复用原终态补存的递归语义比较，仍由Journal核对持久完整载荷。新增真实socket/file回归：活动cancel终态提交失败保留配对材料、错误session/期望版本不补存、Int/Long等价重放及两个串行重试只本地完成/固定结果，HTTP=1、launch=1；Journal明确host fake。另新增生产Coordinator→真实ResumeTransfer复制取消伴随真实close helper抛错，终态保留fileWriteFailure，原件/candidate保留且不调用成功清理。
- 最终Gradle完整命令在android/和既有JBR下、sdkDownload=false正常退出0，/tmp/android-cleanup-check-gradle-final3.log，BUILD SUCCESSFUL in3s。最终XML88=Protocol5+HTTP20+Coordinator30+Lifecycle7+Resume23+Cleanup3，failure/error/skipped全0；AndroidTest Kotlin编译与debug APK构建通过。首轮86通过；新增补存测试首次等待精确8192进度超时（TCP分片及进度合并不保证该样本），改等待首个正字节持久事件后通过，失败日志/tmp/android-cleanup-check-gradle-final.log保留。此后final2为87通过，新增close回归后final3为88通过。
- flutter analyze正常退出0、No issues found（1.4s），/tmp/android-cleanup-check-analyze.log。Dart未改，沿用前轮独立102项，未重跑flutter test；adb devices -l为空，未装SDK/改license/启AVD。SQLite迁移/触发器/并发与Service/通道设备结果不由源码或编译代替。
- 父提供review备份594文件清单除本次授权Journal/Coordinator及其测试、本任务记录外保持一致；protected10实际路径SHA256全MATCH，git diff --check干净，暂存空。未stage/commit/push/archive或改源规范/frontend/.pi/docs/其他平台/共享DTO/依赖/配置。
- 当前v7生产取消源码局部PASS，无剩余已知本轮源码阻断；完整Android/PRD保持BLOCK且不勾。只承诺单Runtime串行门与诚实sandbox；文件集合不原子、无目录fsync或恶意同UID替换保证。v7跨连接清理竞争、全部generation/故障组合、设备SQLite/Service/权限/强杀/API29/30/33/35/36、实际磁盘force/close故障、真实>4GiB和用户目录发布仍未验收。Repository未实现，不能称取消项已从业务列表移除；最终验收由父代理保留。

## v7 父代理核对、规范同步与检查点（2026-11-04）

- 检查进程在1800000ms上限终止，但指定完整报告及结构化acceptance已保存；父代理直接核对报告、最终JUnit XML88项全0、Gradle/analyze日志与源码，不将超时状态本身当通过，也未重复运行已完成检查。
- 核对cleanupMembers双向归属、beginCancel/finishCancel持久清单及OwnedMaterialCleanup整集合校验；规范index/architecture与源design同步为v7，保留20项SQLite仅编译和设备/完整PRD BLOCK。
- 检查点只提交本轮原生实现/测试、任务design/implement及三份规范；不包含既有.pi修改与docs下任何路径，不stage未知docs/.trellis产物。不归档、不勾PRD。后续优先取得真实Android SQLite/Service设备证据；用户目录发布由file-storage任务承接，不能以本地清理通过跳过平台安全门。
