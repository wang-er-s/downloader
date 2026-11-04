# 下载领域契约与共享持久化

## Goal

为真实下载提供可测试的统一数据与事务基础，使进程中断后仍能识别任务、操作意图和待确认回执。

## Background

父任务：[跨平台下载管理器](../../../11-04-download-manager/prd.md)。依据[需求](../../../../../.agents/specs/download-manager/requirements.md) 2.1–2.5、3.2–3.4、5.1–5.6、6.1–6.4、7.1–7.2、8.5 及[设计](../../../../../.agents/specs/download-manager/design.md)的组件接口、数据模型和回执协议。本任务提供基础能力，不单独宣称这些业务验收已完成。

## Requirements

- 不可变业务模型明确平台目录、文件位置、任务状态、未知总长及稳定错误码。
- Engine 的命令固定执行键、会话和期望版本；快照、回执、确认及发布恢复有可验证 DTO。
- URL/名称/目录输入和 DTO 在信任边界校验；未知版本或非法值不覆盖已有数据。
- 持久任务、配置、主题及操作意图；任务状态与回执确认高水位支持同事务提交。
- 取消/删除任务不丢最后确认行，不级联删除配置关联的任务，不以删库处理异常。

## Out of Scope

真实下载、原生服务、插件补丁、用户目录发布、仓库业务调度和界面。

## Acceptance Criteria

- [x] domain 不依赖 Flutter/Riverpod/插件；Engine/FileStorage 不向业务层泄漏平台类型。
- [x] ExecutionKey、EngineCommand、EngineSnapshot、EngineReceipt、ReceiptAck、PublishOperation/Recovery 的字段与设计一致；空快照也能提供会话。
- [x] SQLite v1 实现任务/配置/设置/确认表，重复 requestId、负字节/代次、非法状态/主题被拒绝，支持超过 4GiB 的字节值。
- [x] 事务失败同时回滚业务状态与确认高水位；高水位不倒退，删除任务后确认仍可查询。
- [x] DTO/JSON 版本、未知总长 null、输入非法及数据库版本/写入失败有定向测试，数据库错误不删原记录；尚无已发版旧结构的迁移可验。
- [x] 文件/类按真实用途创建，不预建 BaseRepository 或无用接口包装。
