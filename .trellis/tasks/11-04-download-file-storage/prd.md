# 跨平台目录与文件发布恢复

## Goal

把完整下载安全保存至用户可找到的目录，保留既有文件，在发布中断、授权失效或清理失败时仍能追踪本次操作。

## Background

依赖 contracts-store 及两个引擎的持久日志/回执边界。覆盖[需求](../../../.agents/specs/download-manager/requirements.md) 2.3–2.5、4.1–4.3、4.5、6.1–6.8、7.2–7.3、8.3–8.5；实现[设计](../../../.agents/specs/download-manager/design.md)的 FileStorage 和逐平台发布恢复协议。

## Requirements

- 初次使用具备默认目录，自选目录及必要授权可跨重启访问；取消选择保留原值。
- 新建文件重名时保留原文件并递增命名，不把存在性预检当独占创建。
- 发布创建前持久登记操作；中断后核验操作归属，不重复目标或猜测删除。
- 取消只清理本任务的未完成文件；删除完成项只执行用户选择；权限/空间/锁定失败可处理。
- 文件打开使用平台系统处理程序；APK 安装仅 Android，无分享兜底。

## Out of Scope

网络传输、调度、业务 UI、绕过沙盒/全盘权限和要求所有第三方提供方具备相同原子语义。

## Acceptance Criteria

- [ ] Android 公共 Download/Downloader、macOS/Windows 系统 Downloads/Downloader、iOS 应用内持久位置实际可用；首次默认下载不要求先手选目录。
- [ ] Android URI、Apple bookmark、桌面路径分别处理，取消选择/授权失败不清空旧设置。
- [ ] 创建目标前已有持久 PublishOperation；创建后句柄提交前和最终操作后回执提交前中断，不产生第二个目标或误删。
- [ ] uncertain/授权丢失保留完整暂存、记录和可操作错误；不支持安全恢复的提供方明确报告，不静默改目录。
- [ ] 并发重名、磁盘不足、文件锁定、缺失文件、SAF 改名换 URI 与 Apple 提供方不可用有实际测试。
- [ ] 发布完整核验后才提供 completed 依据；取消/删除错误保留意图，系统打开无处理程序有反馈。
