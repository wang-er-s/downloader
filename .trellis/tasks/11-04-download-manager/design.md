# 技术设计与任务边界

## 权威与兼容

沿用[跨平台设计](../../../.agents/specs/download-manager/design.md)，本文件只定义任务间边界，不复制或改变功能规则。当前所有类型、表及补丁尚未实现；现有计数器和平台配置是实施前状态。

## 结构与数据流

View → Riverpod Controller → Repository → AppStore / DownloadEngine / FileStorage。Android 使用独立原生执行适配；iOS/macOS/Windows 复用 9.5.9 固定源码和有限补丁。只有 Repository 写共享业务表；原生及插件日志持有执行事实。

引擎先持久回执 → Repository 事务提交任务和确认高水位 → 幂等 acknowledge。执行身份为不可变 ExecutionKey 和固定命令；发布先登记 PublishOperation，再创建目标、核对归属、不覆盖发布和确认 completed。

## 子任务接口

| 子任务 | 交付给后续任务的边界 |
| --- | --- |
| contracts-store | 纯业务模型/校验、Engine 与 FileStorage 契约、AppStore 事务和确认表 |
| plugin-engine | iOS/桌面真实执行、非破坏性收件箱、累计字节、安全续传及恢复材料引用 |
| android-engine | 同一 Engine 契约、会话握手、原生日志与前台服务 |
| file-storage | 持久目录、发布操作恢复、归属清理及系统打开；接入已有执行日志 |
| repositories | 唯一业务任务流、命令/回执协调、恢复、配置与设置 |
| ui | 订阅业务仓库并呈现真实结果，不新增执行或持久化来源 |
| platform-validation | 可复查的四平台验证与 49 项验收证据 |

## 风险门槛

iOS 系统 resume data 能否阻止未确认的从零恢复须先验证；外部提供方无法稳定核验身份时保持 uncertain，而不是猜测成功。Windows 实际运行、iOS 实体设备、签名和 release 产物不能用 macOS 上的 Dart fake 代替。

## 回滚与资料

按子任务隔离改动和记录；不得 reset/clean 当前用户工作。业务库首次落地为 v1；后续变更需迁移，不删库。插件固定归档 SHA-256 和补丁来源在 plugin-engine 任务记录，保留许可证，不自动升级 SDK。
