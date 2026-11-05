# Flutter 界面设计

## 前置与范围

依赖 Repository 检查点 b8b2082 的稳定业务 API，按用户授权继续 UI；前序完整 PRD 和平台验收仍未完成。从零重下、Apple/SAF 删除等缺口保留并真实反馈，不能通过 UI 模拟。按[源设计](../../../.agents/specs/download-manager/design.md)和[截图评审](../../../.agents/specs/download-manager/review.md)呈现已确认交互，不重新做产品风格选择。

## 结构

app拥有AppDependencies，组装入口、主题和真实功能依赖；通过`.presentation`暴露具体DownloadRepository、SavedDownloadRepository、SettingsRepository、FileStorage命名record，ProviderScope注入。features禁止反向import app；不增包装接口。三个StreamProvider各订阅对应仓库流，业务数据唯一来自仓库；Notifier只存busy/error，分类/数量派生。局部输入/当前分类留Widget。实际签名和七节断言见[UI规范](../../spec/frontend/ui.md)。

## 交互

下载与设置两个入口，三类下载分类；failed/paused/waitingRecovery/publishing 仍归下载中。新建/编辑字段共享校验，保存配置不执行。删除默认记录-only，删除文件和从零重下明确确认。未知总长保留真实字节，不显示假百分比/剩余时间；系统无新事件不伪造速度。

移动弹窗避让键盘、可滚动；窄桌面采用紧凑导航，宽屏分配列表空间。长名称截断后可查看，支持字体缩放、语义、焦点和键盘操作。桌面关闭窗口/菜单退出走协调流程，活动任务先确认停止；不增加托盘。

## 失败与验证

读取失败不当空态；操作等待与业务状态分开；发布 uncertain、权限、空间、清理失败有可行动反馈。Widget 测试验证交互和语义，平台真机/桌面截图验证布局与关闭流程，不能只用 golden 图宣称下载通过。

## 回滚

替换计数器首页及旧 smoke test 与业务入口一起进行；不修改底层安全契约以适应页面。保留原用户资料，UI 回滚不删除任务或用户文件。

## 本轮最小实现记录
应用级 AppDependencies 初始化 AppStore v2 → 平台 Engine → 执行 journal 对应 FileStorage → Settings/Download/Saved Repository。Provider 仅订阅三个仓库流；Notifier 只保存操作等待集合及错误，不复制业务集合。速度暂显示未知：Repository 快照不携带合法单调样本，不旁路订阅引擎。页面退出不释放业务依赖。
沿七图的灰紫 Material 配色、上方三分类、下载卡片、底部下载/设置、圆角表单。弹窗滚动并使用标准键盘避让，目录选择只经 Controller。桌面退出采用 AppLifecycleListener 与宿主真实接线验证；未验证不宣称拦截成功。
调用方与配置范围：main/app、三 feature presentation、Widget/Provider 测试与 download_ui 集成测试；pubspec/lock 仅解析 flutter_riverpod，无 SDK/override/底层 API 改动。测试 fake 只隔离 Widget；真实集成使用现有 Engine/FileStorage/SQLite。

主管已授权 macos/Runner/AppDelegate.swift 最小接线：保留 FlutterAppDelegate 启动及插件生命周期；NSWindowDelegate 代理转发已有委托方法，仅拦截关闭。窗口关闭/Quit 共享进行中请求，Cocoa 主线程异步询问 Dart；非法/缺失回复拒绝。Dart 确认期间锁定新提交与继续，等待实际 pause 后重查任务与 busy，明确 bool 成功才退出。Windows 原生退出接线本轮未扩展。

独立检查获主管最小扩围授权：AppDependencies.open 的显式retry要求 PluginEngine.open 对取得的执行DB、回调与timer在失败时释放，保留首异常；close须部分初始化及重复调用安全。固定callback group仅允许一个活实例，第二实例结构化拒绝且不移除首实例回调，不停止现有网络/系统任务，不改执行、确认、发布或恢复语义。feature provider改为具体Repository与FileStorage命名record注入，禁止反向import app；取消有独立busy键，仍经原Repository优先取消。

## 规范同步与保留门槛

本轮仅文档，复用独立最终analyze exit0、155 Flutter、2真实macOS Plugin集成、1真实UI smoke（GET=1/557056字节paused/SQLite一致）产物，不再跑产品测试。AppDependencies初始化顺序及首异常保留、具体record、三仓库流、独立cancel busy、ref.mounted、PluginEngine固定group单活owner/失败清理/幂等close、macOS CFBoolean与Dart最终重查已同步至正式规范；AppDependencies.close自身未承诺幂等。

保留速度/ETA未知、restartUnsupported、响应文件名/最终URL、Apple/SAF删除及Apple用户目录临时副本缺口；Windows退出未接线，macOS红钮/Quit无实际操作，系统截图黑屏不作通过。host12仅临时目标；Android设备用户负责且本轮运行0，iOS/Windows/最低版本未验收。UI整任务仍BLOCK/in_progress，PRD不勾选，不stage/commit/push/archive。

## macOS 默认构建兼容修复（2026-11-05）

用户直接运行默认 macOS 构建遇到 Xcode 不支持原候选 10.15，授权应用最低版本改为 12.0。Runner 工程项目级 Debug/Profile/Release 三处统一为 12.0，目标继承项目配置，Info.plist 继续引用 MACOSX_DEPLOYMENT_TARGET。xcconfig 无额外部署覆盖；Flutter 自动生成的 Swift Package 同步为 12.0，不手改生成文件、依赖或其他平台。此前 host12 临时覆盖仅为历史局部证据，不能追认为 10.15 已验证。

本轮移除 XCODE_XCCONFIG_FILE 与 MACOSX_DEPLOYMENT_TARGET 环境覆盖，默认 `flutter build macos --debug` exit0；Info.plist LSMinimumSystemVersion 和 Mach-O minos 均为 12.0。日志 `/tmp/download-ui-macos12-build.log`，退出码 `/tmp/download-ui-macos12-build.exit`。当前主机为 macOS 27.0.1；macOS 12 实机、release 和系统退出等原未验收项继续保留，完整任务仍 BLOCK/in_progress。
