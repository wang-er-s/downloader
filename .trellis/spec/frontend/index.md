# Flutter 前端规范

## 适用范围与当前状态

适用于本仓库 Flutter 应用及各平台适配：Android、macOS、Windows 为必需平台，iOS 为希望一并提供、需验证可行性的平台。采用按功能组织目录、MVVM 职责划分、Repository/Service 分层，Riverpod 负责状态管理与依赖注入。复杂业务按需提取 UseCase。

这是已确认的架构约定；领域/执行 DTO、DownloadEngine 与 FileStorage 接口及 AppStore v1 已实现。PluginEngine 与固定 9.5.9 补丁已接入，桌面日志并发、保留原件的安全恢复和当前 macOS 集成已独立复核；整个插件子任务仍未验收。Android 原生通道、独立日志和 Dart AndroidEngine 桥接已通过局部独立检查；内部 HttpTransfer 新下载/私有暂存及 v2 材料登记门通过主机真实 HTTP 独立检查（JVM19项），固定完整命令及 URL，材料先登记后创建。尚未接服务或通道，续传明确拒绝；六项 Android SQLite instrumentation 仅编译，真实 SQLite、服务和完整引擎未验收，边界见 architecture.md。`lib/main.dart` 仍为计数器，Repository、Riverpod、Android 传输服务集成、用户目录发布与业务界面尚未实现。

## 规范入口

| 文档 | 内容 |
| --- | --- |
| [架构与跨层契约](architecture.md) | 分层、Riverpod、暂停确认、执行身份、持久回执、字节进度与发布恢复断言 |
| [领域与持久化契约](persistence.md) | 已有 DTO/JSON、AppStore 事务、四表 v1、确认身份与高水位、异常及真实 SQLite 测试 |
| [插件执行与恢复契约](plugin-engine.md) | 已实现适配器、独立执行日志、业务确认、prefix 恢复与尚未验收的平台边界 |

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
