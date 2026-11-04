# 插件执行与桌面恢复契约

## 1. Scope / Trigger

适用于 [PluginEngine](../../../lib/features/downloads/data/plugin_engine.dart) 与 [固定插件补丁](../../../third_party/background_downloader/PATCHES.md)。适配器、桌面并发日志、prefix 恢复及有界检查点摘要已实现并独立复核；整个子任务仍为 BLOCK/in_progress。iOS 私有恢复、材料释放和真机生命周期，Windows 实机、macOS 10.15/iOS 14 最低目标尚未验收。

共享模型、AppStore v1 和 AndroidEngine 协议不变；业务表仍由 Repository 写入，原生/插件只拥有执行日志。源方案见 [设计](../../../.agents/specs/download-manager/design.md)。

## 2. Signatures

```dart
static Future<PluginEngine> open({
  required AppStore store,
  Directory? journalDirectory,
});
Stream<EngineEvent> get events;
Future<EngineSnapshot> inspect();
Future<void> enqueue(EngineCommand command, EngineTask input);
Future<EngineReceipt> pause(EngineCommand command);
Future<void> resume(EngineCommand command);
Future<EngineReceipt> cancel(EngineCommand command);
Future<void> acknowledge(ReceiptAck ack);
Future<void> close();
```

`PluginEngineException.failure` 为现有 DownloadFailure。执行日志默认在 application-support 下 `plugin_engine_v1`；journalDirectory 是内部/测试入口，不是用户保存目录。open 拒绝 Android/Linux。close 只用于应用生命周期，页面销毁不得调用。

## 3. Contracts

- 固定 background_downloader 9.5.9 归档，SHA-256 为 `ae55e127f87397b372578fc9474568b879fa78326103c342e00160558d08e527`。保留许可证、PATCHES.md 和可对新归档重放的 downloader.patch，显式 path 依赖；sqlite3 保持精确 3.5.2，不升级 SDK、不加 overrides。
- open 先注册回调，start 关闭 doTrackTasks、doRescheduleKilledTasks、markDownloadedComplete、autoCleanDatabase，任务 retries=0；参数不能代替原生补丁。桌面重开只登记 detached/waitingRecovery，不自动 enqueue；历史字节不是新进程的单调时钟样本。
- `commands.sqlite` 为独立 v1 执行库：executions(id,input,plugin_task)、commands(id,payload,result)、acknowledgements(id,payload)，synchronous=FULL。执行身份和 result=NULL 的未知命令结果同事务登记；结果不明先 inspect，不自动重试副作用。同 commandId/载荷重放原结果，不同载荷拒绝。
- 每执行目录保存完整、不可变的递增 `<receiptVersion>.json`；flush 唯一 pending 后 rename 发布，再通知 Dart。桌面每次写入独立 sqlite3 连接，在 writer.sqlite 上设置 busy_timeout=30000，并以 BEGIN IMMEDIATE 串行保护 latest→merge→版本分配→flush→rename；回收使用同一门。不能用 POSIX 同进程文件锁或 isolate 内队列替代。
- JSON 是已发布版本依据；发布后 COMMIT 失败也不能重用该版本，失败 pending 保留。回滚尽力执行并保留首个异常。不宣称 SQLite 与文件发布为同一文件系统事务，也不保证跨文件集合的事务快照。
- iOS Dart 检查点进入原生 recordExecution，与 Swift 回调共用 NSRecursiveLock；legacy 读取非破坏。Dart 不绕过原生锁回收 iOS 历史，保守保留不能视为完整材料释放验收。
- inspect 非破坏，空集合也返回 ownerSessionId/sequence；集合保留最新快照及待确认历史。事件只发布当前进程新版本；初始读取/解析错误不伪造成空列表。
- acknowledge 必须与注入 AppStore 已提交的完整 ReceiptAck 一致；现存同版本业务回执也核对完整载荷。普通 paused/failed 不释放。仅当前 cancelling/publishing 的明确 resumeRef 可释放该执行登记材料；旧确认不得清较新材料。
- 材料集合包含 resumeData.data 与 ownedMaterials；先校验整个集合的规范化路径、真实父目录、symlink 和私有归属，再删除任意成员。IO 删除失败传播异常、不推进执行确认水位，集合保留供幂等重试；不宣称多个文件删除原子。
- requiredStartByte 与 materialHash 只认证持久 prefix；允许额外未提交 tail，不能据实际文件长度提升检查点或截断原件。实际 GET 需强 ETag、206、完整 Content-Range/长度与已知总长一致，HTTP 200/416、坏响应或坏 prefix 返回 restartRequired，确认前不从零请求。
- 原件有 tail 时，安全响应后先持久 recoveryOperation{id,source,candidate,offset,phase:copying} 与 ownedMaterials，再排他创建 candidate、流式复制认证 prefix，复核后登记 ready 和新 resumeData，才向新文件追加。复制失败不进入传输 finally，不认证原 tail；重试分配新 candidate，并保留旧引用。
- 未知总长独立提供真实累计字节，totalBytes 为 null，不从比例反推；恢复/跨进程重置速度窗口。
- 桌面 [MaterialDigest](../../../third_party/background_downloader/lib/src/desktop/material_digest.dart) 使用公开 SHA-256、固定 1MiB 分块链、32 字节链状态及最多 1MiB 尾部；`bd-chain-sha256-v1:` 明确区别于普通文件 SHA-256。seed/block/end 域分离与 uint64BE 总长度构造以任务设计为准，snapshot 不消费状态，不随文件长度累积证明列表。
- 周期与停止检查点不重读历史文件；先 flush/close 成功，再核对实际长度、字节计数和摘要长度，offset/hash 同回执提交。失败保留旧认证检查点及材料，禁止 finally 提升失败检查点。恢复仍线性读取磁盘认证 prefix，并重建运行摘要；旧无前缀 64 位十六进制 SHA-256 可验证，未知格式拒绝。安全 GET、prefix fork、原 tail 和受控释放边界不变。

## 4. Validation & Error Matrix

| 条件 | 当前行为 |
| --- | --- |
| 旧会话/代次/期望版本、commandId 改载荷 | stateConflict；不改绑、不重复副作用 |
| 持久命令结果仍为 NULL | stateConflict / commandOutcomeUnknown；查询而非重提 |
| 业务尚未提交确认、同版本完整回执不同 | stateConflict；不删除材料、不推进确认 |
| 实际响应不安全或本地 prefix 损坏 | restartRequired；原件长度/hash 不变，不从零请求 |
| prefix 复制中断 | 保留 copying/原 checkpoint/原件及全部 candidate 引用；下次分配新 candidate |
| ownedMaterials 任一成员越界或为 symlink | stateConflict / materialOwnership；整个集合均不开始删除 |
| 关闭/flush/日志写入失败 | 异常完成，不虚报 paused/complete，保留原始错误与可定位材料 |
| 文件删除 IO 失败 | 抛错、确认水位不推进，已登记集合可幂等重试 |
| 平台缺实际证据 | 保持未验收，不用编译或 fake 测试替代 |

## 5. Good/Base/Bad Cases

- Good：checkpoint=8192、原件=24576；校验 prefix、安全 206 后复制到新文件并追加，原 tail 长度/hash 不变。
- Base：4 个真实 isolate 各写 100 条，同目录保留 400 个唯一连续版本；空 inspect 仍能取得会话。
- Bad：复制失败、GET 返回 200、完整确认载荷不同或集合最后一项越界，均保留可追踪状态，不删原件或提前确认。

## 6. Tests Required

当前独立复核：基础 48 项、定向 34 项（[摘要](../../../third_party/background_downloader/test/material_digest_test.dart) 5 项含 Python hashlib 独立固定向量、[HTTP 边界](../../../third_party/background_downloader/test/execution_boundary_test.dart) 28 项、[日志并发](../../../third_party/background_downloader/test/execution_journal_race_test.dart) 1 项且 400/400）、[真实 macOS 集成](../../../integration_test/plugin_engine_test.dart) 1 项，以及 flutter analyze 通过。整个插件子任务尚未通过。

- 强验证器/Range/总长/本地损坏、未知长度 EOF 前增长、真实暂停继续、失败 pending、复制故障与重试；copying、旧引用及原件 hash 必须保留。
- 三处交付中断是适配器重建与真实 SQLite 故障注入；确认前未提交拒绝，旧确认/恶意路径/symlink/非法晚成员不误删材料；不能称作三次 OS 强杀。
- [进程脚本](../../../integration_test/plugin_engine_process_check.py) 已在本机实施运行：SIGKILL 后自动请求 0，手动 Range=bytes=8192- 完成 2MiB 逐字节核对，原 65536 字节材料 hash 不变。复核审查了脚本与已保存证据，没有重复该 OS 实验。
- 首个异步复制边界的文件系统故障注入已通过；复制阶段 OS 强杀、全部跨进程锁故障窗口/机器断电未额外执行。
- [真实大文件](../../../third_party/background_downloader/test/large_download_checkpoint_test.dart) 需显式运行：独立复跑 HTTP 实际落盘并逐块核验 4,315,807,744 字节，暂停至持久回执返回 21ms，额外生产检查点 15,028µs；恢复摘要重建仍线性读盘，本次 34.306s。摘要尾缓冲固定 1MiB，进程 peakRSS 442,318,848 字节包含 Flutter/HTTP/测试；不声称整体内存仅 1MiB。暂停计时从测试进程设置停止标志开始，不是 UI/Repository 端到端延迟保证。生产周期/停止不读历史文件另有断言。
- macOS 集成使用临时 host override 12.0，iOS 无签名编译使用临时 15.0；仓库目标仍 macOS 10.15/iOS 14，不能以 host 构建证明最低版本。iOS 安全 resume、生命周期、完成临时文件保护失败/材料释放及 Windows 实机仍是独立门槛；复制阶段 OS 强杀/断电和真实设备磁盘故障未额外实测。

## 7. Wrong vs Correct

错误：独立 isolate 都先读最大版本再写同一路径，或按原文件现长恢复。

```text
previous = latest(directory); write(previous.version + 1);
offset = file.length; truncateOrAppendOriginal(offset);
```

正确：跨 isolate/进程串行分配版本；只信任持久认证 prefix，并保留原件。

```text
BEGIN IMMEDIATE → latest → merge → flush pending → publish new version → COMMIT
verify committed prefix → validate actual 206 → persist copy intent/ownership
→ exclusive candidate → copy/reverify prefix → ready → append to candidate
```
