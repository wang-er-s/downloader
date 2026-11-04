# Android 引擎设计

## 接口与所有权

依赖 contracts-store。使用[源设计](../../../.agents/specs/download-manager/design.md)中 downloader/android_engine 命令通道及事件通道、protocolVersion=1 和 EngineCommand/Receipt/Snapshot/Ack。不把 Repository 变成原生专用协议。

Kotlin 前台 dataSync 服务持有网络、检查点和独立执行日志；共享 AppStore 不被原生直接写入。MainActivity 只处理通道和系统结果，不持有执行生命周期。复用 Android/Java 标准网络与持久化能力，不新增完整网络框架。

## 执行与协议

inspect 无副作用并返回原生当前会话；命令以固定执行键/commandId/期望版本校验。进程级 ownerSessionId 用于拒绝旧 Intent，Activity 重建不换成重启下载。幂等结果、暂停/终态回执和材料引用持久提交后再交付 Dart，确认后按引用释放。

流式 HTTP/HTTPS、重定向校验和 64 位计数；续传实际响应进入写入前校验 206、Content-Range 和验证器。失败保留材料。START_NOT_STICKY、无 boot 自动下载、无自动重试；系统超时及时停止并异步保存，不在 onTimeout 主线程等待网络。

## 配置与兼容

按实际 target 36 核验 INTERNET、前台服务/类型及通知权限、exported=false、cleartext 与 HTTPS 验证。候选最低 API 29 沿用已审核设计；若 SDK/依赖要求调整先报告。不可通过降 target、全盘权限或后台启动绕过系统限制。

## 文件边界与回滚

仅写应用持久暂存；预留同一执行日志保存 PublishOperation，file-storage 接入后才能发布用户目标。协议和原生调用方一起改，回滚不清日志或业务数据，不编辑生成注册文件。
