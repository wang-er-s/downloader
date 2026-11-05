# 仓库与恢复协调设计

## 前置与结构

三个 Repository 已按[源设计](../../../.agents/specs/download-manager/design.md)实现并局部独立 PASS，真实签名和可执行边界集中见[仓库契约](../../spec/frontend/repositories.md)。不相互读取 Controller；Provider/Riverpod 组装仍未实现，不叠加无用 UseCase。

## 命令与事务

先校验输入/状态并固定执行键和命令，再保存业务意图后调用 Engine。暂停成功等待实际停止、材料/回执及业务提交；保存失败可反映真实已停但不能假装全部成功。创建/启动结果不明只 inspect，不自动换身份重提。不同用户提交同 URL 可创建新任务。

回执按 key/version 对齐；同事务写任务状态和 engine_receipt_acks 后才确认。取消/删除移除业务行仍保留最后确认。旧回调、已取消项或未知孤立回执不能自动导入或复活。

## 启动与发布

先订阅缓冲再 inspect；快照会话/序号/回执版本职责分开。Android/桌面旧进程未完成项 waitingRecovery；iOS 只关联系统既有执行。已下载但未发布走本地恢复，不重新下载；uncertain 持久保留，不再创建第二个目标。

## 配置与设置

保存配置不执行；发起时复制 URL/文件名并固化当时有效目录，删除配置不影响任务。主题随设置流更新；默认目录授权保存失败保留原值，不迁移历史任务。错误在边界映射稳定码，不匹配原始报错字符串。

## 验证与回滚

fake Engine 可定向验证乱序/中断，但需再用真实平台适配 smoke 验证协议。重放和迁移不删记录；回滚代码不逆向删除用户已发布文件，不重放网络请求修饰错误状态。

## 父代理授权调整（本轮）

为严格区分 create 的空目录与显式目录输入，授权 AppStore 四表保持不变、v1→v2 增加 download_tasks.create_input_json；创建任务和规范化原输入同事务保存，不修改共享 DTO。历史无输入记录以 stateConflict/createInputUnknown 拒绝去重，不猜测、不联网。去重仅覆盖现存任务生命周期。restartFromZero 暂以 restartRequired/restartUnsupported 明确拒绝，待引擎增加原子退休旧执行及新代次接口，不能通过 cancel+enqueue 模拟。

## 独立检查后的协调修正

普通用户命令按任务串行，创建按 requestId 串行；事件/inspect 使用独立协调队列，长发布使用按任务发布队列。取消为优先意图：不等待上述长 IO，立即以已提交业务回执保存 cancelling 和原完整 cancel 命令，不能将流中的未提交暂停回执经普通 saveTask 落库。随后等待该任务已开始的发布退出，若已经发布则保留真实最终文件/操作/取消意图并报告 cleanupFailure/alreadyPublished；不猜删、不自动释放私有源。其他任务仍可操作。

回执在业务事务提交前不向同步订阅者发通知，避免订阅回调重入取消后被旧完成快照覆盖。实际已停但提交失败仍通过流反映，随后必须经 commitReceipt 补齐确认。普通保存不得反向覆盖持久 cancelling/deleting。每次非空释放确认前重读业务完成授权；已经开始的外部 ack IO 无法由 Repository 撤回，依赖现有引擎在异步等待后/逐成员删除前重新核验业务授权，不宣称无限即时取消。业务 completed 已提交后普通 cancel 拒绝，删除须显式选择。

删除完成记录前先重放已提交完整 ack 并等待成功，再保存 deleting/调用文件删除/删除业务行；ack 失败保留完整 completed 授权供重试，不能先丢业务行或更改同版本空 ack。历史无完整源引用不能伪造释放；含 complete: 引用但确认载荷缺失时保守拒绝。

仅引擎明确以 stateConflict/staleSession 或 staleReceipt 在接受前拒绝 cancel 时，清除该已拒绝的 pending 命令但保留 cancelling；同步后下一次用户显式取消创建新 commandId/捕获新版本，绝不修改或自动重发旧命令。cleanupFailure、结果不明及已经接受的原 cancel 仍保存原完整身份供清理后重放。

## 本轮文档同步与验证边界

AppStore 四表 v2：源码 v1 基础 DDL 在 0 初建后继续执行与 1→2 相同的事务 ALTER，新增 nullable create_input_json；2 只验证，未知版本拒绝留库。最终 SQL、规范化原输入/空与显式目录差异见持久化及仓库规范。

独立 delivery 日志确认 analyze clean、141 项（36 仓库＋105 既有）及 1 项真实 macOS smoke：总 GET=2，完成与未完成记录重开零新增 GET/发布。文档轮不重跑产品测试。从零重下 restartUnsupported、响应命名/最终 URL、Provider/UI、Apple/SAF 删除及平台最低版本仍未交付或未验收；PRD 保持未勾，不归档。
