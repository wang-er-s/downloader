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

## 首轮协议/日志检查点（2026-11-04，非完整引擎）

已接入 MainActivity 的 MethodChannel/EventChannel，进程对象持有随机会话和串行通道队列，Activity detach 只解除监听。inspect 返回 protocolVersion=1、当前会话、sequence=0 与日志回执；当前没有 worker/事件生产者。ack 只推进匹配完整执行键的已有回执高水位，超前确认拒绝；所有显式材料释放暂拒绝 materialReleaseUnavailable，不删除材料。传输方法解析命令后明确拒绝 transferUnavailable，旧会话拒绝 staleSession；尚未实现 Dart AndroidEngine，不能当作完整 DownloadEngine 调用。enqueue 的请求扩展约定为顶层扁平 command + input=EngineTask.toJson()，嵌套 key 必须匹配。

独立 android_execution_v1.db 使用 Android SQLiteOpenHelper，保存 executions/commands/receipts；执行登记和未知结果、不可变回执分配与命令结果、ack 更新分别在真实 SQLite 写事务中串行提交。inspect 非破坏，保留最新及未确认历史；本轮连已确认历史也保守留库。命令重复同载荷回放、不同载荷拒绝，NULL 结果拒绝自动重试。失败保留原始异常，回滚异常附加到原异常；不删库重建，不打开 AppStore。恢复引用仅记录在不可变回执中；实际材料归属登记、清理、发布扩展及完整失败回执需随 worker 下一轮实现。

当前原生日志不具备核验 AppStore 业务已提交的能力：ack 是调用方提交后的可信边界，Repository 必须先完成 AppStore 同事务业务/确认提交；本轮拒绝全部释放引用，避免在该边界未接入前删除材料。没有前台服务、HTTP、自动传输、暂停/取消成功路径。

## Dart 桥接检查点（2026-11-04，传输仍未接入）

新增 `AndroidEngine.open(store: ...)` 实现现有 DownloadEngine；仅 Android 可打开，`isAndroid` 为最小主机测试注入。监听既有事件通道时显式传 protocolVersion=1，命令显式映射扁平执行键/commandId/会话/期望版本；enqueue 的 input 保留完整 EngineTask JSON。不会生成或重绑命令身份，也不会在打开、inspect、重连或 close 时自动 enqueue/resume/retry。close 仅释放 Dart 事件订阅。inspect 严格使用共享 DTO 解析，空快照保留会话，未知版本、错误类型与初始读取错误均失败，不伪造空集合。首次业务订阅前缓冲事件和错误；事件拒绝非递增序号和未由显式 inspect 确认的会话变化。显式 inspect 可同步当前会话/序号，同会话不降低序号，迟到旧 inspect 不覆盖较新同步；序号缺口保留原值供 Repository 对齐。

ack 先在真实 AppStore 短事务读取并核对完整持久 ReceiptAck，不能把 commitReceipt=false 或调用参数当作提交证明；若现存业务任务的同执行回执版本相同，再非破坏 inspect 核对完整回执内容（缺版本也拒绝）。inspect 让出执行权后再次读取持久确认行和业务任务，对现存同版本完整回执重新比较，防止确认行或同确认行下的业务回执期间被替换。较新业务回执/已移除任务按实际留存确认行重放，绝不删除任务或确认行。材料释放原样交给原生校验，当前 materialReleaseUnavailable 仍传播，Dart 无本地文件释放路径。

平台与解析错误封装为 AndroidEngineException.failure（稳定 DownloadFailure）；仅放行已知结构化 reason，不转发原始 PlatformException 消息、诊断路径或任意 details；业务确认读取异常返回 persistenceFailure。该桥接和 host messenger fake 不证明原生执行成功：服务/HTTP/真实暂停取消、原生事件生产、真实 Android SQLite 与端到端设备验收继续 BLOCK。下一步仍是原生服务、HTTP 安全响应/持久暂存及设备矩阵，不勾完整 PRD 验收。

## HTTP 核心局部检查点（2026-11-04，未接服务）

新增内部 `HttpTransfer(Context.filesDir)` 构件，调用方必须是后续原生服务，绝不使用 Dart stagingLocation 作为根目录。当前 API 接收 File 仅为内部原生/真实 JVM 测试入口；拒绝非 canonical 根、symlink 暂存目录和根别名，依赖 Android 私有 sandbox 排除同权限恶意 native 写入者，不声称抵御同 UID 并发替换目录。随机 UUID 分配 `.facts`/`.part`，CREATE_NEW + NOFOLLOW_LINKS 排他创建，先 force 执行身份/意图，再创建 payload；保留所有原文件，不接受任何已有 partial 路径。facts 是诊断材料，不是 ExecutionJournal 恢复证明；目录项 fsync 与崩溃归属恢复未验收。

使用默认 HttpURLConnection/HTTPS TLS，identity、连接15s/读取30s；每跳重新校验无认证 http/https，拒绝 fragment/非法 port，至多10跳和 visited 检测。只接受初次200；非200、编码、长度和IO错误保留真实 cause 与 material。64位累计、未知total=null，实际写入后发单调时间样本；进度force记录最多每秒，SHA-256仅随写入增量更新，不反复扫描。已知长度EOF不匹配拒绝 staged；output force/close与facts force/close失败均不能返回成功。完整结果只称 staged，绝不称 completed/已发布。

Stop.request(PAUSE/CANCEL)仅请求并disconnect；调用者须等待 run 真正退出，文件关闭及终态facts成功后才能提交回执。取消暂保留材料，不等于取消清理完成；后续Service需串行协调命令、停止与journal回执，并在明确归属释放后才对外完成cancel。网络读被停止中断可形成停止结果，输入close、文件/检查点错误仍传播，不能用finally认证失败检查点。输出关闭后固定一次终态停止原因，facts与返回结果使用同一快照；此边界之后到达的停止请求由后续Service按已完成的暂存结果与取消优先意图协调，不回改既有终态。

续传本轮明确 unsupported：resume() 返回 stateConflict/restartRequired，不打开或修改原件，不发HEAD/Range。完整安全GET/ETag/Content-Range/prefix认证与candidate恢复日志未实现；原生通道继续 transferUnavailable。Service、权限、事件/ExecutionJournal联动、恢复/清理和目标发布留后轮；此构件不得直接接为生产DownloadEngine。
