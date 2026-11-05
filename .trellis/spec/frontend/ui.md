# 下载 UI 与应用组装契约

## 1. Scope / Trigger

适用于[应用组装](../../../lib/app/dependencies.dart)、[应用入口与退出协调](../../../lib/app/app.dart)、[Provider/Controller](../../../lib/features/downloads/presentation/providers.dart)及三个 feature 的 presentation。业务来源为[仓库契约](repositories.md)，执行/文件边界见[插件契约](plugin-engine.md)和[文件契约](file-storage.md)。中文下载/设置、下载中/已完成/缓存、表单与任务操作已接入，本机局部独立 PASS；整个 UI 任务仍 BLOCK/in_progress，PRD不勾选，不作为四平台或系统退出验收。

## 2. Signatures

以下为实际类成员/类型签名，按所属组件列出，不是同一文件顶层声明。

```dart
// AppDependencies：app拥有，页面不关闭
static Future<AppDependencies> open();
PresentationDependencies get presentation;
Future<void> close();
// presentation/providers.dart：具体能力注入，不新增包装接口
typedef PresentationDependencies = ({
  DownloadRepository downloads,
  SavedDownloadRepository saved,
  SettingsRepository settings,
  FileStorage storage,
});
// DownloadsController extends Notifier<OperationState>
Future<bool> run(String id, Future<Object?> Function() action,
    {bool duringExit = false});
Future<bool> pause(String id);
Future<bool> resume(String id);
Future<bool> cancel(String id);
Future<bool> retryPublication(String id);
Future<bool> open(String id);
Future<bool> redownload(String id);
Future<bool> deleteCompleted(String id, bool file);
Future<bool> clearCompleted(List<String> ids, bool deleteFile);
Future<bool> create(CreateDownload input);
Future<bool> save(SavedDownloadInput input);
Future<bool> startSaved(String id);
Future<bool> deleteSaved(String id);
Future<bool> theme(AppTheme theme);
Future<DirectoryLocation?> pickDirectory();
Future<bool> chooseDefaultDirectory();
Future<bool> synchronize();
void clearError();
void lockExit(bool value);
// _AppShellState
Future<AppExitResponse> requestExit();
```

`dependenciesProvider` 为 `Provider<PresentationDependencies>`；`tasksProvider` 为 `StreamProvider<List<DownloadTask>>`，`savedProvider` 为 `StreamProvider<List<SavedDownload>>`，`settingsProvider` 为 `StreamProvider<AppSettings>`；`downloadsControllerProvider` 为 `NotifierProvider<DownloadsController, OperationState>`。OperationState 仅有 `Set<String> busy` 与 `String? error`。flutter_riverpod实际解析3.4.3，不要求生成代码，无新增环境变量或业务数据库表。

## 3. Contracts

- main先ensureInitialized，再runApp(DownloaderApp)。DownloaderApp.initialize默认AppDependencies.open；FutureBuilder提供加载、初始化错误与显式重试，失败不自动循环、删库或显示伪空集合。同步抛错经Future.sync捕获，retry Future提前挂错误监听，避免下一帧前未处理错误。
- AppDependencies.open顺序：AppStore.openPersistent（四表v3）→ AndroidEngine.open(store:)或PluginEngine.open(store:) → platformFileStorage（Plugin路径注入engine.publicationJournal）→ SettingsRepository(defaultDownloadDirectory()) → application-support/staging_v1 → DownloadRepository.initialize → SavedDownloadRepository。失败对已取得settings、engine、store分别尽力释放，保留初始化首异常；PluginEngine内部失败清理及幂等close见插件规范。
- app将`.presentation`命名record通过ProviderScope override注入；feature只依赖具体Repository/FileStorage类型，禁止import app/dependencies.dart或重建应用依赖。页面销毁只退订/释放界面资源，不取消任务或关闭Engine/Store。AppDependencies.close为应用所有者入口，不保证其本身重复调用幂等。
- 三个仓库流是业务显示唯一数据源：tasks来自watchTasks、saved来自watchSavedDownloads、settings来自watchSettings。分类/数量由流派生；完成须为已发布completed，paused/failed/waitingRecovery/publishing仍属下载中。Notifier不存任务/配置/主题副本，不直接读SQL、插件或订阅Engine事件。输入、当前分类、导航留Widget。
- run同键busy或退出锁且非duringExit时返回false；接受操作时登记busy，成功返回true，捕获失败写中文error并返回false。busy/error是局部反馈，不提前修改业务状态。异步完成后只有ref.mounted才写state，销毁后Future仍结算；成功结算保留其他并发失败的error。
- pause使用任务id且duringExit=true；cancel使用独立`cancel:<id>`且duringExit=true，普通任务busy及退出等待仍保留取消菜单入口，同cancel键阻止重复提交。持久取消优先、迟到发布及uncertain清理由Repository处理，UI不得点击取消就移除记录。
- 目录选择经注入storage；null表示取消且保留原值，选择错误可反馈，不能当永久授权成功。保存配置不下载，发起/重下生成提交id并走Repository；删除默认仅记录，删文件需明确选择。确认不能绕过restartUnsupported或平台安全拒删。
- totalBytes=null时显示真实累计字节和不确定进度，不显示虚构比例。当前Repository未向UI提供合法单调样本，速度/ETA在下载详情中显示未知，紧凑列表不重复显示未知占位；禁止墙钟差分或旁路Engine补数。
- 下载/完成/缓存列表使用紧凑卡片：横向12/纵向8内边距、卡片间隔8；文件名一行省略，下载状态与字节/已知比例合并，未完成项底部保留进度条。缓存文件名/URL点击查看完整详情和保存目录。错误、待保存操作及busy反馈仍可见，不固定卡片高度；文字放大允许信息自然换行，详情和图标操作保留至少48逻辑像素点击高度。
- 已完成列表只显示 downloadedBytes 一个大小，次行显示 completedAt 的本地 YYYY-MM-DD HH:mm，缺少历史完成时间时回退 updatedAt；不展示大小/大小或进度百分比。日期保留完整可换行且有完成时间语义，下载中仍显示累计/总量。
- 已完成列表按 completedAt ?? updatedAt 降序展示，最新完成在前；仅排序分类过滤后的新列表，不修改仓库快照，下载中/缓存沿用各自原有顺序。
- macOS [AppDelegate](../../../macos/Runner/AppDelegate.swift)保留FlutterAppDelegate启动及原窗口委托转发。窗口close与菜单Quit合流，pending合并回调且每次只回复一次；`downloader/app_lifecycle`的`requestExit`无业务参数，Dart回复bool。Swift只接受CFBoolean类型且true放行，NSNumber数字、false、错误或缺回复均拒绝，approved后重入放行。
- Dart的AppLifecycleListener.onExitRequested与通道进入同一requestExit。并发退出或已有busy拒绝，确认期间锁exit阻止新提交/继续，允许pause/cancel。活动running/queued经确认后逐项等待实际pause及保存，publishing/cancelling/deleting拒绝退出。确认后检查mounted，最终重新读取watchTasks首快照，同时重查除exit外的busy及全部活动状态；任一存在则拒绝。失败解除退出锁，批准保留锁；onResume显式synchronize。协议没有系统红钮/Quit实际操作证据，Windows原生退出未接线。

- 缓存未填文件名时显示 SavedDownload.displayName：共享 downloadFileName 取 URL 最后一段已解码路径，忽略查询/片段并经可移植文件名校验；无法取名回退 download_<id>，手填名优先。保留原 fileName=null 和 URL，不在显示时改写配置或联网。
- 已完成分类标题栏提供「清空已下载」图标；空列表/读取中/任一操作busy时禁用。确认框复用 DeleteDownloadDialog(clearAll:true)，「同时删除本地已下载文件」每次打开默认false；取消不执行。确认仅处理打开确认框时的 completed ID 快照，新完成/活动/缓存不包含在内。
- clearCompleted 通过 run('clearCompleted') 按序调用原 Repository.deleteCompleted，保留完整 ack、文件归属和失败校验；一项失败即停止并显示原错误，保留失败及尚未处理项，不宣称全部成功。批处理中已完成卡片的单项变更操作禁用，运行中任务仍可取消，不绕过退出锁。

## 4. Validation & Error Matrix

| 条件 | 必须行为 |
| --- | --- |
| 初始化/日志解析失败 | 错误页与显式重试；已取得资源尽力释放，首异常保留，不删资料 |
| 流读取失败 | 显示错误与重试，不按空集合渲染 |
| 普通操作busy时取消 | 独立cancel键仍提交真实Repository，等待业务结果 |
| 异步操作中Provider销毁 | ref.mounted阻止写失效state，Future正常结算 |
| restartUnsupported / restartRequired | 中文说明原数据保留，不cancel+enqueue模拟从零重启 |
| publicationUncertain / cleanupFailure | 保留事实与记录，提示核实/重试，不虚报完成或移除 |
| permissionDenied / persistenceFailure | 提示授权或状态保存问题，不宣称完整持久成功 |
| 目录选择取消 | 原值不变；设置成功不等于所有授权组合通过 |
| requestExit数字/非法回复、通道错误、并发请求 | Swift严格拒绝非法布尔；pending合流，Dart冲突返回cancel |
| 确认后销毁、仍有活动项/非exit busy、pause保存失败 | 拒绝退出，不先批准再补保存 |

## 5. Good/Base/Bad Cases

- Good：真实Flutter View→Controller→Repository→PluginEngine/FileStorage/SQLite创建并暂停，GET=1、557056字节，业务paused与EngineReceipt一致；暂停等待时cancel仍能到Repository。
- Base：无任务为空态，选择目录取消不变，配置保存不联网，主题由设置流驱动；窄屏底部导航，宽度≥800使用NavigationRail及最大1040内容宽。
- Bad：初始化解析损坏记录、其他操作busy时取消、操作等待期间销毁容器、确认退出期间出现新busy/活动任务；须保留首异常/材料/真实状态并拒绝错误放行。

## 6. Tests Required

本轮文档同步复用已核验产物，不重跑产品测试。最终`/tmp/download-ui-check-final-{analyze,test,plugin,smoke}.exit`全0：analyze无问题，155项Flutter用例，2项真实macOS Plugin集成，1项真实UI smoke。Plugin用例覆盖注册后损坏日志初始化失败→清理→修复数据→显式retry、重复close、第二实例拒绝不误注销owner；UI smoke真实GET=1/557056字节paused且SQLite一致。host12仅临时xcconfig，仓库最低目标未改。

[Widget/Provider回归](../../../test/widget_test.dart)覆盖分类数量、表单/确认/错误、主题和目录取消、独立cancel到Repository、销毁后Future结算、暂停pending菜单仍含取消。375窄屏、2倍字体、250键盘inset和表单semantics有Widget证据。[Plugin集成](../../../integration_test/plugin_engine_test.dart)与[UI集成](../../../integration_test/download_ui_test.dart)分别在真实macOS进程通过。联合集成首轮第二个host连接失败exit1，拆分后各自通过；Widget初稿动画等待超时/点击未命中修正后通过，保留历史失败。

退出自动化为Dart MethodChannel fake：pending拒绝、取消确认、pause失败拒绝、保存回执前不回复、确认期间创建锁及批准后保留锁。Swift随真实host12编译不等于系统退出通过，红钮/Quit、交错请求及生命周期真实操作仍缺。已检查实际RenderRepaintBoundary帧，系统截图黑屏、foreground失败不算系统窗口视觉通过。

保留阻断：速度/ETA未知，restartUnsupported，响应文件名/最终URL未交付，Apple/SAF现存文件删除及Apple用户目录临时副本回收未完成；Windows退出未接线，macOS红钮/Quit未实际操作，iOS/Windows/最低版本未验收。Android设备/模拟器本轮运行0，由用户负责。完整创建→暂停→继续→发布→打开/删除→重开UI闭环、七页面全套真机截图、真人屏幕阅读器及完整桌面焦点遍历仍需验收，不能由当前局部PASS勾选PRD。

## 7. Wrong vs Correct

错误：feature反向import app取得依赖；Notifier复制任务列表；点击就置paused；所有入口共用busy阻止取消；异步完成无条件写state；NSNumber(1)批准退出。

正确：app注入具体能力record，三仓库流提供业务事实；操作状态局部保存，取消独立键，异步写state前检查ref.mounted；macOS严格CFBoolean且Dart最终重查。

```dart
Future<bool> cancel(String id) => run(
  'cancel:$id',
  () => dependencies.downloads.cancel(id),
  duringExit: true,
);
// run成功分支：不因本次成功抹掉其他并发失败
if (ref.mounted) {
  state = OperationState(
    busy: {...state.busy}..remove(id),
    error: state.error,
  );
}
```
