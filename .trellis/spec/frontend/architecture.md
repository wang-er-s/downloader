# Flutter 架构与跨层契约

## 设计决策：Feature-first + MVVM + Repository/Service + Riverpod

下载管理器页面数量有限，但下载生命周期、任务恢复和文件访问必须独立于页面。采用按功能组织目录、MVVM 式职责划分及 Repository/Service 分层；Riverpod 管理界面状态与依赖，复杂业务按需提取 UseCase。

该分层决策已确认；领域/执行 DTO、DownloadEngine 与 FileStorage 接口及 AppStore v1 已实现，现有 API 与验证范围见[持久化契约](persistence.md)。PluginEngine 与固定插件补丁已接入，桌面局部验证见[插件执行契约](plugin-engine.md)；AndroidEngine 的 Dart 桥接、新下载 Service/Coordinator/HttpTransfer 生产调用链已通过主机局部独立检查；Android v6 公开 resume 生产链、冻结源与新 worker 授权、候选分支晋升及终态补存已通过主机局部独立检查；Repository 和用户文件操作仍待实现，Android 设备验收未通过。插件子任务尚未完成平台验收，当前 macOS 运行结果不能代表 iOS/Windows/最低版本通过。

平台范围为必需支持 Android、macOS、Windows，并争取同步提供 iOS。共享业务接口不能绑定 Android 专用通道或数据库；优先复用跨平台实现，仅在平台边界适配执行、目录和文件打开。iOS 系统托管后台任务例外已获用户确认：关联既有任务并同步状态，不主动重新提交失败或取消任务；用户强制退出按系统取消行为处理。具体跨平台方案见 [设计文档](../../../.agents/specs/download-manager/design.md)，其技术选型仍须通过设计审核及平台验证。

考虑过全面 Clean Architecture、Bloc/Cubit 及独立 package：首期保持单个 Flutter 工程，避免为简单操作增加转发层。出现复杂复用规则时提取 UseCase，出现实际跨应用复用或团队边界时再考虑拆包。

### 目录与职责

```text
lib/
├── app/                           # 应用入口、主题、导航、依赖组装
├── features/
│   ├── downloads/
│   │   ├── presentation/          # 页面、DownloadsController、局部组件
│   │   ├── domain/                # DownloadTask、纯业务规则、必要的 UseCase
│   │   └── data/                  # DownloadRepository、DownloadEngine、持久化适配
│   ├── saved_downloads/           # 需求中的“缓存”：可重复使用的下载配置
│   └── settings/                  # 主题与全局默认目录
└── shared/                        # 已被多个功能实际复用的组件或能力
```

这是职责示意，按实现需要创建目录和文件，不预建空目录。`saved_downloads`、`settings` 按自身复杂度增加层，不强制复制 downloads 的全部结构。测试按 `test/features/<feature>/` 对应组织。

| 部分 | 职责 | 边界 |
| --- | --- | --- |
| View | 渲染、输入、确认交互和用户反馈 | 不调用引擎、数据库或平台插件 |
| Controller / Notifier | 承担 ViewModel 职责，暴露操作、协调界面状态和反馈 | 不再叠加同职责 ViewModel；不维护第二份任务集合 |
| Repository | 对外提供统一任务数据，协调引擎、恢复记录和持久化 | 不依赖 Widget、BuildContext 或页面状态 |
| Service / 平台适配 | 封装下载插件、数据库、文件、目录授权等具体能力 | 插件类型与平台异常不泄漏到业务模型和 View |
| Domain / UseCase | 纯业务模型、复杂或复用的业务规则 | 不导入 Flutter、Riverpod、数据库或插件；简单转发不提取 UseCase |

普通调用方向为 View → Controller → Repository → Service。复杂业务可插入 UseCase；Repository 和 Service 可使用 domain 模型，domain 不反向依赖具体 data 类。需由 UseCase 访问数据时，仅在真实边界需要处提取最小接口，不给每个类预建接口与 Impl 配对。依赖由 app 或功能级 Provider 组装，功能不导入 app 的组装代码；跨功能的数据需求通过注入协作能力解决，不互相读取 Controller。

### Riverpod 与生命周期

- Provider 组装依赖，StreamProvider 订阅 Repository 的任务流，Notifier 类暴露操作及必要界面状态。具体 Riverpod API 和版本在引入依赖时确认。
- 输入框、当前分类等局部状态可以留在 Widget；下载中、已完成列表及数量由统一任务集合派生。
- 下载引擎及必要的同步、持久化由应用级或平台生命周期持有。页面取消订阅或 Provider 释放只能释放界面资源，不能取消后台下载。
- Riverpod 不承担各平台后台执行保证。回到前台时，Repository 应重新对齐引擎和持久化记录，避免仅凭旧内存快照显示任务状态。

## 场景：暂停下载与任务状态同步

### 1. Scope / Trigger

跨越 View、Controller、Repository、下载引擎和持久化的状态变更，必须约束调用结果、数据来源及失败行为。以下以暂停为最小示例；创建、继续、取消及删除的完整签名在对应功能设计时补充，行为遵守后文业务约束。

### 2. Signatures

下列暂停及回执对齐签名中，DownloadEngine 已有抽象接口，Controller/Repository 仍待接入；完整数据结构和 SQLite v1 见[设计文档](../../../.agents/specs/download-manager/design.md)，现有存储 API 见[持久化契约](persistence.md)。不新增对外 HTTP API 或环境变量。

| 所属对象 | 最小签名 |
| --- | --- |
| DownloadsController | `Future<void> pause(String taskId)` |
| DownloadRepository | `Stream<List<DownloadTask>> watchTasks()` |
| DownloadRepository | `Future<void> pause(String taskId)` |
| DownloadEngine | `Future<EngineReceipt> pause(EngineCommand command)` |
| DownloadEngine | `Future<EngineSnapshot> inspect()` |
| DownloadEngine | `Future<void> acknowledge(ReceiptAck ack)` |

`DownloadTask` 为不可变业务快照。`ExecutionKey` 固定 taskId/engineId/generation；`EngineCommand` 固定 commandId、key、当前 ownerSessionId 和 expectedReceiptVersion。EngineSnapshot 即使为空也返回当前会话；EngineReceipt 带跨重启单调递增的 receiptVersion；ReceiptAck 包含 key、已提交版本和默认空的 releaseResumeRefs。不泄漏插件任务类型。

### 3. Contracts

- `taskId` 必须非空且对应已有任务。首次暂停仅对可暂停的活动任务生效；已暂停任务重复暂停为幂等成功，其他不可暂停状态不得下发引擎操作。稳定枚举为 DownloadStatus，端到端状态校验由后续 Repository 接入。
- `watchTasks()` 订阅后提供当前快照，再发布变化。列表及元素对消费者不可变；同一任务只有一个稳定标识，分类和数量从此流派生。
- Controller 按 taskId 调用 Repository；Repository 校验时捕获完整执行键、会话及期望回执版本，保存稳定 commandId，再调用引擎。适配器不在发送/重试时将旧命令重绑当前代次；相同 commandId 幂等，不同载荷拒绝。
- 暂停成功需确认传输停止、保留续传数据，并完成所需的暂停状态持久化。操作的 Future 只有在这些条件满足后才能成功完成；失败则以异常完成，由界面处理。
- Repository 的数据流反映实际结果，不在点击时提前发布“已暂停”。操作等待期间可显示处理中，并避免重复提交同一任务操作；不得用临时界面状态覆盖实际任务状态。
- 引擎成功但持久化失败：流中如实展示已暂停的运行状态，操作仍报告保存失败及恢复风险；不能伪装全部成功，也不能为掩盖失败自动重新下载。
- 已定义 DownloadFailure/FailureCode；平台及 SQLite 原始异常由后续 Repository/适配边界转换为可供界面处理的失败信息，区分引擎和持久化失败。不得通过匹配原始报错字符串控制流程。
- 引擎先持久保存暂停回执及材料，再交付；inspect 是非破坏性读取。Repository 在同一事务提交业务状态及确认高水位，然后 acknowledge；写入失败不确认，确认失败可重放，不重新传输。任务移除后最后确认行仍保留至安全回收。
- 暂停/失败的普通确认不释放恢复材料；插件 autoCleanDatabase=false 不能替代原生读取/确认和资源生命周期补丁。只在已提交的取消、确认重下或发布完成意图下，显式释放归属匹配的恢复引用，旧确认不能删除新材料。
- EngineEvent 独立提供累计 downloadedBytes 和 totalBytes?；未知总长不能停发字节，也不能通过比例反推。速度使用同执行的单调时间样本，换进程/恢复时重置窗口；未知总长的比例与剩余时间为 null。

```text
点击暂停 → Controller.pause(id) → Repository.pause(id)
          → 校验并固定执行身份 → Engine.pause(command) → 持久暂停回执
          → 事务保存业务状态和确认高水位 → acknowledge
          → Repository 发布任务快照 → Riverpod → View
失败     → 保留或对齐真实状态 → Controller → 可理解的界面反馈
```

### 4. Validation & Error Matrix

下表约束后续端到端边界；已有 DTO/AppStore 校验及异常行为见[持久化契约](persistence.md)，不能将其等同于具体引擎已验证。

| 条件 | 边界行为 |
| --- | --- |
| 标识为空或任务不存在 | Repository 拒绝，不调用引擎、不写任务 |
| 任务已经暂停 | 幂等成功，不重复暂停 |
| 不可暂停状态、旧会话/执行键/期望版本 | 返回 stateConflict；reason 区分 staleSession/staleExecution/staleReceipt，不重绑执行、不产生副作用 |
| 引擎拒绝、权限不足或执行失败 | 解释原因，不发布虚假成功，不自动清理仍引用的恢复材料 |
| 已暂停但业务提交/确认失败 | 报 persistenceFailure、保留真实暂停；业务未提交不确认，确认失败重发已保存确认行 |
| 订阅或初始读取失败 | 展示错误与重试，不伪造空列表 |

### 5. Good/Base/Bad Cases

- Good：活动任务暂停成功，流更新为实际暂停状态，续传数据保留，保存后的记录支持重启恢复。
- Base：空任务集合展示空态；已暂停任务重复暂停不重复下发引擎命令。
- Bad：平台拒绝暂停，页面提示原因，任务不因点击动作变成“已暂停”；已暂停但保存失败时明确提示恢复风险。

### 6. Tests Required

以下包括已覆盖的领域/存储断言和仍需实现的跨层测试；现有测试与平台未验证范围见[持久化契约](persistence.md)，不以当前主机单元测试代替真实引擎验收。

- Repository：当前不可变快照与分类数量；写业务状态和确认高水位为同一事务，删除任务不级联最后确认行。
- 暂停：Future 成功前实际停止、材料/回执及业务状态已保存；业务提交前不确认，确认失败不回滚真实暂停、不恢复传输。
- 命令：空快照返回当前会话；重复 commandId 幂等，旧会话/执行键/期望版本均拒绝，不在超时重试时替换身份。
- 交付故障注入：回执持久后、读取后业务提交前、提交后确认前分别终止；重放不重复副作用；零重试失败不丢恢复材料，旧确认不删新材料。
- Widget / Provider：等待时不伪造状态，保存/确认失败可见；销毁页面不取消引擎。
- 恢复：Android/macOS/Windows 重开只恢复记录；iOS 关联既有任务、不重复提交/自动重试失败项。
- 未知总长：完成前累计字节持续增长；总长、比例、剩余时间保持未知，重建速度窗口不产生负值或跨进程时间差。
- 文件与续传：实际恢复 GET 的 200/坏 Range/变化验证器在文件写入前返回 restartRequired，旧部分文件长度和散列不变；发布在创建前有持久操作，创建/最终操作后中断不重复目标，不猜测删除。
- 平台：默认/自选目录、Android 后台与重启、macOS/Windows 退出与授权、iOS 会话和私有恢复材料分别做原生/实体设备验证；Dart fake 不替代平台结论。

### 7. Wrong vs Correct

以下是 Controller 内的方法片段示意，假定 `repository` 已注入；UI 必须处理异步失败。

错误：点击时先改页面副本，未等执行成功就显示暂停。

```dart
Future<void> pause(String taskId) async {
  markTaskPausedInLocalList(taskId);
  await repository.pause(taskId);
}
```

正确：等待 Repository 执行，通过订阅任务流呈现实际状态；操作中的提示与任务状态分开。

```dart
Future<void> pause(String taskId) async {
  await repository.pause(taskId);
}
```

## 下载管理器的其他业务约束

来源：[需求文档](../../../.agents/specs/download-manager/requirements.md)。以下边界在后续功能设计和测试中必须保留。

- 任务、配置和设置持久化；执行回执先落引擎日志，再由 AppStore 同事务保存状态与确认水位，最后确认回收。暂停/失败的材料不随终态或页面释放清除；检查点与释放条件以设计契约为准。
- Android/macOS/Windows 进程终止或设备重启后恢复记录，未完成任务等待用户手动继续。iOS 已获准由系统继续管理既有后台下载，应用重启只关联任务与同步实际状态，不重新提交失败或取消任务；用户强制退出后的系统取消任务等待用户操作，设备重启后的状态先查询系统，不自行猜测或重排。
- 恢复必须在实际 GET 响应写入前检查安全性；HTTP 200、错误 Content-Range、验证器/偏移不符返回 restartRequired，保留原部分文件。HEAD 预检和插件配置不能替代拦截；从零下载须先取得用户确认。
- 创建任务时固定目标目录：任务指定目录优先，否则读取当时全局默认目录。可复用配置没有独立目录时，每次发起新任务读取最新默认值。
- Android 初始默认位置为公共 `Download/Downloader/`；macOS/Windows 使用系统当前用户下载目录下的 `Downloader`，不能硬编码绝对路径。iOS 使用可持久访问的应用内默认位置，具体文件访问能力待验证；实际访问与授权由平台适配处理，选择器取消保留原值。
- 用户目录创建目标前，先持久登记 PublishOperation、唯一操作定位及阶段；创建和最终发布结果须核对归属，不仅凭同名文件。结果 uncertain 时保留记录、完整暂存和处理入口，不重复新建/猜测删除。各平台恢复能力和不覆盖规则见设计；不完整文件不标完成。
- 暂停保留续传数据；取消停止传输、清理未完成文件后移除任务。清理失败要报告并保留可追踪信息，不能静默遗留文件或虚报成功。
- 删除完成记录与删除文件是独立选择；文件不存在时仍可清除记录。重新下载创建新任务，保留原已完成文件；删除可复用配置不删除任务或文件。
- 文件打开交给所在平台的系统处理程序；APK 系统安装交接仅适用于 Android。权限或处理程序不可用时反馈原因并保留记录，不绕过 iOS 或桌面平台的限制。不得引入分享、代理等首期排除功能。

## 待验证与后续补充

- 引擎：固定 9.5.9 补丁及 PluginEngine 已实现；桌面日志跨 isolate 串行写入、prefix 安全恢复、未知长度字节、确认及故障回归已独立复核，见[插件执行契约](plugin-engine.md)。周期/停止全文件扫描已用固定块有界摘要替代，并独立实测超过 4GiB 的 HTTP 落盘、暂停及内容核验；恢复仍线性认证磁盘 prefix，不能将局部通过视作整个插件子任务验收。
- 平台：iOS 私有 resume 安全、原生材料释放/临时文件保护失败及真机生命周期，Windows 实机、最低版本、默认目录/持久授权/系统打开仍待验证；Android/桌面不得自动恢复，iOS 不重复提交。
- 存储：AppStore v1 与确认行已落库；插件独立执行日志不写业务表，确认必须核对实际业务提交。用户目录发布恢复未实现；提供方不支持安全恢复时报能力错误，不假定所有 URI/文件身份稳定。
- 依赖与发布：sqlite3 3.5.2、path_provider 2.1.6、固定 9.5.9 path 插件已解析锁定；Riverpod 与目录选择仍待接入。macOS release/iOS 无签名构建仅在临时 host 目标 12/15 编译通过，仓库 10.15/14 仍未验证，Windows 未构建。业务功能铺开前须关闭设计所列安全门槛。

## Android 执行协议、Service 与私有暂存（主机局部通过）

### 1. Scope / Trigger

适用于 AndroidEngine、原生通道、Service/Coordinator、传输/恢复核心及 OwnedMaterialCleanup 的命令、执行和清理边界。2026-11-04 v7 显式取消生产源码独立局部 PASS：88项 JVM、flutter analyze 和 debug APK 构建通过；Dart 未改，沿用前轮独立102项。20项 Android SQLite instrumentation 仅编译；真实 Service/SQLite/通道及 API29/30/33/35/36 设备矩阵仍 BLOCK，完整任务不得勾选或归档。

### 2. Signatures

- 通道固定为 `downloader/android_engine`、`downloader/android_engine/events`，请求均含 `protocolVersion=1`。`inspect` 只携带版本，返回 `{protocolVersion,ownerSessionId,sequence,receipts}`，空集合也返回当前会话。事件有当前会话、单调 sequence 和完整回执。
- enqueue/pause/resume/cancel 携带扁平 taskId/engineId/generation、commandId、ownerSessionId、expectedReceiptVersion；enqueue 另传 `input=EngineTask.toJson()`，嵌套 key 必须匹配。ack 为扁平执行键、receiptVersion、releaseResumeRefs。不会把内部嵌套命令 JSON 原样当通道命令。
- 日志入口：`register(command,session)`、`acceptWorker(command,session)`、`acceptResume(command,session)`、`newTransfer(command,session,allocation)`、`newResumeTransfer(command,session,allocation): ResumeTransfer`、`registerMaterials(command,session,payload,facts)`、`saveResumeCheckpoint(command,session,forced)`、`inspectResume(key)`、`newRecovery(command,session,ref): ResumeTransfer`、`inspectCandidate(key,resumeCommandId)`、`inspectRecoveries(key)`、`inspectMaterials(key)`、`workerReceipt(command,session,checkpoint,finished)`、`stopWorker(worker,command,session,checkpoint)`、`finishWorker(command,session,checkpoint,pause)`、`inspect()`、`acknowledge(ack)`；既有 `complete` 保留旧命令路径。公开 resume 经 acceptResume/newResumeTransfer；newRecovery 保留旧内部 pending 路径及其严格源版本门。
- 独立 `android_execution_v1.db` 的 user_version=7；保留 v1–v6 历史，新增 cancel_cleanups、cancel_cleanup_members，不打开共享 AppStore。`beginCancel(command,session,worker?,checkpoint?)` 原子登记意图；`finishCancel(command,session)` 仅在停止及终态保存后清理并提交结果。
- ServiceLifecycle：`issue(stop)`、`pending(token,action)`、`foreground(token,instance,action)`、`ready(token,instance)`、`worker(token,action)`、`revoke(token)`、`idle()`、`stop(ticket,action)`、`destroy(instance,action)`；token 和实例归属只在当前进程有效，不从数据库重建调度。
- `HttpTransfer(appFiles: File, authorizedUrl: String? = null, onCheckpoint: (ForcedMaterial) -> Unit = {}, onAllocation: (ExecutionKey,File,File) -> Unit).run(key,url,stop,onSample): Staged`；Sample 为 bytes:Long、total:Long?、monotonicMs:Long，Staged 为 file、bytes、total、effectiveUrl、stop、sha256。`Stop.request(PAUSE|CANCEL)` 只发布停止请求。生产 newTransfer 注入检查点持久回调；`ResumeTransfer.run(stop,onSample,onCopied): Staged` 只由内部固定材料工厂构建，测试故障注入不改变默认真实关闭/断连。

### 3. Contracts

#### 执行日志与材料授权

- 进程随机会话、单协调队列不依赖 Activity；detach 只解绑监听。命令深复制并重新解析，固定完整执行键、commandId、会话、期望版本及 URL。原生只接受 Int/Long 计数，拒绝负数、未知版本、控制字符、非法名称和嵌套身份不匹配。
- register 原子登记执行及 NULL 未知命令结果；acceptWorker 同事务保存 queued 接受结果及 worker_authorizations。不可变 enqueue 结果与后续递增 worker 事实分离；同 commandId/规范化载荷重放，不同载荷拒绝。未知 NULL 结果不是重跑 HTTP 的许可。
- v1→v7 保留旧历史并依次补材料、worker、恢复/候选/分支及取消清理表；v2–v6 仅补后续表。SQLiteOpenHelper 同事务迁移 DDL 与 user_version，未知版本拒绝，失败保留数据库；第二 DDL 失败回滚前一 DDL、版本和新意图，回滚失败不覆盖首异常。迁移断言目前仅编译，未在 Android 设备执行。
- materials 以 command_id 为主键，保存完整执行归属和唯一 payload/facts 私有路径；外键引用命令和执行。worker_authorizations 以 enqueue/resume command_id 为主键，保存 session、engine、generation、version、allocated、stop、finished；完整命令和 task 归属仍在事务内核验，不能仅信任外键。
- newTransfer 捕获完整命令/授权 URL；run 在建目录前拒绝 URL 替换。分配事务重查命令载荷、当前会话/执行/代次、授权版本、未停止/未完成及未消费条件，再消费一次性分配权并登记材料；旧 pending 路径仍要求 result=NULL，旧库命令不自动升级为 worker 权限。一个命令不能二次分配，即使原文件不存在也不能重下。
- 原生 Context.filesDir 是唯一私有根，不使用 Dart staging 路径授权；拒绝根别名和 symlink 暂存目录。先提交 UUID 双文件归属，后以 CREATE_NEW+NOFOLLOW_LINKS 排他创建 facts/part，再请求网络；失败保留材料。空 staging 目录可能先存在，不授予恢复/删除权。私有 sandbox 排除同 UID 恶意写入者，未承诺完全 TOCTOU 安全或目录项 fsync。
- worker、stop、终态及暂停结果在同一事务核对完整命令、会话、执行键、最新代次/版本、pending/finished 条件；持久 cancel 不可被 pause、running 或 publishing 撤销。终态 checkpoint 与暂停命令结果同事务提交，成功结果丢失后同 checkpoint 重试不再分配版本，不同 checkpoint 拒绝。
- inspect/inspectMaterials 非破坏，不安排网络、不清理材料；facts 仅诊断，不能凭文件存在推定完成/可恢复/可删除。原生 ack 仅核对已有回执/归属/高水位，普通确认保留材料，当前所有非空 releaseResumeRefs 仍拒绝。

#### 恢复材料、公开接受事务与实际 GET 安全门

- ForcedMaterial 为 `{key,source,offset,total?,effectiveUrl,etag,prefixDigest,algorithm}`；NativeResumeMaterial 另带本日志生成的 opaque ref、源 commandId 和 receiptVersion。resume_checkpoints 以 ref 为主键、command_id 唯一并引用 materials，保存 receipt_version、offset>0、total?、url、etag、digest、algorithm；执行归属通过材料表及完整事务校验核对，不接受 channel 传入路径/URL 授权。recovery_attempts 以恢复 command_id 为主键保存 source_ref/phase；recovery_operations 以 id 为主键，恢复命令与 candidate 均唯一，保存 source_ref/candidate/phase。
- newTransfer 生产链在 payload.force 与 facts.force 成功后才调用 onCheckpoint，onSample 只表示累计进度。最终 proof 必须等待 payload 与 facts 均真实关闭成功；force/close/短 EOF 失败不能在 finally 提升最终 offset，较早已认证 proof 保留。材料实际长度允许大于认证 offset，未提交 tail 不纳入认证、不截断。无强 ETag 不生成恢复证明，也不对外声明 supported。
- saveResumeCheckpoint 核对完整命令/会话/worker/当前版本和材料归属；持久 cancel 后不推进 proof。offset 不倒退；total/最终 URL/ETag/算法不得改变，同 offset 的 digest 必须相同。worker 回执递增只关联已有 proof 的 receiptVersion，不借此提升认证 offset。facts 仍仅诊断，不能代替恢复三表。
- NativePrefixDigest 算法固定 `native-prefix-v1-65536`：64KiB 分块、32字节链及最多64KiB tail；seed 为 SHA256(ASCII `downloader/native-prefix/v1/seed`)。每块 F(domain,chain,index,data,size)=SHA256(ASCII domain || 0x00 || chain || int64BE(index) || int32BE(size) || data[0:size])，完整块域为 `downloader/native-prefix/v1/block`、index 从0开始；snapshot 以 `downloader/native-prefix/v1/end` 域、总 length 与未满 tail 计算64位十六进制摘要，不消费状态。算法名独立保存，不冒充普通文件 SHA256，不 clone provider、不周期重扫历史文件。恢复仍线性读盘重建并认证 prefix，每64KiB检查 Stop。
- newRecovery 冻结完整已登记 pending resume 命令，核对 payload/NativeCommand/session 一致、本日志 ref、最新执行/代次/期望版本、源 worker 已 finished 且未 cancel、worker/proof/current receiptVersion 相同；在工厂、实际 GET 前、candidate 登记和内部 staged 时重验。beforeRequest 先持久一次性 recovery_attempts，结果不明不得同命令重发网络；inspect/重开不调用该工厂调度。
- 先认证磁盘 prefix，再实际 GET 携带 Range/If-Range。只接受206、完全一致强 ETag、identity、精确 Content-Range 起点/终点/总长、存在时相符的 Content-Length 与不变的原已知 total；64位溢出拒绝。200/416/redirect、坏/缺/弱验证器、坏 Range 或 prefix 返回 restartRequired，不发确认外的从零请求，不创建输出。
- 通过实际响应门后先提交 recovery_operations copying/candidate 归属意图，同事务在 recovery_candidate_files 登记 operation_id 与唯一 facts_path，再在私有 canonical 父目录 CREATE_NEW+NOFOLLOW 创建配对 UUID payload/facts，流复制并复验认证 prefix 后才写 suffix；原件和 tail 保留。完整 EOF、force 和真实 close 后才记内部 staged；复制/登记/关闭失败保留原件与候选，不标用户 completed。
- candidate_checkpoints 按 operation_id 和唯一 resume_command 保存 source_ref/source_version、固定 receipt_version、offset/total/URL/ETag/digest/algorithm/facts_path。写入重验完整冻结命令/owner/session/key/源快照与当前 worker 授权，operation 必须仍为 copying；offset 不倒退、同 offset 摘要不变。原 total 未知可由206确定，之后不漂移。`inspectCandidate(key,resumeCommandId)` 只读指定分支；读取不晋升或授权网络，生产认证回调才可事务推进 active_branches。旧内部 newRecovery 仍沿用其 source=head/finished 门；候选释放仅经下述显式取消清单。
- 同一 Stop 贯穿认证/复制/网络。初始认证停止零 GET/零 candidate；复制停止只保留已登记 partial，不认证未完整复制的 prefix。内部 `Stopped(reason,candidate?,bytes)` 表示真实停止，bytes 仅为源位置/复制诊断，不是新下载量或认证 offset。suffix 暂停须等待真实 input/output/facts 退出及 proof 提交；周期 proof 先双 force，final 先双 close。Stopped 不得掩盖 FILE 关闭或 NETWORK 断连错误，已有首 IO/Journal 错误仍主导。双 close 与最终 proof 回调后重读 Stop，facts.close 期间 late CANCEL 不产生新 proof 或 staged。等待响应头已观察到 stop 时先处理停止，不能将迟到200误报为资源不安全；完整 prefix 复制后暂停也不获取已失效连接的 input。
- acceptResume 仅由 Coordinator 在当前进程同执行无 Work（包括终态待补存）时调用；同事务核验真实 Runtime session、完整命令/执行键/当前 head/最新 generation、原生 input、非取消/非 publishing 状态及原生源材料归属。冻结历史 source N 的完整 proof，原子保存 queued N+1、不可变接受结果及独立新 worker 授权，不能要求历史源版本等于新 head。
- resume_sources 以新 worker command_id 为主键保存 root_ref 和不可变 source snapshot；active_branches 按 engine/generation 保存确定已认证分支及 root_ref；retired_workers 记录旧 command_id、retired_by 和 waitingRecovery 原因。只有显式当前 session 用户 resume 且 Runtime 无同执行 Work，才可在接受事务记旧 session 未 finished 授权退休，不伪造 finished；inspect/open/重连/旧 Intent/NULL 结果均不退休或联网。
- newResumeTransfer 的 GET 前/候选登记/proof/staged 回调均重验完整冻结命令、当前 worker/head、历史 source、root ref、operation/candidate/facts 与完整 key。一次性 beforeRequest 意图仍先于 GET；未知结果不得重发。同 key 一 worker、全局两 worker，复用同一 ServiceLifecycle token/ready，无第二调度器。
- active branch 仅在完整 prefix 经双 force 或最终双 close 的认证事务后晋升，不按文件现长/mtime猜测；旧 source/tail/candidate 保留。持久 CANCEL 拒绝新 proof，持久 PAUSE/CANCEL 在 staged 事务也转为 Stopped，不能被迟到 staged 撤销。只有真实 proof 才输出 supported/opaque resumeRef，publishing/cancelling 不授予继续；known total 且 offset==total 保守 restartRequired，不自动重下或本地发布。
- 目录 fsync、同 UID 恶意并发替换和设备磁盘故障不在当前已验证保证内。

#### Service 生命周期与停止

- 生产链为 Dart AndroidEngine → 通道 → 进程串行 Coordinator → 当前进程 token → DownloadService → 最多两个 HttpTransfer/ResumeTransfer worker → SQLite → EngineEvent；同执行最多一个 worker。只有显式本进程 enqueue/resume 可调度；inspect、重连、进程启动、空/旧/重复 Intent 和未知结果不得创建网络请求。
- Manifest 声明 INTERNET、FOREGROUND_SERVICE、FOREGROUND_SERVICE_DATA_SYNC、POST_NOTIFICATIONS；Service exported=false、foregroundServiceType=dataSync、START_NOT_STICKY，无 boot receiver、WorkManager 或自动网络重试。按需求允许明文 HTTP，HTTPS 保持默认证书验证。API<26 拒绝服务；候选最低 API29 未因本轮修改。
- Runtime 与 Service 共用同一 ServiceLifecycle；token、实例、ready、idle epoch 在短同步临界区核验，实际 startService/startForeground、worker 提交和 idle stopSelf 按同一归属执行。启动动作抛错立即同步撤销 grant，不等待日志队列；失败前台启动立即安排 epoch 约束的 idle 停止。
- 新 enqueue 使旧 idle 票据失效；destroy/timeout 只失效所属实例 grant，并先发布所属 worker 停止标志，后排日志保存。退休实例不绑定新授权且给出明确失败，不自动重新调度。timeout 整体退休所属实例时无参 stopSelf()；无效/重复 Intent 只按 startId 停止不属于当前 owner 的实例，不误停有效新请求。
- 生命周期锁内不访问 SQLite、不等待 Future 或网络退出。标准启动/通知/停止 IPC 的设备延迟尚未验证；不能以短临界区假设替代平台证据。
- Stop 原子优先级 CANCEL>PAUSE；disconnect 在独立 daemon 池执行且不持 Stop/Lifecycle 锁，attach 后重查 stop。系统停止标志不排在可能阻塞的日志队列后；用户 pause/cancel 仍先持久意图再发信号。标志可见不保证平台 connect/headers/read 立即退出。
- pause Future 必须等真实 run 退出、payload/facts force/close 和终态提交后才成功，失败 pause 重放仍失败。cancel 必须再完成归属清理和完成结果提交；中间 cancelling 接受回执不代表成功，更不代表业务任务已移除。ready 前已停止的 enqueue Future 也必须确定结束。
- running/进度/终态持久后才 emit，sequence 会话内递增，事件消费者异常不能回滚已持久操作。完整私有暂存只到 publishing，未完成目标发布不能 completed。

#### 终态补存、HTTP 与 Dart 边界

- 终态落库失败保留冻结 Work.terminal、完整命令和材料，active=false 释放 worker 槽；inspect 明确报 persistenceFailure/terminalSavePending，不伪造快照版本或隐式补存。显式重发原完整 enqueue/resume/pause 仅重试本地 finish，不创建 worker/HTTP/copy/candidate；变化身份/会话/版本/载荷拒绝，并发同命令补存串行且幂等。
- 历史 finished worker 的同 checkpoint 重放，恢复派生字段使用该历史 receipt 已提交的 resumeSupport/resumeRef，不按最新 active branch 重算；其余 checkpoint 字段、完整 worker 身份及 pause 命令/result 仍精确比较。新分支晋升不能污染旧终态幂等，也不能借此接受改变 bytes 的载荷或再分配版本。
- v7 同完整 cancel 显式重放可在真实 worker 停止后补存终态并重试本地清理，不创建新 GET/worker。重放复用递归数值语义比较（Int/Long 等价），仍精确核验完整持久载荷；历史 v6 无清理操作的 cancel 保留原 cleanupFailure，须当前 session/head 新命令。kill 后只承认持久事实，不从 facts 猜测完成。

#### 显式取消与归属材料清理

- beginCancel 在同 Runtime 串行队列先事务保存 cancelling、完整命令及所有原件/候选 payload/facts 清单，再发 CANCEL；活动 Work 等真实退出、force/close 和终态落库，之后才 finishCancel。paused/failed/旧进程无 Work 仅由当前 session 显式取消退休旧授权并本地清理，不启动 Service/HTTP。open/inspect 不重放清理。
- cancel_cleanups 保存 command_id、完整 key、intent_version、phase、result；cancel_cleanup_members 保存 source_id、配对路径和各成员 done。commands.result 是不可变接受结果，cleanup.result 仅在全部删除和完成回执事务成功后首次写入；完成回执仍为 cancelling/error=null、保留字节，不制造 completed。
- 清单从原生日志读取，不扫描目录。原件完整 key 与 enqueue 命令一致；候选只要 source root 或 resume 命令任一边关联当前 key，就必须两边一致，并核对 candidate proof 的 resume/source/facts 与 operation。finish 前重新比较当前完整归属集合，任一冲突整集合零删除。
- OwnedMaterialCleanup.run(pairs,deleted) 先验证整集合 canonical 私有根/父目录、唯一 UUID .part/.facts 配对、NOFOLLOW 普通文件，再逐成员删除并持久 done。已登记 missing 幂等；删除后 done 保存失败可显式重试。任一 IO/持久失败保留 pending，不宣称跨文件原子；未知孤儿、用户目标、普通/旧 ack 均无删除授权。
- 真实停止/关闭错误阻止原 cancel 清理成功，保留材料和诊断；持久 stop/finished/retired 阻断迟到 callback 新增证明。该保证依赖单 Runtime 串行门和私有 sandbox，不证明跨连接调度或同 UID 恶意替换安全。发布完成/确认重下的非空 releaseResumeRefs 仍拒绝。
- HTTP identity、连接15s/读取30s，最多10跳、每跳重新校验无认证 http/https 和 visited 循环检测；新下载只接受200，严格验证编码、Content-Length 和已知长度 EOF。64KiB 缓冲、64位计数、未知 total=null、独立单调字节样本、增量 SHA-256；周期 force 最多每秒，不全文件重扫。
- StageFailure/Failure 保留 JOURNAL/NETWORK/HTTP/FILE 阶段、稳定 code、首 cause 及 suppressed 关闭错误；非200/redirect/编码/长度为 httpFailure，SocketTimeout 为 timeout，其他网络为 networkUnavailable，Journal 为 persistenceFailure，文件为 fileWriteFailure。不得通过匹配原始异常字符串分类。fileUse 确保 Staged 返回前实际关闭；关闭失败不能认证 paused/staged。最终 disconnect 仍是 run 屏障的一部分。
- 输出关闭后固定一次停止原因，facts 与返回使用同一快照；之后的取消由 Coordinator 按持久意图协调，不回改冻结事实。公开 resume 复用安全 Range/验证器/prefix/candidate 门，拒绝不安全资源时返回 stateConflict/restartRequired，保留原件，不误报 fileWriteFailure 或未经确认重下。
- AndroidEngine.open(store:) 仅 Android；isAndroid 是主机测试注入。事件在首个业务订阅前顺序缓冲；仅显式成功 inspect 同步会话/序号，迟到旧 inspect 不覆盖新基线。Dart 不生成或重绑命令身份，不自动 enqueue/resume/retry。
- acknowledge 先读取真实 AppStore 完整 ReceiptAck，对现存同版本业务回执与非破坏 inspect 的完整载荷比较；await 后重读确认及任务再比较，冲突不发送 ack，不删除业务行。错误只放行稳定 code/reason，中文信息不泄露路径或原始 PlatformException；主机 fake 不证明真实平台通道。

### 4. Validation & Error Matrix

| 条件 | 当前行为 |
| --- | --- |
| 未知协议/方法/类型、非法输入 | protocolMismatch；不调度 |
| 旧会话/执行/版本、commandId 载荷变化或替换 URL | stateConflict，结构化 reason；拒绝副作用 |
| 材料分配无授权、重复分配、非私有 UUID 双文件 | 拒绝材料和网络，保留已登记未知意图 |
| 旧/空/重复启动令牌、退休 Service 实例 | 不启动 worker；明确拒绝有效新请求的启动失败，不自动重排 |
| 终态写失败或仍待本进程补存 | persistenceFailure/terminalSavePending；保留完整终态，显式原 enqueue/resume/pause 只补存 |
| HTTP 状态/重定向/编码/长度异常 | httpFailure；保留实际材料，不虚报 staged |
| 网络断开/超时、写入/force/close、日志失败 | networkUnavailable/timeout、fileWriteFailure、persistenceFailure；不虚报暂停成功 |
| 内部恢复缺/弱/变化 ETag、旧 proof/worker 版本、坏 prefix/Range、200/416/redirect | restartRequired 或对应 stateConflict；不创建 candidate，不覆盖原件、不从零重发 |
| 恢复复制/EOF/force/close/候选登记失败 | 保留原件、旧 proof 与已登记 candidate；不认证内部 staged 或用户完成 |
| 通知权限拒绝、后台启动受限、系统 timeout/destroy | permissionDenied 或 backgroundRestricted 等稳定失败；先停止授权、再保存受影响任务，保留材料；通知请求 UI 未实现 |
| 取消归属冲突、删除/完成保存失败 | stateConflict 或 cleanupFailure；不虚报清理完成，保留可重放意图和诊断 |
| 普通/旧 ack 或非空 releaseResumeRefs | 普通确认不删材料；非空引用仍 materialReleaseUnavailable |
| 公开 resume 无安全 proof/强 ETag、known total 且 offset==total | stateConflict/restartRequired；不从零请求、不自动发布 |
| 新分支后重放历史同终态；改变 checkpoint 载荷 | 原历史结果幂等、head 不变；变化载荷拒绝 receiptPayload |

### 5. Good/Base/Bad Cases

- Good：旧 idle 已排队，新 enqueue 进入后旧票据失效，旧 destroy 只影响旧实例；终态补存只落日志、HTTP 数不增长，同版本结果不重复分配。
- Base：空 inspect 返回会话/sequence/空回执而不网络；重复完整 commandId 重放；未知总长在 EOF 前持续增字节，总长和派生比例保持未知。
- Bad：SQLite 队列阻塞时系统停止仍须即时发布标志；disconnect 阻塞不延迟 CANCEL 优先级；关闭/落库失败不能返回 paused，取消回放不能变更已提交结果。
- 恢复 Good：offset=8192、原件24576；认证 prefix 并通过实际206后写新 candidate，原 tail 长度/hash不变。Bad：facts 关闭失败保留较早 proof；认证首块收到 CANCEL 时 beforeRequest/candidate均为零；旧 proof 不授权新事实。

### 6. Tests Required

独立 Gradle `:app:testDebugUnitTest :app:compileDebugAndroidTestKotlin :app:assembleDebug` 正常退出、debug APK 构建成功；88项 JVM（协议5＋HTTP20＋Coordinator30＋Lifecycle7＋Resume23＋Cleanup3）零失败/错误/跳过，flutter analyze 干净。Dart 未改，沿用前轮独立102/102。本轮日志 `/tmp/android-cleanup-check-gradle-final3.log`、`/tmp/android-cleanup-check-analyze.log`；审查进程超时前已完成正式报告，父代理核对保存结果，不将超时本身当验收。

- 生产 Lifecycle/Stop/Coordinator 确定性回调/latch：旧 idle/new enqueue/旧 destroy、新旧实例、启动失败立即撤权、foreground/ready 间失效、同实例多个 start 的 timeout、阻塞断连与取消优先。
- 真实 loopback HTTP/文件：最多两个 worker、未知长度、持久后事件、幂等命令、失败 pause、cancel 优先、终态保存失败不饿死其他下载、显式补存无新 HTTP、提交结果丢失/并发补存/身份变化；Journal 为 host fake，不能称真实 Android SQLite。
- HTTP 覆盖短EOF/编码/长度/redirect、阻塞读取停止、路径/symlink/sentinel、分配先于网络和 URL 固定；typed phase、生产 fileUse helper 关闭故障不替代真实设备磁盘 force/close。大长度测试仅声明4294967419而实际5字节，不是超过4GiB传输。
- 恢复测试：独立 Python hashlib/struct 固定向量及重复 snapshot；真实 GET 206/200/416/redirect、强弱验证器、坏 Range/长度/total、源 prefix 与 tail、复制中断、candidate close、首异常与 typed suppressed 关闭异常。after-force/双 close、late CANCEL、响应头停止等已有核心回归保留。
- 公开 Coordinator.resume 入口真实 socket/file/core 回归：enqueue→pause8192→resume→pause16384→resume→publishing，3GET/2candidate，逐字节/whole SHA256、原24576字节 tail及旧 candidate不变。重复/NULL/旧身份、坏 prefix、queued stop、同执行一 worker/全局两 worker、新 Runtime 零请求与显式继续、persist-before-event、终态补存零新增 GET/candidate。Journal 为 host fake。
- 认证/复制各 PAUSE/CANCEL 四组合、复制暂停伴随 payload.close 失败、final proof 屏障暂停伴随提交失败和持久 cancel 竞争使用确定 latch；分别保留旧 proof、返回 fileWriteFailure/persistenceFailure 或 cleanupFailure，不把 Stopped.bytes 作进度。
- 20项 SQLite instrumentation 覆盖历史迁移/回滚、resume/branch 归属与 v7 意图/完成结果、候选双向归属、删除前重验。全部仅编译；真实 Android SQLite、跨连接清理竞争及完整 generation/故障组合尚未执行。
- 取消生产入口真实 socket/file 回归覆盖终态补存、错误身份拒绝、Int/Long 等价及并发重放只补一次、零新增 GET，关闭失败保留原件/候选；Journal 为 host fake。清理核心覆盖整集合校验、symlink/越界零删除、部分删除和 done 失败重试。
- 后续执行 API29/30/33/35/36 的 Service、通知/后台限制、timeout、Activity 重连、强杀重开零 HTTP、TLS、SQLite/磁盘故障和真实大文件；目录 fsync、发布完成材料释放与用户目录发布仍未验收。

### 7. Wrong vs Correct

错误：`stopService(globalIntent)` 排入主线程后不验证新授权，旧 onDestroy 全局停止；或 `stop.request(PAUSE); emitPaused()`；或保存失败后删除 Work 并重跑下载。

正确：按实例/token/idle epoch 重验实际启动与停止 → 用户意图先持久（系统紧急停止先发标志）→ 等真实 worker 退出/关闭 → 按取消优先冻结终态 → 事务保存不可变回执 → 交付；补存失败保留入口，只重试原本地提交，设备未测保持未验收。

恢复错误：将 onSample 当持久偏移、facts.close 前提交最终 proof、按源文件现长追加原件，或旧 proof 通过工厂后不再核对版本。
恢复正确：当前用户 resume → 原子冻结 source N/接受 queued N+1/新 worker 授权 → 同 ServiceLifecycle → 重验冻结 source 与新 worker → prefix 认证 → 一次性 GET 意图 → 实际206门 → candidate 意图 → 新文件复制/复验/追加 → 双 force/最终双 close 认证并晋升 branch → 持久 stop 重验/终态事务 → 事件；失败补存不重新请求，设备未测保持未验收。

清理错误：收到 cancelling 接受回执就删文件，按路径扫描候选，或普通 ack 删除暂停材料。
清理正确：持久完整取消意图/归属清单 → CANCEL → 实际退出/关闭/终态落库 → 双向归属重验及整集合文件校验 → 逐成员删除/done → 完成结果事务；失败显式原命令重放，不新增 HTTP。
