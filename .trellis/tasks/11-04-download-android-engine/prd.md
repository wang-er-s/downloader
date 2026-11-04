# Android 独立下载执行适配

## Goal

Android 切后台时按系统能力持续下载；页面销毁或重连不影响执行，进程终止后不自动重启传输，任务和材料可恢复。

## Background

依赖 [contracts-store](../11-04-download-contracts-store/prd.md)，不依赖 PluginEngine 实现。覆盖[需求](../../../.agents/specs/download-manager/requirements.md) 1.1、1.3–1.4、2.1–2.3、3.1–3.5、8.1–8.2、8.5；遵守[设计](../../../.agents/specs/download-manager/design.md)的 Android 通道、生命周期和回执约定。

## Requirements

- HTTP/HTTPS、重定向、流式大文件、已知和未知总长进度。
- 暂停实际停止，安全续传不破坏数据，取消有可确认停止结果。
- 会话和执行身份明确，旧命令/事件不复活新执行；回执持久且业务确认前可重放。
- 后台/通知/系统时限受限制时给出真实反馈，不能承诺无限后台。
- 不向下载插件提交 Android 任务，不自动网络重试或开机恢复下载。

## Out of Scope

业务库原生独占写入、UI、配置业务、完整用户目录发布与 APK 打开流程。文件发布日志接入由 file-storage 负责。

## Acceptance Criteria

- [ ] 空 inspect 返回当前 ownerSessionId、sequence、receipts，不触发网络；旧会话/执行键/期望版本拒绝且无副作用。
- [ ] commandId 幂等、暂停确认、read/ack、恢复材料保留符合共享契约，旧确认不删新材料。
- [ ] GET 写前校验 Range/验证器和偏移；未知总长真实计数，超过 4GiB 偏移不溢出。
- [ ] 前台服务不依赖 Activity/Dart，页面销毁不停止；重连关联仍在执行的服务。
- [ ] 进程终止/重启后无用户操作的新请求为零；START_NOT_STICKY 之外仍校验会话，不注册自动恢复下载路径。
- [ ] 系统时限、通知拒绝、权限与写入错误保存可追踪状态；API 29/30/33/35/36 原型结果可查，未测项明确保留。
