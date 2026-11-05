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

FileStorage 检查点 5e22b0d 已提交；以 frontend/file-storage.md 为文件契约。三个生产 Repository 已实现，AppStore 按后续授权升级四表 v2，不改共享 DTO/API，不重写网络/发布核心。功能级 Provider/Riverpod 仍待接入；本轮仅文档同步，以上未勾列表保留未完成范围，不作为 PRD 验收。

completed 对齐必须同事务保存最终位置、published 操作、完整回执与显式完整源 ack，再 acknowledge；同版本确认不得先空后改。取消先保存稳定原命令/意图，cleanupPendingPublication 成功后只重放原 cancel；uncertain/安全拒删保留可追踪任务。启动只 inspect/确认重放/只读发布恢复，不能自动 enqueue/resume 或猜测新建目标。真实 macOS smoke 通过生产 Repository→Engine/FileStorage 与 HTTP 服务端计数验证，平台缺口不扩大为已通过。

本轮父代理授权：先补 AppStore v2 原始创建输入原子保存/查询及迁移回归，再接三个生产仓库；历史未知输入拒绝去重。从零重下安全接口暂缺，显式拒绝并列未交付，不勾完整 PRD。

独立检查新增确定性回归：长发布屏障中取消立即持久、其他任务可暂停、迟到完成保留事实不释放源、重开零新增发布；ack 屏障中取消先落库；删除完成记录先确认且确认失败保留完整授权；createTask 身份及显式目录一致性；fresh/migrate 四表 DDL/列相同；completed 确认触发器失败原子回滚后补存；创建输入跨仓库重开/普通保存仍保留。测试按 analyze → 全套 Flutter → macOS 真链顺序独立运行，证据见 /tmp/repository-check-*.log 及 .exit。原 PRD 保持未勾，不将 restart、响应名称与未验收平台记为完成。

## 文档同步交付

可执行契约见[repositories.md](../../spec/frontend/repositories.md)，implement.jsonl/check.jsonl 已引用。已核实 `/tmp/repository-check-{analyze,tests,smoke}-delivery.log` 及 `.exit` 均 0：analyze clean，141 项（36 仓库＋105 既有），1 项真实 macOS 集成，总 GET=2、重开零新增 GET/发布。本轮不重跑产品测试。

从零重下仍 restartUnsupported；响应命名/最终 URL、Provider/Riverpod/UI 以及 Apple/SAF 删除、各平台最低版本仍未完成或未验收。PRD 不勾、不归档；文档验证检查链接/围栏/末尾换行、七节、task.py validate、diff --check 及保护文件哈希。
