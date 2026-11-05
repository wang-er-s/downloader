# 仓库实施计划

## 依赖

contracts-store 已验收，其余引擎及 FileStorage 已有可接入的局部安全原型与独立证据，任务尚未整体验收。按用户2026-11-05调整继续 Repository→UI，Android实机由用户负责；Apple/SAF现存目标删除等功能缺口须保留错误与任务，不以仓库层伪造成功。

- [ ] 检查共享接口与实际适配结果，修正所有真实调用方、DTO/fixture 及规范的差异。
- [ ] 实现唯一任务流、创建去重、输入/目录固化与同任务串行命令。
- [ ] 接入回执事务、确认重放、用户意图优先和业务记录移除后的确认保留。
- [ ] 接入平台启动恢复与本地发布恢复，不自动提交未完成/失败下载。
- [ ] 实现缓存/设置仓库及功能级 Provider 组装，不提前实现 UI。
- [ ] 先做定向单元/SQLite 集成，再跑真实 Engine/FileStorage smoke。

## 验证

flutter analyze、flutter test；新增仓库测试覆盖初始快照/读取失败、重复提交、旧会话/代次、暂停保存失败、取消与完成竞争、回执提交前后中断、确认重发、发布 uncertain 和本地重试。

设置/配置测试覆盖保存不下载、编辑取消保持值、删除不级联、全局目录更新不影响历史任务、配置空目录取发起时默认值。可控 HTTP 统计启动网络请求，不能只检查 fake enqueue 次数代替平台证明。

## 审阅与回滚

不变更已确认产品范围；检查 UI 将使用的 Repository API、Stream 不可变性和稳定错误。出现协议或 schema 改动同时补调用方/测试/规范，不通过销毁记录或自动重试隐藏问题。

## 激活与本轮生产边界（2026-11-05）

FileStorage 检查点 5e22b0d 已提交；以 frontend/file-storage.md 为最新契约。直接实现 DownloadRepository、SavedDownloadRepository、SettingsRepository，复用 AppStore v1、现有 Engine/FileStorage 和 PublicationJournal，不改共享 DTO/API/四表或重写网络/发布核心。功能级 Provider 在业务仓库稳定后接入，首轮不因组装引入 Riverpod 依赖。

completed 对齐必须同事务保存最终位置、published 操作、完整回执与显式完整源 ack，再 acknowledge；同版本确认不得先空后改。取消先保存稳定原命令/意图，cleanupPendingPublication 成功后只重放原 cancel；uncertain/安全拒删保留可追踪任务。启动只 inspect/确认重放/只读发布恢复，不能自动 enqueue/resume 或猜测新建目标。真实 macOS smoke 通过生产 Repository→Engine/FileStorage 与 HTTP 服务端计数验证，平台缺口不扩大为已通过。
