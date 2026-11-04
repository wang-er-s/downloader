# Flutter 架构与跨层契约

## 设计决策：Feature-first + MVVM + Repository/Service + Riverpod

下载管理器页面数量有限，但下载生命周期、任务恢复和文件访问必须独立于页面。采用按功能组织目录、MVVM 式职责划分及 Repository/Service 分层；Riverpod 管理界面状态与依赖，复杂业务按需提取 UseCase。

该分层决策已确认；领域/执行 DTO、DownloadEngine 与 FileStorage 接口及 AppStore v1 已实现，现有 API 与验证范围见[持久化契约](persistence.md)。下文 Controller/Repository、具体引擎和文件操作仍是后续契约；变更时同步调用方和测试。当前主机 SQLite 测试不代表插件补丁、原生后台或四平台兼容性验证通过。

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

- 引擎：9.5.9 原版存在已知契约缺口，iOS/桌面必须先完成固定版本的有限补丁；原生非破坏读取/确认、失败材料保留、未知总长字节和桌面安全恢复均须故障注入，不能只加 Dart 包装。
- 平台：最低版本、生命周期、默认目录、持久授权、系统打开和 iOS resume data 的系统行为仍待验证；Android/桌面不得自动恢复，iOS 不重复提交。
- 存储：AppStore v1、确认行及发布意图镜像已落库，真实 SQLite 测试通过；引擎日志、材料释放和平台发布恢复仍待验证。提供方不支持安全恢复时报明确能力错误，不能假定所有 URI/文件身份稳定。
- 依赖与发布：sqlite3 3.5.2、path_provider 2.1.6 已解析并锁定；Riverpod、补丁插件与其余依赖仍待接入，四平台 release 尚未构建。业务功能铺开前须通过设计所列最小验证门槛。
