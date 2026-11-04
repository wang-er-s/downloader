# Flutter 架构与跨层契约

## 设计决策：Feature-first + MVVM + Repository/Service + Riverpod

下载管理器页面数量有限，但下载生命周期、任务恢复和文件访问必须独立于页面。采用按功能组织目录、MVVM 式职责划分及 Repository/Service 分层；Riverpod 管理界面状态与依赖，复杂业务按需提取 UseCase。

该分层决策已确认；领域/执行 DTO、DownloadEngine 与 FileStorage 接口及 AppStore v1 已实现，现有 API 与验证范围见[持久化契约](persistence.md)。PluginEngine 与固定插件补丁已接入，桌面局部验证见[插件执行契约](plugin-engine.md)；AndroidEngine 的 Dart 桥接已通过主机独立检查，但 Repository、Android 原生传输和用户文件操作仍待实现。插件子任务尚未完成平台验收，当前 macOS 运行结果不能代表 iOS/Windows/最低版本通过。

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

## Android 首轮协议/日志检查点（局部通过，非完整引擎）

### 1. Scope / Trigger

适用于 AndroidEngineChannels、EngineProtocol、ExecutionJournal 及 Dart AndroidEngine 调用方。2026-11-04 协议代码、实际 Kotlin 编译、五项 JVM 协议测试和 Dart 桥接 94 项测试通过；另有内部 HttpTransfer 的11项主机真实 HTTP 测试通过，边界见后文。三项 Android SQLite instrumentation 仅编译。服务集成、安全续传及设备生命周期仍未实现或未验收。

### 2. Signatures

通道为 `downloader/android_engine` 和 `downloader/android_engine/events`，所有请求含 `protocolVersion=1`。inspect 请求仅版本，返回 `{protocolVersion,ownerSessionId,sequence,receipts}`；当前无事件生产者，sequence=0。命令携带扁平执行键、commandId、ownerSessionId、expectedReceiptVersion；enqueue 额外使用 `input=EngineTask.toJson()`，嵌套 key 必须匹配。ack 使用扁平执行键、receiptVersion 和 releaseResumeRefs。

日志入口：`register(command,session)`、`complete(command,session,checkpoint)`、`inspect()`、`acknowledge(ack)`；独立 `android_execution_v1.db` v1 包含 executions/commands/receipts，不打开 AppStore。

### 3. Contracts

- 进程随机会话和串行队列独立于 Activity；detach 只解除通道，不触发传输。inspect 非破坏。
- SQLite 写事务原子登记执行身份与 NULL 未知命令结果；complete 原子分配递增回执并保存命令结果。相同 commandId/规范化载荷回放，不同载荷拒绝；NULL 结果不自动重执行。
- 原生 ack 仅验证已有回执/身份/高水位，当前拒绝全部显式材料释放并保守留历史。Dart AndroidEngine 还需先核对 AppStore 已提交的完整确认和现存同版本业务回执；确认期间重读任务与回执，不能仅信任调用参数。
- 原生类型验证只接受 Int/Long 计数，拒绝负数、未知版本、控制字符、非法名称及不匹配嵌套 key。材料定位形态校验不等于路径归属授权。
- 真实 SQLite 事务/版本/磁盘故障尚待设备验证；回滚失败附加到原异常，绝不删库重建。

### Android Dart 桥接补充

- `AndroidEngine.open(store: ...)` 仅在 Android 打开；主机测试通过 `isAndroid` 注入，不改变生产平台判断。MethodChannel/EventChannel 使用固定名称和 `protocolVersion=1`。
- 命令使用扁平执行键，`enqueue` 保留完整 `input=EngineTask.toJson()`；`enqueue/resume` 接受原生持久命令结果，`pause/cancel` 必须校验回执执行键、状态和版本。
- 事件在首次业务订阅前按顺序缓冲；只有显式成功 `inspect` 才允许更新会话/序号基线，事件本身不能授权换会话。旧 inspect 的迟到结果不能覆盖较新的同步。
- `acknowledge` 在发送原生确认前读取真实 AppStore 确认行，并对现存同版本业务回执与非破坏 `inspect` 结果做完整比较；inspect 期间再次读取任务和回执，冲突时不发送确认。原生拒绝材料释放时，业务行保持不变。
- 主机 messenger fake 与 sqlite3 测试证明桥接边界，不证明 Android 原生 SQLite、服务/HTTP、真实通道或设备验收。

### 4. Validation & Error Matrix

| 条件 | 当前行为 |
| --- | --- |
| 未知方法/版本/类型/非法输入 | protocolMismatch |
| 旧会话、执行键、版本或改 commandId 载荷 | stateConflict，并保留结构化 reason |
| 传输方法通过解析和会话检查 | stateConflict / transferUnavailable；无伪造网络或暂停成功 |
| 非空 releaseResumeRefs | stateConflict / materialReleaseUnavailable；不推进水位、不删文件 |
| SQLite/JSON 失败 | persistenceFailure；保留原生诊断，不伪造空快照 |

### 5. Good/Base/Bad Cases

- Good：已登记且已完成命令以同载荷重放，返回原不可变回执。
- Base：空 inspect 返回当前会话、0 序号和空集合，不安排网络。
- Bad：直接转发嵌套 Dart 命令、旧会话或未提交业务确认，不得伪造成已接受传输或可释放材料。

### 6. Tests Required

独立 Gradle `:app:testDebugUnitTest :app:compileDebugAndroidTestKotlin` 通过；五项 JVM 测试含 64 位/null、控制字符及保留名称断言。三项 SQLite 测试覆盖重开/确认、回滚与竞争，但没有连接设备，不能计通过。Dart 桥接独立复核及父代理顺序复跑 flutter analyze 干净、flutter test 94/94（基础48 + 桥接46）；包含真实主机 SQLite 的确认竞争、初始事件和显式重新同步。后续补真实通道/重连、未知原生库版本/磁盘错误、材料释放、服务/HTTP 及 API29/30/33/35/36 生命周期矩阵。

### 7. Wrong vs Correct

错误：把 `EngineCommand.toJson()` 的嵌套 key 原样发送，或将原生 ack 当作已证明业务提交。

正确：显式映射扁平通道字段并保留完整执行身份；Dart 对照 AppStore 实际持久确认，再发送 ack；传输未实现保持明确错误，设备未测保持未验收。

## Android HTTP 私有暂存核心（主机局部通过，尚未接服务）

### 1. Scope / Trigger

适用于 [HttpTransfer](../../../android/app/src/main/kotlin/com/example/downloader/downloader/HttpTransfer.kt) 及其后续原生 Service 调用方。当前仅有测试调用方，通道仍 transferUnavailable；不能将核心测试通过当作可用 AndroidEngine。

### 2. Signatures

`HttpTransfer(appFiles: File).run(key: ExecutionKey, url: String, stop: Stop, onSample: (Sample) -> Unit): Staged`；Sample 含 bytes:Long、total:Long?、monotonicMs:Long。Staged 含 file、bytes、total、effectiveUrl、stop:Stop.Reason?、sha256。`Stop.request(PAUSE|CANCEL)` 只请求停止；`resume()` 明确抛 stateConflict/restartRequired。

### 3. Contracts

- 根目录只能由原生 Context.filesDir 注入，拒绝 Dart 路径授权、根别名与 symlink 暂存目录。随机 UUID facts/part 排他 CREATE_NEW+NOFOLLOW_LINKS；先 force 身份意图再创建 payload，不打开旧 partial，不覆盖现有文件。依赖私有 sandbox 排除恶意同 UID 目录替换，不声称完全 TOCTOU 安全。
- 默认 HTTPS 校验；HTTP identity、15s连接/30s读取、最多10跳重定向，每跳重新校验无认证 http/https 并检测循环。仅新下载200；已知长度严格验证，未知长度仍发真实累计字节。64KiB流缓冲、增量 SHA-256，周期 force 至多每秒，不重扫全文件。
- request 返回不是停止屏障；调用方等待 run 真正退出及 force/close 成功，再提交 ExecutionJournal 回执。输出关闭后固定一次终态停止原因，facts 与返回使用同一快照；晚到取消由 Service 的取消优先意图协调。取消目前只停止保留，不代表清理成功。
- facts 仅为诊断材料，不是持久恢复证明。原生日志联动、目录 fsync/重启归属、安全 Range/prefix/candidate 恢复及受控释放均待实现。staged 只表示完整私有暂存，未发布用户目标。

### 4. Validation & Error Matrix

| 条件 | 当前核心行为 |
| --- | --- |
| 非法根/暂存别名或 symlink | 拒绝，不触碰外部已有文件 |
| 非法跳转、非200、编码/长度异常、短EOF | 异常并保留实际材料，不返回 staged |
| 读被停止中断 | 等待输入/输出关闭及终态facts保存后返回停止结果 |
| force/close/消费者回调失败 | 异常，不虚报暂停或暂存成功 |
| 请求续传 | restartRequired，不打开或修改原件 |

### 5. Good/Base/Bad Cases

- Good：未知长度正文在EOF前持续增字节；实际阻塞读取被跨线程停止，run退出后材料与关闭facts一致。
- Base：两次新下载分配不同私有文件；完整暂存不等同于用户目录发布。
- Bad：晚到PAUSE不能让facts记staged而返回PAUSE；CANCEL请求返回不能视作已清理。

### 6. Tests Required

独立 Gradle 编译及JUnit16项（协议5＋HTTP11）、flutter analyze、diff检查通过。[真实Socket测试](../../../android/app/src/test/kotlin/com/example/downloader/downloader/HttpTransferTest.kt)覆盖字节/散列、未知长度、重定向、短EOF、编码/长度异常、真实阻塞停止、symlink与sentinel、连接失败和消费者异常。大长度仅声明4294967419、实际5字节，不是超过4GiB传输证明。Android TLS、连接/响应头阻塞停止、force/close故障、目录fsync/重启恢复及设备矩阵尚未验证；后续服务集成须独立验证。

### 7. Wrong vs Correct

错误：`stop.request(PAUSE); emitPaused()`，或以facts/part存在推断可恢复、已发布。

正确：请求停止 → 等待worker真实退出/关闭 → 按串行用户意图协调终态 → 提交持久执行回执 → 交付；取消另需归属清理，发布另走FileStorage协议。
