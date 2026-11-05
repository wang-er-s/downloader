# Flutter 界面实施计划

## 依赖与准备

按用户继续完善其他功能的授权，在 Repository 局部独立检查与检查点 b8b2082 后激活；前序任务仍保留未验收缺口，不能据此宣称完整安全原型或平台通过。先逐张读取 docs/ 七张参考图，加载 Flutter/UI 规范和设计技能；已有资料决定布局。

- [x] 已核对lib/main.dart、Widget测试及真实仓库接口。
- [x] 已组装app、Riverpod与主题并替换旧首页及测试。
- [x] 已实现下载分类/列表、进度、空态和任务操作及确认反馈。
- [x] 已实现下载/缓存表单及设置/目录选择，沿用共享校验。
- [x] 已接入错误、局部busy、恢复提示及宽窄窗口/大字体/键盘/语义；桌面退出仅macOS接线及Dart回归。
- [ ] 跨平台smoke、系统退出实际交互和完整视觉/无障碍验收仍缺；本机创建/暂停局部通过。

## 检查

flutter analyze、flutter test。Widget 覆盖真实状态订阅、分类数量、表单取消/校验、重下与删除选择、读取失败、未知总长及 publicationUncertain；Provider 测页面释放不会取消引擎。

按七张截图核对核心内容和交互。大字体、长链接、窄桌面、软键盘、焦点/屏幕阅读器及主题切换分别验证；真实 Engine 完成创建→暂停→继续→保存→打开/删除流程，缓存与目录设置重开一致。

## 停点与回滚

fake 数据仅用于隔离 Widget 测试，不冒充可运行业务。依赖或平台安全问题不能由 UI 藏错/伪造状态；仅回退本任务的界面变更，不清除存储和文件。

## 激活与本轮生产边界（2026-11-05）

以三个真实 Repository、AppStore v2、已有 Engine/FileStorage 为应用级依赖，接入 Riverpod 和中文界面；不改底层契约以适配 UI。允许实际解析兼容的 flutter_riverpod，桌面退出优先复用 Flutter/原生已有机制，必要平台接线先记录方案。页面退订不关闭引擎，应用初始化失败给出错误与显式重试。
从零重下 restartUnsupported、Apple/SAF 删除及临时副本回收等缺口必须如实反馈，不伪造成功或取消后新建模拟。目录选择取消保留原值，当前设置仓库不校验授权，调用方使用已有平台选择能力。Android 设备由用户测试，本轮不跑模拟器/设备；Windows/iOS/最低版本无环境不计通过。
本轮要求真实可运行入口、Widget/Provider 自动化与本机 macOS 真实 Repository 流 smoke；实施后独立检查、规范同步及授权提交。PRD 未满足项不勾选，不归档。

本轮执行：先最小依赖与真实错误/重试入口，再三分类/操作/配置设置，然后 Widget/Provider、顺序 analyze/test，最后 macOS 真实 UI smoke 与截图。共享 guides/index.md 当前不存在，按已读 frontend 规范实施。所有未知能力保留明确错误，PRD 不勾选。

## 本轮实现与验证结果
已接入真实应用依赖、三个仓库 StreamProvider、只存操作状态的 Notifier、中文下载/设置、三类数量、下载/缓存表单、任务菜单、未知进度、错误与发布恢复入口。macOS AppDelegate 最小扩展获主管授权，代理转发原窗口委托；close/Quit 合流到 Dart 确认、退出锁、真实暂停保存与最终活动项重查。
实施阶段历史结果为analyze exit0、153 Flutter用例及1项真实UI smoke（GET=1/524288字节paused）。它们由下文独立最终155项与557056字节结果更新；保留历史日志，不重复累计为独立新增证据。
实际运行 RenderRepaintBoundary 帧 /tmp/download-ui-impl-actual-render.png 已读图检查：深色桌面三分类与真实 paused 卡片无覆盖。系统 screencapture /tmp/download-ui-impl-real-macos.png 全黑且 open foreground 返回1，不算系统窗口截图通过。macOS 原生 close/Quit 已编译但无系统菜单/红钮实际操作证据；Dart 通道回归覆盖 pending 拒绝、取消、暂停失败拒绝、真实回执成功后放行与创建锁。Windows 无原生退出接线证据；Android用户负责，iOS/Windows/最低版本未验证。
保留限制：Repository 无单调样本公开给 UI，速度/ETA显示未知；从零重启、响应命名/最终URL、Apple/SAF安全删除等底层缺口未改。屏幕阅读器真人操作、七图全部实机截图、全平台正常退出仍需后续验收。未stage/commit/归档，PRD保持未勾选。

独立检查修复：feature Provider以具体Repository/FileStorage命名record注入，移除app反向import；取消使用独立busy键并保留菜单入口；Notifier异步返回先检查ref.mounted，成功不清除其他并发失败。应用初始化清理保留首异常并尽力释放每个资源。主管明确授权PluginEngine.open失败清理与close幂等、固定callback group单活实例所有权，增加真实损坏日志初始化失败→修复数据→retry及第二实例拒绝不误清首实例回归；未改传输/发布/ack/schema。原生退出回复增加CFBoolean严格核验，Dart确认后检查mounted、放行前重验剩余busy和活动任务。
独立最终顺序 /tmp/download-ui-check-final-analyze.log exit0、final-test.log exit0共155项（原153＋2取消/销毁回归）；plugin.log exit0共2真实macOS集成项（含新增初始化失败/重试）；final-smoke.log exit0共1真实UI集成项，GET=1、557056字节paused且SQLite回执一致。host12仅临时xcconfig，未改最低目标。联合两集成文件首次运行第二个host启动失败exit1，拆分独立运行均通过；新增Widget初稿pumpAndSettle受不确定动画影响，改为有限帧和菜单可用性断言后通过。
已逐张读取七张docs参考图及实施旧渲染、本轮实际RenderRepaintBoundary渲染，桌面深色布局可读；不冒充系统窗口/close/Quit实际交互或其他平台验收。任务仍BLOCK，PRD不勾选，不stage/commit/archive。

## 本轮规范同步（仅文档）

- [x] 加载trellis-update-spec、独立检查报告、当前任务及正式相关规范，核对实际源码签名与锁定版本。
- [x] 新增七节[UI规范](../../spec/frontend/ui.md)，同步架构、插件、仓库、文件、源设计及上下文清单；持久化规范已准确为四表v2，无必要改动，源设计SQL保持原样。
- [x] 保留独立局部PASS与整体BLOCK/in_progress边界，PRD未勾选；复用`/tmp/download-ui-check-final-{analyze,test,plugin,smoke}.exit`全0，不重跑产品测试。

本轮文档校验及受保护文件哈希比对结果随外部交付报告提供；未修改产品代码/配置/依赖、PRD、task.json、requirements、review、.pi、docs或其他任务，未stage/commit/push/archive。

## macOS 默认部署基线修复（2026-11-05）

- [x] 检查应用工程三配置、xcconfig、Info.plist 和当前 macOS 依赖/Flutter Swift Package；应用部署版本统一 12.0，生成 Package 由 Flutter 自动同步，不改依赖及其他平台。
- [x] 移除 XCODE_XCCONFIG_FILE 与 MACOSX_DEPLOYMENT_TARGET 环境覆盖后执行 `flutter build macos --debug`，exit0；`/tmp/download-ui-macos12-build.log` 与 `.exit` 保留证据。产物 LSMinimumSystemVersion/minos 均为 12.0。
- [x] 同步任务设计、正式 frontend 入口和源设计当前基线；历史临时 host12 和 10.15 未验证记录原样保留。配置修复无需新增镜像测试。
- [ ] macOS 12 实机、release、系统 close/Quit 和其他平台验收仍未完成；PRD/task.json 不变，不 stage/commit/push/archive。

独立部署核查：项目级 Debug/Profile/Release 均为 12.0；Runner、RunnerTests 与 Flutter Assemble 无目标级部署覆盖，xcconfig 链无额外部署值。清除 XCODE_XCCONFIG_FILE/MACOSX_DEPLOYMENT_TARGET 后，分别只读执行三配置 Runner 的 xcodebuild -showBuildSettings，均 exit0 且有效值 12.0。复核既有默认 debug 构建日志与 .exit=0；实际 downloader.app 的 LSMinimumSystemVersion=12.0、主 Mach-O LC_BUILD_VERSION minos=12.0。五文件差异仅调整当前基线并补充证据，历史 host12/10.15 未验证结论保留；无阻断缺陷。不重跑构建或 Dart 测试，Profile/Release 仅核查配置，不计构建/运行通过。

## 应用图标替换（2026-11-05）

用户批准生成并替换图标，主会话直接处理。原图保存在 assets/branding/downloader-icon.png；替换 Android 五档 mipmap、iOS AppIcon 15张、macOS AppIcon 7张及 Windows 多尺寸 ICO，共28个现有资源文件，沿用 Manifest/Contents.json/Runner.rc 引用，无新增依赖或业务代码。iOS 转为不透明 RGB 并补满蓝色底，其他平台保留透明背景，原始图片不改。
Pillow 断言核验全部目录尺寸、iOS 无 alpha、Android 密度与 Windows ICO 的16/24/32/48/64/128/256尺寸通过。清除临时部署环境覆盖后 flutter build macos --debug exit0，产物 downloader.app，日志 /tmp/downloader-icon-build.log。本轮仅资源替换，不重复 Dart 测试；Android/iOS/Windows 构建及各系统桌面图标缓存表现未实机验证。
