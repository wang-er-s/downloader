# 领域与持久化实施计划

## 依赖与启动

前置：用户批准最新任务摘要；无其他子任务依赖。先读本任务三份文档及上下文，加载 trellis-before-dev。不能因新建了任务就直接开始编码。

## 顺序

- [x] 读取 pubspec、lib/main.dart、现有测试和规范；仅加入本任务需要的依赖并解析 lockfile，不提前拉入未修补下载器。
- [x] 定义业务模型、输入校验、稳定错误及 Engine/FileStorage 契约和载荷校验；按源设计保持 Repository 的 taskId API 与 Engine 的完整命令 API 分离。
- [x] 实现 SQLite v1 和 AppStore 的最小事务入口、目录定位与版本处理，包含确认表和 pending_command/publish_operation 字段。
- [x] 写模型/DTO/输入边界测试；写真实 SQLite 约束、持久重开、回滚和确认保留测试。
- [x] 检查调用方、导出、fixture 与文档签名一致；只添加已有消费者实际需要的接口。

## 检查

- [x] flutter analyze：No issues found。
- [x] flutter test --reporter expanded：48 项通过（27 契约、20 SQLite、1 原计数器 smoke）。
- [x] 超过 4GiB/最大 int64、重复 requestId、未知版本/非法字段、事务中断和删除任务不删确认行均有断言。
- [x] 回执确认高水位不会因旧事件倒退；配置删除不级联。
- [x] 当前 macOS 主机真实加载 sqlite3 原生资产；使用内存/临时磁盘库与重开测试，未用 fake 替代。

## 审阅与回滚

以该子任务为单位审查 domain/data、AppStore、pubspec/lockfile 和测试。构建或测试失败不标完成；不编辑四平台网络/后台配置或主界面。变更 schema 前对照源设计，后续发版迁移不得删库。

## 实施与独立检查记录（2026-11-04）

- trellis-implement 完成基础实现，trellis-check 已做最终全范围 2.2；修复首次伪造确认占位、同版本完整回执被篡改、回滚失败掩盖原始异常三项问题，并新增三项真实 SQLite 回归测试。
- 依赖解析：sqlite3 3.8.0 的 hooks/record_use 要求 meta ^1.19.0，与 Flutter 3.44.8 固定 meta 1.18.0 冲突；实际精确解析 sqlite3 3.5.2、path_provider 2.1.6，通过，无 SDK 升级或 dependency_overrides。
- Flutter 工具自动在 windows/flutter/generated_plugins.cmake 的 FFI 列表添加 jni 一行；已获父代理批准保留。来源 path_provider_android 2.3.1 → jni 1.1.2 / jni_flutter 1.0.4+1，不手写生成文件。
- 独立检查实际运行 dart format、flutter analyze、flutter test --reporter expanded、git diff --check，均通过；未暂存/提交/归档。
- 源设计、frontend/index.md、architecture.md 已按实现状态同步，并新增 [持久化契约](../../spec/frontend/persistence.md) 的七节 API/数据/错误/测试约束。
- 未验证：四平台 release/实机、真实 path_provider 通道与目录授权、后台下载、材料归属释放、文件发布恢复；尚无已发版旧 schema，未宣称历史迁移已验证。
- 用户已于 2026-11-04 批准两笔提交及后续直接提交/推进的授权；本子任务实现与独立检查通过，完成工作提交后归档，再按依赖启动 plugin-engine。当前记录不代表其余平台能力已验收。
