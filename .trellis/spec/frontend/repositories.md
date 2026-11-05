# 下载、缓存与设置仓库契约

## 1. Scope / Trigger

三个生产 Repository 已有局部独立 PASS，协调 [AppStore v2](persistence.md)、[引擎](plugin-engine.md)及[文件发布](file-storage.md)。[源设计](../../../.agents/specs/download-manager/design.md)仍有未交付部分，PRD 不勾选、不归档。

## 2. Signatures

以下按所属类列出，使用领域 DTO，失败为 RepositoryException.failure（DownloadFailure）。

```dart
// DownloadRepository
static Future<DownloadRepository> initialize({required AppStore store,
  required DownloadEngine engine, required FileStorage storage,
  required String stagingDirectory});
Stream<List<DownloadTask>> watchTasks();
Future<DownloadTask> create(CreateDownload input);
Future<void> pause(String taskId);
Future<void> resume(String taskId, {bool restartFromZero = false});
Future<void> cancel(String taskId);
Future<void> deleteCompleted(String taskId, {required bool deleteFile});
Future<DownloadTask> redownload(String taskId, String requestId);
Future<void> open(String taskId);
Future<void> synchronize();
Future<void> retryPublication(String taskId);
Future<void> close();
// SavedDownloadRepository
SavedDownloadRepository({required AppStore store, required DownloadRepository downloads});
Stream<List<SavedDownload>> watchSavedDownloads();
Future<SavedDownload> save(SavedDownloadInput input);
Future<void> delete(String savedDownloadId);
Future<DownloadTask> start(String savedDownloadId, String requestId);
Future<void> close();
// SettingsRepository
SettingsRepository({required AppStore store, required DirectoryLocation defaultDirectory});
AppSettings get current;
Stream<AppSettings> watchSettings();
Future<void> setTheme(AppTheme theme);
Future<void> setDefaultDirectory(DirectoryLocation directory);
Future<void> close();
```

## 3. Contracts

- 初始化先监听缓冲再 synchronize/inspect；watchTasks 返回不可变快照，分类/数量派生。初始化失败抛错，不伪造空列表；仓库由应用持有，页面只退订。
- 普通操作按 taskId 排队，创建按 `create:<requestId>`，事件/inspect 使用 `_serial`，长发布按 `publish:<taskId>`，取消后续工作按 `cancel:<taskId>`；其他任务不被长 IO 阻塞。
- create 先读取有效默认目录，再同事务保存任务、固定执行键/命令及规范化原输入后 enqueue。相同 requestId 比较原输入，NULL 目录与显式相同目录不同；默认值改变不影响原请求幂等。去重仅覆盖现存任务生命周期，历史 NULL 输入拒绝猜测。
- cancel 首次等待前同步持久 cancelling/原完整命令，再等待该任务已开始的发布退出。已发布则保留最终文件、操作及取消意图，报 cleanupFailure/alreadyPublished，不猜删、不自动释放私有源。completed 已提交后普通 cancel 拒绝，删除需显式选择。
- 固定 commandId/key/session/expectedReceiptVersion；cleanupFailure、未知结果保留原命令供重放。仅接受前明确 stateConflict/staleSession 或 staleReceipt 拒绝可清 pending、保留 cancelling；同步后下一次用户显式取消才新建命令，不在本次自动重试或改绑旧命令。
- commitReceipt 同事务提交业务状态、完整回执和完整 ack，COMMIT 后更新快照及通知，避免同步订阅者重入取消被旧完成覆盖。真实已停但保存失败仍可通过流反映，操作报告 persistenceFailure，不能以普通 saveTask 绕过事务。
- ack 失败保留已提交授权。deleteCompleted 先重放已提交完整 ack 并等待成功，再 deleting/可选文件删除/删行；失败保持 completed 授权。确认行不级联删除，同版本非空 ack 不得改为空。
- 启动零自动传输：Android/桌面旧活动项 waitingRecovery；iOS 只关联既有系统任务。仅 inspect、确认重放及 recoverPublication 只读核对，不自动 enqueue/resume/publish/cleanup；retryPublication 是显式本地重试，uncertain 不再建目标。
- 缓存 save/delete 不下载、不级联，start 复制配置调用 create，空目录取发起时最新默认值。设置仅无记录时保存 system 主题/defaultDirectory；setDefaultDirectory 校验平台一致后持久化，保存失败保留旧值，历史任务目录不迁移。仓库不探测授权/可写性，也不持有 FileStorage；UI Controller 已通过注入的 FileStorage.pickDirectory 选择目录，null 保留旧值，选择或设置成功不等于全部持久授权组合已验收。
- app 将具体三个 Repository 与 FileStorage 组成 presentation record 注入，feature 不依赖 app。tasksProvider/savedProvider/settingsProvider 各订阅对应业务流，分类/数量由流派生；Notifier 只存 busy/error，不直接访问SQL/引擎。独立 cancel busy 和 mounted 生命周期见[UI 契约](ui.md)。

## 4. Validation & Error Matrix

| 条件 | 当前行为 |
| --- | --- |
| 原输入不同 / 历史 NULL 输入 | stateConflict/createInputConflict 或 createInputUnknown，零新提交 |
| 默认目录缺失 / 目录平台不同 | directoryUnavailable / invalidInput |
| 无安全恢复材料 / 确认从零 | stateConflict/restartRequired 或 restartUnsupported，不模拟 cancel+enqueue |
| 已发布后取消 / 发布不明 | cleanupFailure/alreadyPublished / publicationUncertain，保留事实 |
| 业务提交/ack 失败 | persistenceFailure，保留重试依据，不重发网络 |
| 未知任务 / 非法状态 | notFound / stateConflict，不导入孤立回执 |

## 5. Good/Base/Bad Cases

- Good：空目录请求创建后默认值改变，原 requestId 仍返回原任务；改为显式目录则拒绝。
- Base：保存缓存不联网；start 固化当时设置，之后变更不改历史任务。
- Bad：长发布中取消、提交后同步订阅者重入、删除前 ack 失败；保留优先意图、真实文件及完整确认授权。

## 6. Tests Required

独立交付证据 `/tmp/repository-check-{analyze,tests,smoke}-delivery.log` 及对应 `.exit` 均退出 0：141 项（36 仓库新增＋105 既有），analyze clean；1 项[真实 macOS 集成](../../../integration_test/download_repository_test.dart)，完成项及未完成项各一次 GET，总 GET=2，重开零新增 GET/发布。本轮不重跑产品测试。

保留断言：fresh/migrate 四表同构、迁移失败/未知版本留库、原输入重开与普通保存保留；取消/发布/ack 屏障及跨任务操作；COMMIT 后通知；删除前完整 ack 重放；触发器失败原子回滚、uncertain 零重复目标。

限制：从零重下仍 restartUnsupported；响应 Content-Disposition 命名、最终 URL 回传尚缺，当前显示名取用户名称/原 URL/回退名。Riverpod/Provider/Controller/业务 UI 已局部独立 PASS，最新155项及真实macOS创建/暂停证据见[UI 契约](ui.md)；速度/ETA仍未知。Apple/SAF现存目标删除、Apple用户目录临时副本回收、Windows退出、macOS系统close/Quit实际操作、Windows/iOS及最低版本仍未验收。

## 7. Wrong vs Correct

错误：全局长队列阻塞取消；publish 返回即删源；删业务行后才补 ack；启动自动发布/续传。

正确：

```text
cancel 同步提交意图 → 等该任务发布退出 → 保留已发布事实或清理后原 cancel 重放
业务状态 + 完整回执 + 完整 ack 同事务 → COMMIT → 通知 → acknowledge
删除：完整 ack 重放成功 → deleting/可选文件删除 → 删除业务行
启动：先监听 → inspect/去重 → 已提交确认重放/只读发布核对 → 等用户操作
```
