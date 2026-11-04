# 领域与 AppStore 持久化契约

## 1. Scope / Trigger

适用于下载领域/引擎 DTO、共享 SQLite v1，以及后续 Repository 对状态与确认的原子对齐。当前已实现契约与存储，尚未实现真实下载、Repository 调度或文件发布。源业务方案见[设计文档](../../../.agents/specs/download-manager/design.md)。

实现入口为 [AppStore](../../../lib/shared/data/app_store.dart)、[schema](../../../lib/shared/data/app_store_schema.dart) 和 [领域模型](../../../lib/features/downloads/domain/download_models.dart)。domain 仅依赖 Dart；Flutter、SQLite、插件类型不得泄漏进入领域。

依赖精确锁定 sqlite3 3.5.2、path_provider 2.1.6。原候选 sqlite3 3.8.0 实际解析因 hooks → record_use 要求 meta ^1.19.0，与 Flutter 3.44.8 固定 meta 1.18.0 冲突；不升级 SDK、不使用 dependency_overrides。Flutter 自动生成的 Windows jni FFI 登记与 lockfile 一并保留，不手改生成文件；这不证明 Windows 已构建。

## 2. Signatures

以下为现有 API；Repository 对 Engine 的确认调用仍属于后续接入。

```dart
AppStore(Database database);
static Future<AppStore> openPersistent({Future<String> Function()? databasePath});
T transaction<T>(T Function(StoreTransaction store) action);
List<DownloadTask> readTasks();
DownloadTask? readTask(String id);
List<SavedDownload> readSavedDownloads();
AppSettings? readSettings();
List<ReceiptAck> readAcknowledgements();
void close();
```

事务回调内的 `StoreTransaction` 提供：

```dart
void saveTask(DownloadTask task);
void deleteTask(String id);
bool commitReceipt(DownloadTask task, ReceiptAck ack);
ReceiptAck? readAcknowledgement(ExecutionKey key);
void saveAcknowledgement(ReceiptAck ack);
void saveSavedDownload(SavedDownload saved);
void deleteSavedDownload(String id);
void saveSettings(AppSettings settings);
```

事务内另有同名类型化读取入口。`AppStore.openPersistent` 默认通过 application-support 定位 `downloader.db`；`databasePath` 仅是可测试入口，不是公共下载目录配置。不新增环境变量或网络 API。

数据库固定四表：download_tasks、saved_downloads、app_settings、engine_receipt_acks；列与约束以 schema 和源设计为准。request_id、engine_id 唯一；确认主键为 `(engine_id,generation)`，没有任务外键。不要增加配置到任务的级联关系。

## 3. Contracts

- 所有模型与嵌套集合防御复制且不可变。URL 仅接受无用户名/密码的 HTTP/HTTPS，名称拒绝穿越、分隔符、控制符和目标平台非法名称。
- 目录/FileLocation 的 JSON 使用 `version=1`，内部执行 DTO 使用 `protocolVersion=1`，嵌套 ExecutionKey 使用 `version=1`；未知版本、枚举及字段类型不默默转换成默认值。Android 扁平载荷映射在适配器实现，不直接转发内部持久 JSON。
- DownloadPlatform 为 android/ios/macos/windows；FileKind 为 path/contentUri/bookmark，ResumeSupport 为 unknown/supported/unsupported。DTO 只校验形态与平台组合，不授予目录访问权或文件归属证明。
- 字节为非负有符号 64 位整数，未知 totalBytes 为 null；不以 -1、0 或比例反推未知大小。时间落库为 UTC 毫秒，读取为 UTC DateTime。
- `target_ref` 为 SQL NULL 或 `{version:1,targetRef:String?,fileLocation:FileLocation?}` JSON 信封。不能丢弃 FileLocation 的 platform/kind/identity，也不能把任意不透明引用猜成 JSON；非空不代表发布成功。
- pending_command_json、publish_operation_json、engine_receipt_json 保留完整身份和版本。PublishPhase 为 prepared/creating/copying/finalizing/published；发布能力及文件操作仍由后续适配器实现。
- AppStore 单连接、同步短事务。不得嵌套、返回 Future、在回调里 await 网络/平台调用或复制文件；事务句柄在回调结束后失效。状态与确认必须在同一事务提交，确认引擎只能发生在提交之后。
- `commitReceipt(task,ack)` 要求 task、回执、ack 执行键及版本匹配。当前任务不存在返回 false，不导入或复活任务；当前执行键不同返回 stateConflict。旧版本不写入；相同版本完整回执及确认载荷一致才幂等，改变 downloadedBytes/resumeRef/error 等也必须拒绝。
- `saveTask` 固定原 requestId、engineId、originalUrl、requestedFileName、目录和创建时间，禁止降低代次或回执版本。保留确认行限制其他 taskId 重用 engineId 或写回旧代次。不要以旧回调重绑当前身份。
- `saveAcknowledgement` 核对现存 engine 所属 taskId 及代次；保留旧代次确认重放能力，拒绝其他所有者或超前代次。同版本不同确认拒绝，较低版本不得替换更高版本及其 releaseResumeRefs。
- 取消/删除事务先保存最后确认再删除任务；确认行不级联删除。普通暂停/失败确认的 releaseResumeRefs 为空，实际材料归属和释放由引擎再校验；存储不会删除文件或自行判断可回收材料。
- `commitReceipt` 返回 false 时不能据此确认传入的新载荷：查询已提交确认并按该行重放。AppStore 不执行取消优先、发布恢复、启动协调等 Repository 状态机。
- user_version=0 原子初建，version=1 验证必要表/列，未知版本拒绝且保留库。尚无已发版旧结构，不能宣称已验证历史迁移；以后逐版本迁移，绝不删库重建。回滚尽力执行，回滚失败不得掩盖最初异常。

## 4. Validation & Error Matrix

| 条件 | 当前边界行为 |
| --- | --- |
| 非法用户 URL/名称或负数/越界计数 | DownloadFailure，code=invalidInput；不持久写入 |
| JSON 版本、枚举或字段类型无效；未知数据库版本 | code=protocolMismatch；不覆盖旧数据、不删库 |
| 身份变更、旧代次/回执、同版本不同载荷、伪造确认 | code=stateConflict；原记录与确认保持 |
| 重复 requestId/engineId、SQL 约束或磁盘写入失败 | 保留原始 SqliteException；事务回滚；后续 Repository 映射 persistenceFailure |
| 无任务的 commitReceipt | false；不创建任务、不自动确认未提交内容 |
| 事务嵌套/关闭后调用/过期句柄 | StateError；异步回调返回值为 ArgumentError |
| 数据解析或原始回调失败 | 保留原始异常供边界映射，不伪造空列表或保存成功 |

## 5. Good/Base/Bad Cases

- Good：先已有任务，新的真实执行回执与确认同事务提交；重开读取相同快照与确认，再按持久确认通知引擎。
- Base：空库首次原子创建；readSettings 为 null 时由后续 Repository 初始化默认设置；完全相同回执重放不重复写入。
- Bad：伪造其他 taskId 首次占确认主键、同版本修改恢复引用、SQL 触发器中途失败、SQLite 已自行回滚、未知 JSON 版本；都不能污染已有记录或用删库掩盖问题。

## 6. Tests Required

现有 [contracts_test](../../../test/features/downloads/contracts_test.dart) 与 [app_store_test](../../../test/shared/data/app_store_test.dart) 覆盖以下断言；独立检查后当前主机 `flutter analyze` 无问题，48 项测试通过（27 契约、20 SQLite、1 保留的计数器测试）。

- 不可变嵌套集合、版本/枚举/输入边界、完整 DTO 往返、未知总长 null。
- 真实 SQLite 内存和临时磁盘库、重开、超过 4GiB 和最大 int64、重复 requestId 与表约束。
- 状态/确认原子回滚、SQL 触发器注入失败、回滚不掩盖原始异常、过期事务句柄拒绝。
- 首次伪造确认不占主键，删除后确认保留且其他所有者不可重用执行；配置删除不影响任务。
- 同版本不同回执通过 saveTask/commitReceipt 两入口均拒绝；旧确认不覆盖新版本或释放列表；未知版本不覆盖旧值。

当前 macOS 主机已真实加载 SQLite 原生资产；path_provider 测试使用注入的目录解析。四平台 release、真实目录通道/授权、原生后台回执、恢复材料释放与文件发布故障注入仍未验证，不能用 DTO/主机单元测试替代。

## 7. Wrong vs Correct

以下为后续 Repository 接入片段，假定 task/ack 已校验、store/engine 已注入。

错误：业务写入与确认分开，进程中断后丢确认重放依据。

```dart
store.transaction((tx) => tx.saveTask(task));
await engine.acknowledge(ack);
```

正确：同事务提交状态与确认；仅在确认该载荷已提交后通知引擎。

```dart
final committed = store.transaction((tx) => tx.commitReceipt(task, ack));
if (committed) {
  await engine.acknowledge(ack);
}
```

返回 false 时读取已持久确认行处理重放，不把传入 ack 当作已保存；确认失败保留确认行，不重新启动传输。取消/删除使用同一事务保存最终确认并删任务，禁止在页面销毁或普通失败确认后释放恢复材料。
