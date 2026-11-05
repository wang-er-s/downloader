# 文件发布与 completed 源释放契约

## 1. Scope / Trigger

适用于 [FileStorage](../../../lib/shared/platform/file_storage.dart)、[平台工厂](../../../lib/shared/platform/platform_file_storage.dart)、[NativeFileStorage](../../../lib/shared/platform/native_file_storage.dart) 和执行侧 [PublicationJournal](../../../lib/features/downloads/data/publication_journal.dart)。发布与 completed 显式私有源释放已有生产实现及 macOS 局部独立证据；完整 FileStorage PRD 仍 BLOCK/in_progress。Repository、Riverpod、业务 UI 尚未实现。Android 实机由用户负责，不阻塞其他功能。

## 2. Signatures

```dart
FileStorage platformFileStorage({PublicationJournal? journal});
DirectoryLocation defaultDownloadDirectory();
Future<void> cleanupPendingPublication(FileStorage storage, PublishOperation operation);
// FileStorage
Future<DirectoryLocation?> pickDirectory();
Future<FileLocation> publish(PublishOperation operation);
Future<PublishRecovery> recoverPublication(PublishOperation operation);
Future<void> deleteOwned(FileLocation file);
Future<void> open(FileLocation file);
// PublicationJournal：执行侧唯一写入方，AppStore 仅镜像
Future<T> exclusive<T>(Future<T> Function() action);
Map<String, Object?>? read(String operationId);
void save(String operationId, Map<String, Object?> record);
Future<String> authorize(PublishOperation operation);
Future<void> published(PublishOperation operation, FileLocation file);
Map<String, Object?>? findFile(FileLocation file);
```

Apple/Windows 使用 `platformFileStorage(journal: pluginEngine.publicationJournal)`，缺 journal 拒绝；Android 工厂返回 AndroidFileStorage，原生执行侧授权与写日志，通道 `downloader/file_storage`。没有新增共享 DTO/API、依赖或环境变量。

| 执行侧数据库 | 当前结构与迁移 |
| --- | --- |
| `publications.sqlite` v1 | publications(id 主键, execution 唯一, record)，同完整执行键只允许一个 operationId |
| Android `android_publications_v1.db` v1 | 独立原生发布日志，AppStore 不能成为第二个发布写入方 |
| Plugin `commands.sqlite` v2 | 保留 executions/commands/acknowledgements；事务迁移 v1，新增 complete_sources(id,ref,members)、material_releases(id,ack,done) |
| Android `android_execution_v1.db` v8 | 依次保留 v1–v7 历史，新增 completed_sources(engine,generation,ref,members,ack,done) |

未知版本拒绝，迁移失败回滚留库，禁止删库重建；AppStore 仍四表 v1。旧 completed 可通过同发布身份的本地回执重放补登记 opaque 引用、生成新完成版本，不新增 GET/目标。

## 3. Contracts

- 默认目录 DTO：Android/macOS/Windows 为 systemDownloads、displayName=Downloader；iOS 为 appDocuments、displayName=Downloads。原生实际定位为 Android 公共 Download/Downloader、macOS/Windows 系统当前用户 Downloads/Downloader、iOS Documents/Downloads。不硬编码用户路径或静默以 sandbox 替代公共目录。选择取消返回 null，保留旧设置；SAF URI、Apple bookmark/security scope、Windows 路径分别验证。
- 源路径不是授权。Plugin 从当前同执行 publishing 回执和已登记 EngineTask 核对源、完整长度、固定目录、未 detached；Android 从原生日志核验。执行侧 PublicationJournal 唯一持久写入，AppStore 只镜像。prepared/creating 先于外部创建，源与目录固定幂等；创建结果或 identity 未知返回 uncertain，不按唯一名认领、不新建第二项。
- 复制须真实关闭并核对完整字节；finalizing 先保存候选及已知身份，再不覆盖发布，重名递增。recoverPublication 只读核对，返回 notCreated/staged/published/needsPermission/uncertain，不创建/改名/删除或补写回执。已保存最终身份但回执未提交时，显式 publish 重放仅补本地回执。
- Apple 从核验源 fd 向 O_EXCL 新最终 fd 流复制，fsync/close 后返回独立最终 identity；publishAttempt、temporaryIdentity、keepTemporary 为内部记录。最终创建回复丢失或最终 identity 未持久则 uncertain。Apple/SAF 现存目标 cleanup/delete 安全拒绝，Apple 发布后用户目录临时副本保留，均为功能缺口；不能用检查后路径 unlink/quarantine rename 掩盖竞态。
- Windows 用核验源 HANDLE 执行 FileRenameInfo、ReplaceIfExists=false，关联核验父目录 HANDLE；窗口拥有串行 worker，平台线程交付结果，析构停接并 join 后释放 messenger。只有源码审查，没有 Windows 构建/运行证据。Android MediaStore 使用本应用保存的 pending 行 URI；SAF 仅支持系统 com.android.externalstorage.documents/com.android.externalstorage 提供方，直接创建最终候选并保存 URI/fd identity 后复制，避免 renameDocument 换 URI/覆盖语义。未知身份 uncertain，其他提供方创建前 directoryUnsupported；本轮 MediaStore/SAF 只编译，未运行提供方。
- 取消：持久 cancelling → 原 EngineCommand.cancel 真实停止/关闭并保存回执 → 未清理发布项触发 cleanupFailure → cleanupPendingPublication → 成功后重放完全相同原 cancel。cleaning 先于删除，证明未创建/已清理才记 cleaned；删除后日志失败重开只核对补存。uncertain、失权、published 拒绝自动清理，保留源/操作/任务。完成文件删除另走显式 deleteOwned。
- completed 回执通过 resumeRef 暴露 `complete:` opaque 稳定引用；resumeSupport=unsupported 也可承载释放引用，绝不表示可续传。引用仅索引引擎登记集合，不解释调用方路径。Plugin 集合为完整源和历史 ownedMaterials/桌面 resumeData，Android 为登记 payload/facts 配对集合。用户最终文件/用户目录临时副本不在私有集合。iOS URLSession opaque resume blob 不解析为路径，不声称回收系统临时下载文件。
- Repository 必须以同一 AppStore 事务 commitReceipt 保存业务 completed、完整 EngineReceipt、最终 FileLocation、published PublishOperation 与完整 ReceiptAck（显式 releaseResumeRefs），提交后再 acknowledge。两 Dart 桥读完整已提交 ack 并核对业务完成/完整发布身份/回执；引擎另验当前完整 key/版本、登记引用、无较新分支/活动 worker。普通空 ack、旧/伪造 ack、单纯 publish 返回不删完整源；同版本 ack 不可事后换释放载荷。
- Plugin 删除前整集合仅接受归属匹配的普通文件或已登记缺失成员，拒绝 symlink、目录、FIFO，晚成员非法也必须零删除。等待 worker idle/平台目录查询后、每个未完成成员删除前及最终 ack 前，重读完整已提交 ack、业务 completed/发布身份及当前完整执行回执；业务转 cancelling 即停止。持久 intent → 每成员 delete/done → 最终确认；intent/delete/done/ack 任一失败均保留可重开重放的事实，缺失成员幂等，不承诺多文件原子删除。
- 执行门 `execution.gate.sqlite` → 发布门 `publications.sqlite.gate.sqlite`：独立 SQLite 连接 BEGIN IMMEDIATE、busy_timeout=0，BUSY/LOCKED（5/6）异步延迟10ms重试，覆盖长异步 IO；禁止同门重入（调用约束，无自动检测）。ROLLBACK/close 用嵌套 finally。日志短事务与 gate 分开；不要混淆 vendor 回执 writer.sqlite 原有 busy_timeout=30000 的版本分配锁。

## 4. Validation & Error Matrix

| 条件 | 行为 |
| --- | --- |
| 源/目录/执行键/同 operation 载荷不符 | stateConflict，拒绝副作用 |
| 未知日志版本 / 日志写失败 | protocolMismatch / persistenceFailure，留库与已提交阶段 |
| 失权 / 能力不足 | needsPermission 或 permissionDenied / directoryUnsupported，保留目录与源 |
| 创建或最终身份未知 | uncertain / publicationUncertain，不认领、不重建、不猜删 |
| cleanup 不明、published 或 Apple/SAF 现存项 | cleanupFailure，保留意图与文件，不移除任务 |
| ack 未提交、旧引用、非普通/越界成员、异步授权变化 | stateConflict，拒绝继续释放；集合预验失败零删除 |
| delete/done/最终 ack 保存失败 | 不推进最终确认，重开重放原完整 ack |

诊断落库失败不掩盖首异常；初始化/读取/锁及全部底层异常的结构化映射仍未完整验收。

## 5. Good/Base/Bad Cases

- Good：真实 HTTP→发布→AppStore 同事务 completed/显式 ack→私有集合释放，重开幂等，最终用户文件字节不变，GET=1。
- Base：普通 ack 保源，登记 missing 幂等，无发布的原 cancel 兼容，缺失目标核对后补 cleaned。
- Bad：晚成员变目录、等待期间业务 cancelling、最终创建回复丢失、done/最终 ack 保存失败；零误删、未知不再建、失败重开续处理。

## 6. Tests Required

最新 completed-release 独立检查：57 focused（55桥＋2真实 SQLite 锁）、macOS 5引擎＋9文件真实集成、flutter analyze 干净；Android JVM 独立 --rerun-tasks，6份 XML 共93项，失败/错误/跳过0。本轮规范同步不重跑产品测试。

- 断言：同名不覆盖、创建/最终未知 uncertain、已知最终身份回执补存、原 cancel 重放、外来替换/symlink、安全拒删；completed 同事务 ack、旧/伪造/未提交 ack 保源，晚目录/等待 cancelling 零删除，delete后 done 失败与最终 ack INSERT 失败重开，GET=1。
- 真实双 isolate 与同 isolate 异步等待者均等 owner 异步 IO 完成；owner 抛错后可再取锁。未新增跨进程强杀锁主实验。
- Plugin v1→v2、迁移失败/未知版本留库已回归；Android v7→v8 与释放故障22项 instrumentation 本轮仅编译，设备执行0。旧 API37 v7 的20 SQLite＋7 Runtime 历史通过不是 v8 通过。
- macOS 临时 host12 不证明10.15；iOS 前轮 host15 无签名编译不证明14；Windows 缺环境。Android 提供方/实机由用户验证。持久授权撤销、外部提供方、空间不足、锁定、系统打开/APK、Apple/SAF 正常删除、Repository 接线仍待完成，PRD 不勾选、不归档。

## 7. Wrong vs Correct

错误：publish 返回就删 sourceRef；把非空 resumeRef 当续传能力；空 ack 顺带删源；持有执行门再重入该门；把旧 v7 设备结果称作 v8 验收。

正确：

```text
执行源授权 → 创建前意图 → 排他创建/身份核验 → 复制关闭 → 不覆盖发布
→ published 回执 → AppStore 同事务 completed/最终位置/发布操作/显式 ack
→ acknowledge → 整集合预验与异步授权重核 → intent → delete/done → ack
未知身份 → uncertain 保源；取消 → cleanup 成功 → 原 cancel 重放
```
