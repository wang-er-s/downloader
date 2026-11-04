# 领域契约与共享持久化设计

## 前置与边界

这是首个实施子任务，无其他实施依赖；用户已批准最终规划并激活实施。以[源设计](../../../.agents/specs/download-manager/design.md)的 Signatures、Contracts 和共享 SQLite v1 为准，不再设计第二套模型。

## 结构

下载模型放 features/downloads/domain；Engine 契约和必要适配 DTO 放其 data 边界。多功能复用的 AppStore 放 shared/data；配置和设置模型留在各自功能。实际精确依赖为 sqlite3 3.5.2、path_provider 2.1.6，不用插件业务表代替 AppStore；原 sqlite3 3.8.0 候选因传递依赖与当前 SDK 固定 meta 冲突而调整。

## 数据与事务

稳定执行键包含 taskId/engineId/generation，命令含 commandId/ownerSessionId/expectedReceiptVersion；恢复材料只暴露不透明引用。EngineSnapshot 返回会话和回执，ReceiptAck 默认不释放材料；PublishOperation 记录创建前意图，Recovery 可返回 uncertain。

SQLite v1 同源设计：download_tasks、saved_downloads、app_settings、engine_receipt_acks。使用参数绑定、短事务和可测试的持久目录入口；用户目录网络与文件复制不放事务内。确认高水位与业务更新原子提交，确认行不依赖任务外键。尚未发版的 v1 与源设计同步，之后的 schema 变化必须迁移。

实际 API、target_ref 的 version=1 JSON 信封、枚举和错误边界已同步至[持久化契约](../../spec/frontend/persistence.md)。StoreTransaction.commitReceipt 原子提交任务/确认，同版本回执载荷不可变，确认行及保留执行身份在删除后仍生效；回滚失败不得掩盖最初异常。

## 失败与兼容

JSON 类型/版本、URL、文件名和目录定位不合法时返回稳定错误；不截断 64 位字节，不用未知总长 0 代替 null。读库/迁移失败保留数据，禁止自动删库重建。不改真实下载、主界面或四平台权限。

## 验证与回滚

Dart 单元和内存/临时目录 SQLite 测试验证约束、往返序列化、事务回滚及删除后的确认保留。SQL 草案自检不是实际 Dart 实现测试。新增依赖和 lockfile 是本子任务所有的变化；不回退仓库既有未提交资料。
