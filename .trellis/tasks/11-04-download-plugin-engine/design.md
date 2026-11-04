# 插件执行适配设计

## 前置

依赖 [contracts-store](../archive/2026-11/11-04-download-contracts-store/prd.md) 的模型/接口和事务边界；不依赖 Android 引擎或 UI。源协议均见[设计](../../../.agents/specs/download-manager/design.md)，禁止另造任务事实来源。

## 固定来源与补丁

将 background_downloader 9.5.9 放 third_party/background_downloader，保留作者许可证及来源记录；归档 SHA-256 为 ae55e127f87397b372578fc9474568b879fa78326103c342e00160558d08e527，实施时重新核对。显式 path 依赖，记录补丁源码提交，不使用 main 代替。

修改范围限定为 BDPlugin.swift 的原生持久 read/ack、base_downloader.dart 的材料与终态处理、iOS TaskFunctions.swift/桌面 isolate 的累计字节，以及桌面 download_isolate.dart 的实际响应写前校验。只是概念范围，实施先搜索调用方与全部清理路径，再确定必要文件；不能仅修一个入口而保留旁路删除。

## 持久与事件

原生/桌面先提交回执和引用再交付。read 不删，业务提交后显式 ack；旧 ack 不清新材料，默认不释放 paused/failed 引用。状态缓存可以复用，但不能代替持久交付。未知总长事件带累计字节和单调样本，恢复偏移校准后再计数。

## 续传与平台

桌面 GET 的 206/Range/验证器和本地材料全部验证后才追加；否则 restartRequired，不删除或覆盖原部分文件。仅 HEAD 预检不足。iOS 使用系统后台 URLSession 与私有 resume data，先用实体设备证明安全边界；如果系统不可拦截的降级违反需求，不假造成功。

启动注册监听并使用设计中的关闭重调度/自动重试/自动清库参数，但不能把参数当作补丁。iOS 重建相同会话仅关联系统任务；桌面属于进程，无守护任务。

## 回滚

补丁与应用 PluginEngine 分开审查，记录每一处上游差异及测试；失败不自动升级依赖或改 SDK。用户目录发布留给 file-storage，本任务只保护私有持久暂存和执行引用。

## 2026-11-04 桌面日志互斥与未提交尾部恢复修订

- 桌面每执行目录新增私有 `writer.sqlite`，使用现有精确 sqlite3 3.5.2；每次写入独立连接以 busy_timeout=30000、BEGIN IMMEDIATE 串行保护 latest读取、合并、连续版本分配、flush与rename发布。不得用同进程POSIX文件锁或单isolate队列替代。OS释放崩溃连接锁；失败pending唯一保留，已存在版本不覆盖。回执回收通过同一门串行，保留最新快照。iOS仍由Swift NSRecursiveLock与recordExecution原生入口拥有写入，不修改Swift；Dart不在原生锁外回收iOS历史。
- 材料可能比已认证 checkpoint 长；requiredStartByte 与 materialHash 只认证该prefix，不把实际tail长度冒充检查点。GET仍从认证偏移请求，强验证器与完整Content-Range/总长校验不变。再次验证prefix后，只有安全206才登记并流式复制prefix到新私有材料，在新文件追加；原始tail保持不变。不安全响应/坏prefix不创建恢复材料或改原件。
- 每次恢复尝试先持久 `recoveryOperation={id,source,candidate,offset,phase:copying}` 与 `ownedMaterials` 私有路径集合，再排他创建candidate；完成并验证后登记phase=ready和新的resumeData。复制中断不把candidate认作可续传材料；下次尝试分配新candidate，旧项仍可从ownedMaterials定位。复制失败不会进入传输finally，更不能重新认证原件tail。
- 当前取消/发布明确释放本执行resumeRef时，同时处理其持久登记的ownedMaterials集合；先校验整个集合规范化路径、真实父目录、symlink与私有归属，再删除，普通暂停/失败确认不释放。共享AppStore/schema/领域DTO/DownloadEngine不变。此为内部执行材料协议，不扩展用户目录发布。
- 该轮尚存的每秒全文件 hash 成本 P2 已在下节修复并独立复核；iOS 系统私有续传、真机生命周期/材料释放、Windows 与最低系统版本仍未验收。

## 桌面检查点摘要成本修复（P2，已实施并通过局部独立复核）

先前每秒及暂停结束重读全部 partial，导致累计 O(n²) 扫描和随文件增长的暂停等待，现已替换为下述有界摘要。本轮只修改桌面私有材料摘要及必要测试，不修改共享 DTO/AppStore/schema、Swift、SDK、系统基线或用户目录发布。

- 使用已安装 crypto 的公开 SHA-256 API；在传输写入流上维护固定 1MiB 分块的摘要链及最多一块的尾部，checkpoint 只对有界尾部求摘要，禁止每次重读历史文件。摘要需域分离并包含总长度；内部 materialHash 增加明确版本前缀，不能把链式摘要当成普通文件 SHA-256。不得依赖 crypto 私有类或添加依赖。
- 首次下载建立增量状态；重启/继续时对已认证 prefix 做一次或常数次线性读取校验并重建状态，不能直接相信持久摘要来跳过磁盘内容校验。旧普通 SHA-256 材料继续验证，未知摘要版本拒绝；AppStore 的 resumeRef 仍是不透明引用。
- 先成功 flush，再把完全匹配实际文件长度的 offset/摘要一起提交。flush/close/长度不符时保留上一认证检查点及可定位材料，不把尚未成功写入的字节或原件 tail 认证进去。暂停/失败不再以最终全文件扫描掩盖错误。
- 保留安全 GET、强 ETag、完整 Range/总长、prefix fork 意图/归属/原件不变和受控释放。pause/cancel 必须等待实际停止及持久化，不能为性能提前返回。
- 验证：新旧格式恢复、分块边界与任意网络切片、重复读取摘要不消耗状态、prefix 损坏和未提交 tail、flush 失败、copy 中断/重试；重新运行 22 项 HTTP、400 写竞争和必要 macOS 集成。增加真实 >4GiB 流式场景并记录传输/检查点/暂停耗时与有界内存方法，区分合成摘要自检和真实 HTTP/文件执行。未执行的大文件或平台证据继续列未验证，不用小文件成绩冒充。

### P2 实际内部格式与失败边界（2026-11-04）

新 `desktop/material_digest.dart` 使用公开 crypto SHA256：块大小固定1048576字节；`C0=SHA256(UTF8("bd-material-v1:seed"))`，完整块递推 `Ci=SHA256(UTF8("bd-material-v1:block") || C(i-1) || block)`；快照为 `bd-chain-sha256-v1:` 加 `SHA256(UTF8("bd-material-v1:end") || Ci || uint64BE(totalLength) || remainingTail)` 小写十六进制。域分离、固定块与总长度共同区分边界；仅保留32字节链及一块Uint8List，snapshot不消耗运行状态，不依赖网络chunk边界。既有无前缀64位小写hex按普通SHA256校验，恢复同一磁盘读取同时重建新状态；未知版本拒绝。resumeRef仍为不透明引用，没有公共DTO/依赖变更。

新下载在output.add成功后维护摘要；周期checkpoint先flush并核对实际文件length、已接收计数与摘要length完全一致，再把offset/hash同回执提交，不打开或读取历史文件。停止先等待close成功，再以运行摘要及精确stat提交，无全文件扫描。flush/close/长度失败传播失败，保留上次已认证checkpoint和材料引用；失败checkpoint禁止finally重新提升offset。EOF与完成拷贝前flush失败同样禁止认证。首次恢复仍从磁盘验证prefix，安全响应后重建运行摘要；fork的意图、原tail、copy失败隔离和owned集合全部保留。非适配器上游任务没有journal时只重建其既有prefix，不改变其原上游边界。

真实>4GiB测试位于vendor/test/large_download_checkpoint_test.dart，必须显式运行，不进入应用基础48项默认套件。该测试HTTP流式写入后在大文件阶段暂停，逐64KiB内容核验并独立从磁盘重建摘要；生产checkpoint计时不包含历史读取。原始日志与最终指标以implement.md为准。此局部性能证据不代表复制中途OS强杀、断电或iOS/Windows/最低目标验收。
