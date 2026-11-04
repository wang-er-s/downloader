# 文件发布与恢复设计

## 前置与接口

依赖 contracts-store 的 FileStorage/PublishOperation/Recovery，以及 plugin-engine、android-engine 的持久日志边界；可先写平台定向原型，不在日志未接通时宣称发布恢复通过。协议权威为[源设计](../../../.agents/specs/download-manager/design.md)。

## 目录与发布所有权

默认目录通过系统 API 定位，任务创建时固化。Android 保存 SAF tree URI 授权，Apple 自选目录使用持久 bookmark 和配对访问，Windows 使用实际 Known Folder。所有操作核对父目录和资源身份，不将 URI 当路径或路径当归属证明。

Android 原生日志、iOS/桌面补丁日志分别持有唯一发布者的操作；AppStore 只镜像。prepared/creating 在外部新建前提交；保存目标身份后复制校验；finalizing 在最终不覆盖发布前提交。published 回执对齐 completed 后才清理私有完整暂存。

## 平台恢复

桌面/应用内目录按登记的操作临时名及文件身份核对；MediaStore 按本应用操作标记/条目与 IS_PENDING；SAF 不假定 renameDocument 后 URI 不变；Apple 目录先激活/协调访问并核验持久身份。recoverPublication 只查询，不自行再创建/改名/删除。

创建或改名结果不明且无法证明归属时返回 uncertain，保留操作和暂存；权限失效返回 needsPermission。已知不支持安全恢复的提供方返回 directoryUnsupported，不能用该限制掩盖默认位置未实现。取消清理不明项返回 cleanupFailure 并保留任务。

## 系统打开与安全

使用平台安全 API 及必要临时授权；不拼 shell 命令，不增加分享；Android APK 交系统安装流程。源与目标短暂双份占用需校验空间，失败不伪报完成。

## 回滚

外部文件不是代码回滚对象；只清理经过日志和身份证明的本任务未完成项。授权仍被历史任务引用时不能提前释放。未完成操作保留，禁止扫描用户目录按普通文件名猜归属。
