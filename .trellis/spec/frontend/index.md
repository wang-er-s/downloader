# Flutter 前端规范

## 适用范围与当前状态

适用于本仓库 Flutter 应用及各平台适配：Android、macOS、Windows 为必需平台，iOS 为希望一并提供、需验证可行性的平台。采用按功能组织目录、MVVM 职责划分、Repository/Service 分层，Riverpod 负责状态管理与依赖注入。复杂业务按需提取 UseCase。

领域/执行 DTO、DownloadEngine、FileStorage、AppStore 四表 v2 与三个 Repository 已实现；Plugin commands.sqlite v2、Android execution v8，普通/旧 ack 不删完整源。前序文件阶段57 focused、macOS5引擎＋9文件集成、93 JVM通过；22项 Android v8 instrumentation仅编译，旧 API37 v7 设备结果不证明 v8。Repository 阶段141项及1项真实macOS smoke为历史局部证据。

Riverpod 3.4.3、Provider、中文业务 UI 和 AppDependencies 已接入，见[UI 契约](ui.md)。UI 独立最终 analyze exit0、155 Flutter用例、2项真实macOS Plugin集成、1项真实UI smoke通过；后者 GET=1、557056字节 paused，SQLite与回执一致。host12仅临时目标，不证明macOS10.15。完整 UI/FileStorage 仍 BLOCK/in_progress，PRD不勾选；速度/ETA未知、restartUnsupported、响应命名/最终URL、Apple/SAF删除及临时副本、Windows退出、macOS红钮/Quit实际操作、iOS/Windows/最低版本仍未验收。系统截图黑屏不算通过；Android设备由用户负责。

## 规范入口

| 文档 | 内容 |
| --- | --- |
| [架构与跨层契约](architecture.md) | 分层、Riverpod、暂停确认、执行身份、持久回执、字节进度与发布恢复断言 |
| [领域与持久化契约](persistence.md) | 已有 DTO/JSON、AppStore 事务、四表 v2、原始创建输入与事务迁移、确认身份与高水位、异常及真实 SQLite 测试 |
| [插件执行与恢复契约](plugin-engine.md) | 已实现适配器、独立执行日志、业务确认、prefix 恢复与尚未验收的平台边界 |
| [文件发布与源释放契约](file-storage.md) | 真实工厂/默认目录、唯一发布日志、取消重放、completed 同事务显式 ack、异步 SQLite 门及平台缺口 |
| [仓库与恢复协调契约](repositories.md) | 三仓库真实签名、分队列、取消优先、提交后通知、完整 ack 重放与只读启动 |
| [界面与应用组装契约](ui.md) | 具体依赖 record、三仓库流、局部操作状态、取消优先、初始化重试与退出证据边界 |

需求来源：[下载管理器需求](../../../.agents/specs/download-manager/requirements.md)；跨平台方案见 [设计文档](../../../.agents/specs/download-manager/design.md)。功能范围以需求为准；本目录约束如何实现，不扩展需求范围。

## Pre-Development Checklist

- 阅读 [架构与跨层契约](architecture.md)，确认改动所属功能和层；涉及领域模型、执行 DTO 或数据库时同时阅读 [领域与持久化契约](persistence.md)。
- 检查调用方、现有实现、测试、fixture、配置与导出，只新增实际需要的结构。
- 当前主机真实 SQLite 测试已通过；下载引擎、四平台原生资产/后台生命周期及目录访问仍待验证，不能将 Android 专用执行与存储方案当成整个应用架构。iOS 系统托管后台任务例外已获用户确认，按需求关联既有任务，不重新提交失败或取消任务。
- 修改跨层接口或持久化结构时，同步更新签名、错误行为和测试断言。
- iOS/桌面已引入 9.5.9 加有限补丁；修改执行/材料/恢复时阅读 [插件执行契约](plugin-engine.md)，验证跨 isolate 日志门、非破坏性回执、失败材料保留、未知总长字节和实际 GET 写入前校验。原版配置开关不足以满足契约，现有 macOS 结果也不代表 iOS/Windows 已通过。

## Quality Check

- Widget 不直接调用下载引擎、数据库或平台插件；Notifier 不重复保存 Repository 的任务集合。
- 页面销毁不取消后台任务；任务状态反映执行结果，失败有可理解的反馈。
- 执行键/会话/期望版本固定；业务提交后才确认回执，旧确认不删除新材料，未知总长仍有累计字节。
- 发布前先登记操作，结果不明不重复新建或猜测删除；目录快照、续传确认、清理和删除选择符合需求。
- 业务模型不依赖 Flutter、Riverpod 或插件类型；没有只有转发作用的 UseCase。
- 代码变更执行 `flutter analyze`、相关 `flutter test`；平台集成分别在 Android、macOS、Windows 验证，并在纳入 iOS 时完成其真机检查。文档变更检查链接、内容一致性和示例边界。

## 当前 macOS 部署基线

应用 macOS 最低部署版本现为 **12.0**，Runner 项目 Debug/Profile/Release 统一继承该基线；Flutter 生成的 Swift Package 随正常构建同步，不手工修改生成配置或依赖下限。用户授权修复原候选 10.15 与当前 Xcode 不兼容的问题后，已移除 XCODE_XCCONFIG_FILE 和 MACOSX_DEPLOYMENT_TARGET 环境覆盖执行 `flutter build macos --debug`，exit0，日志 `/tmp/download-ui-macos12-build.log`；Info.plist 最低版本及 Mach-O minos 均为 12.0。历史临时 host12 证据仍不证明 10.15；本轮默认构建通过也不代表 macOS 12 实机、release 或四平台验收。
