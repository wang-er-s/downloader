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

## 执行侧落地约束（本轮）

FileStorage 不接受调用方路径作为源授权。PluginEngine 从同执行当前 publishing 回执和已登记 EngineTask 解析完整源，核对长度及固定目录；Android 同理由原生日志核验。发布阶段由引擎侧 PublicationJournal 唯一持久写入，业务库只镜像。发布 journal 使用独立、显式版本的执行侧 SQLite，不改变 AppStore 四表；未知版本拒绝，初始化失败保留原文件。

操作按 operationId 及完整执行键幂等，首次请求固化源、父目录身份和名称；跨实例/进程互斥覆盖文件副作用到阶段提交。prepared、creating 先于外部创建；创建返回前中断且无法证明身份时保留 uncertain，不凭唯一文件名认领。copying 保存文件身份，复制成功须实际关闭、核对完整长度。finalizing 先保存候选名和身份，再调用系统不覆盖发布。已发布但回执未写入时，重开按已保存身份只补本地回执，不重建目标、不发网络。recoverPublication 只读取核对，不补写回执。

取消/删除必须经过同一执行串行入口且校验引擎当前状态；取消意图优先于发布完成。完整源在业务完成及显式确认前保留，普通确认不释放。所有原生变更前核验父目录与文件身份；路径和唯一名称仅用于定位，不能单独授权删除。

## 当前实际接入及取消协议（2026-11-05 收尾）

Repository 通过 `platformFileStorage(journal: pluginEngine.publicationJournal)` 组装 Apple/Windows；Android 由同一工厂使用原生执行侧发布日志，无需传入 Dart journal。`defaultDownloadDirectory()` 返回平台默认目录 DTO，实际定位发生在原生发布入口。没有引入新依赖或改动 AppStore 四表。桌面日志为执行侧 `publications.sqlite` v1，Android 为独立 `android_publications_v1.db` v1；同执行只允许一个 operationId。内部 cleaning/cleaned 为清理日志阶段，不扩展共享 PublishPhase。

取消调用顺序：Repository 先持久 cancelling 意图，再调用原 EngineCommand 的 cancel。引擎先真实停止并保存原命令/回执；存在未核实或未清理的发布操作时返回 cleanupFailure，不能移除业务记录或释放完整源。之后调用 `cleanupPendingPublication(storage, operation)`，成功后重放完全相同的原 cancel 命令。PluginEngine 的 cancel 返回门和非空释放 ack 门检查发布日志；Android finishCancel 在 OwnedMaterialCleanup 之前检查发布日志。没有发布操作的取消路径保持兼容。清理先提交 cleaning，只有删除已证明归属目标或证明未创建后才提交 cleaned；删除完成但 cleaned 提交失败，重开只核对和补存。cleaned/cleaning 不允许迟到 publish 再新建。

cleanupPendingPublication 拒绝 uncertain、授权丢失和已 published 文件，保留源与操作；已最终发布但业务取消竞争的目标不能自动删除，等待明确用户处理。完成文件删除仍须显式调用 deleteOwned，不将取消清理当作用户确认删除完成文件。现有真实回归覆盖串行队列次序、外来替换及 symlink，但不证明每个原生 syscall 间的恶意并发替换均安全，见 implement.md 剩余阻断。

Android MediaStore 直接以最终候选名 INSERT 并设置 IS_PENDING，最终步骤仅对已保存且核验过的自身 URI 清除 pending，不执行路径 rename。SAF 仅接受系统 `com.android.externalstorage.documents` / `com.android.externalstorage` 提供方；已核对本机 Android 36.1 SDK 的 FileSystemProvider.createDocument：buildUniqueFile 后 createNewFile，不成功即失败，不覆盖既有文件。它直接创建最终名称、保存返回 URI 与 fd 的 dev/inode，再复制关闭核验，避免 renameDocument 改 URI/覆盖语义。其他提供方在创建前返回 directoryUnsupported。创建结果或 identity 取得失败时，即使保留了 URI 但无 identity，恢复仍为 uncertain，不补建或猜测清理；MediaStore 查询确认已公开且完整的条目只补本地阶段，不再复制。以上 Android 分支已编译，提供方运行与竞态仍待用户实机及后续定向自动化验证。

## 独立审查修正（本节优先于上文旧实现描述）

Apple 不再用路径 linkat 发布：从已核验暂存 fd 流式复制到 O_EXCL 新建的最终 fd，实际 fsync/close 后返回新 inode 身份，最终身份提交后才核验 published。内部发布记录新增 temporaryIdentity、publishAttempt、keepTemporary，不改共享 DTO/数据库版本；外部创建前保存 publishAttempt。最终创建回复丢失或新身份未落日志时返回 uncertain，不按名字认领、不再创建第二项。此方案多一份目标卷暂存占用；默认目录仍可完成真实发布。

Darwin 没有按已核验 inode 条件 unlink 的接口。现存目标的 cleanup/delete 明确返回 cleanupFailure，不执行路径 unlink/quarantine rename，保留源、目标和清理意图；发布成功后也保留登记的用户目录临时副本。此项是实质安全拒绝及功能缺口，不能宣称取消/完成删除已验收。SAF ExternalStorageProvider 的路径型 documentId 同样不能把 deleteDocument 绑定已核验 inode，因此现存 SAF 清理/删除安全拒绝；MediaStore 仍操作本应用持有的稳定行 URI，提供方运行验证待用户实机。

Windows 发布改用验证后的源 HANDLE 执行 FileRenameInfo/ReplaceIfExists=false，目标关联已核验父目录 HANDLE；取消路径和完成删除保留句柄验证及 disposition。通道由窗口持有串行 worker，文件操作离开 UI，结果入回复队列并由窗口消息在平台线程交付；析构停接请求并 join 当前操作，销毁未发送结果后才释放 messenger。选择器和系统打开保持平台 apartment。缺 SDK，以上是源码修复，不是 Windows 构建/运行证明。

同规范化执行根的 PluginEngine 实例共用 Dart 命令队列，当前命令与发布使用独立 SQLite 异步门，顺序固定为执行门→发布门；已替换早期 execution.lock 文件锁实现。真实双 isolate 与同 isolate 异步等待者、双 Engine 发布/cancel 屏障已通过，未新增跨进程强杀锁主实验；禁止同门重入是调用约束。签名与门路径详见[文件契约](../../spec/frontend/file-storage.md)。

completed 源释放已按下一节落地，正式生产契约见[文件契约](../../spec/frontend/file-storage.md)。Repository 仍待接入同事务 completed/完整回执/最终 FileLocation/published PublishOperation/完整 ReceiptAck→显式 acknowledge；Apple 用户目录临时副本与私有完整源分别管理，前者仍受安全拒绝约束。

## completed 显式确认释放落地（本节替代上文待实现描述）

不改共享 DTO、DownloadEngine/FileStorage 或 AppStore 四表。PluginEngine commands.sqlite 升 v2，事务迁移保留 v1 的 executions/commands/acknowledgements；新增 complete_sources（完整源 opaque 引用及历史 ownedMaterials/resumeData 成员集合）与 material_releases（完整 ack、逐成员 done）。Android execution 库升 v8，按 1..7 顺序补表，不删历史，completed_sources 保存原生登记的 payload/facts 配对集合、opaque ref、ack 和逐路径 done；未知版本拒绝，迁移失败回滚留库。原有 completed 记录可在相同发布身份的本地发布回执重放时补登记并生成新完成版本，不发网络。

发布完成回执以 resumeRef 暴露 complete: 不透明稳定引用；调用方不能把路径作为释放授权。Repository 尚未实现，因此本轮集成直接使用真实 AppStore 事务 commitReceipt：completed 快照同时含完整 EngineReceipt、FileLocation、published PublishOperation，以及仅包含该 opaque 引用的 ReceiptAck。只有事务完成后才调用既有 acknowledge。Dart 两桥核对完整已提交 ack；completed 释放额外核对当前执行键/版本、业务完成及完整发布身份。引擎核对当前完成记录、引用登记、无较新代次/活动 worker，然后持久 intent → 每成员 delete/done → 最后确认水位。删除后 done 或最终 ack 保存失败可重放，缺失已登记成员幂等；普通空 ack、旧/伪造 ack、单纯 publish 返回不删完整源。用户最终文件和用户目录临时副本不在私有释放集合中。iOS URLSession opaque resume blob 是审计元数据，不解析为文件路径；本轮不宣称清理系统拥有的临时下载文件。

PluginEngine 执行门与发布文件门改为独立 SQLite 连接持有 BEGIN IMMEDIATE，busy_timeout=0，遇 BUSY/LOCKED 使用异步延迟重试；不阻塞拥有者所在 isolate 的长异步 IO。按执行门→发布门顺序，不允许同一门重入。SQLite 锁覆盖同进程不同 isolate 及进程，关闭/崩溃释放；本轮真实双 isolate 与同 isolate 等待者回归通过，同根双 Engine 发布/cancel 屏障仍通过。未做独立进程杀死锁主的新增实测。

## Apple / SAF 恢复正常删除的最小方案与信任边界

本轮保留安全拒绝；这是待完成的功能，不是最终交付。源码研究基于当前 macOS SDK Foundation/NSFileCoordinator.h（WritingForDeleting、coordinateWritingItemAtURL 及 presenter 协议注释）和 Android 36.1 DocumentsContract.java（deleteDocument、FLAG_SUPPORTS_DELETE 与 ACTION_DOCUMENT_SETTINGS）。

Apple 最小原型应在已激活 bookmark/security scope 后，使用独立 NSFileCoordinator 对待删 URL 执行 .forDeleting 协调写，在 accessor 返回的 URL 内重新核对父目录、资源 identity、普通文件/无 symlink，再调用系统删除，并持久核对缺失结果。协调覆盖遵循 NSFileCoordinator/NSFilePresenter 的正常提供方移动、替换、并发读写，不能宣称阻挡任意不配合的 POSIX 写入或同 UID 恶意逐 syscall 换名。需测试普通外部替换发生在协调前/等待期间时拒绝误认、提供方协调失败/撤权、成功删除和删除后日志失败重放；非协调目录若不能给出可接受边界，使用明确用户确认的系统文件处理能力并在返回后重新核对结果，不自动认领已替换文件。macOS 可研究 NSWorkspace 的系统回收站处理；iOS 没有可通用代替任意文件条件删除的系统确认 API，必须按具体 FileProvider 协调能力验证。

SAF deleteDocument 仅按 URI 发 provider.call(METHOD_DELETE_DOCUMENT)，无 expected inode/identity 参数；FLAG_SUPPORTS_DELETE 只声明能力，不能证明路径 documentId 稳定。ACTION_MANAGE_DOCUMENT 在当前 SDK 是隐藏 @SystemApi，不能当公共解决方案；公开 ACTION_DOCUMENT_SETTINGS 需 provider 声明 FLAG_SUPPORTS_SETTINGS，只是打开提供方文档管理界面，不保证包含删除或可靠删除回调。最小可行路线：针对经过实机验证、提供稳定文档对象身份/并发语义的 provider 建能力允许清单；ExternalStorageProvider 普通外部替换在删除入口重核 identity，若采用其路径删除必须明确采用正常外部编辑而非同 UID 恶意 syscall 替换的信任模型并经用户确认，不能悄悄降低现契约。若提供方有用户管理界面可交用户系统处理，之后只核对原记录已缺失/identity 冲突，不以返回成功直接清记录。任意第三方 SAF 没有通用原子条件 unlink，严格无误删契约下仍保留明确能力失败。没有引入 quarantine、额外用户目录副本或分享兜底。

## 本轮独立检查补强

Plugin completed 释放在任何成员删除前对整集合做普通文件/缺失类型校验；目录、FIFO、symlink 等非普通类型不能等到逐成员删除时才拒绝。等待 worker idle、平台目录查询及逐成员异步删除会让出事件循环，因此在等待后、每个未完成成员删除前与最终确认前重读完整已提交 ack、业务 completed/发布身份及当前完整执行回执；业务转 cancelling 或回执变化即停止，保留持久意图供后续处理。SQLite gate 的关闭使用独立 finally，ROLLBACK 异常也不跳过连接释放。

## 正式规范同步（文档检查点）

工厂/默认目录、发布日志v1、Plugin commands v2/Android execution v8、opaque complete: 经resumeRef（unsupported不代表可续传）、取消重放、整集合预验/异步授权重核与门顺序统一到[文件契约](../../spec/frontend/file-storage.md)；AppStore仍四表v1。最新独立57 focused（55桥＋2锁）、macOS5引擎＋9文件、93 JVM强制重跑及analyze通过；22 Android instrumentation仅编译，旧API37 v7的20SQLite＋7Runtime不是v8通过。完整PRD仍BLOCK/in_progress，Repository/Riverpod/UI未实现；Apple/SAF删除/用户目录临时副本回收、Windows环境、Android用户实机、iOS及最低版本等余项不因规范同步消失。
