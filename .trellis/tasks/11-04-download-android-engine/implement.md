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
