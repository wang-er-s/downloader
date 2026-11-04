# 实施计划

## 激活前门槛

- [x] 父任务及七个子任务的 prd/design/implement 和上下文清单均已校验。
- [x] 最终任务摘要已获用户明确批准（2026-11-04：“可以，开始吧”）；允许开始首个子任务。
- [x] 已激活 download-contracts-store 为 in_progress；父任务保持编排用途，其余子任务按依赖推进。
- [x] 用户于 2026-11-04 批准当前两笔提交，并明确授权本任务树后续在实现、检查和规范同步通过后直接提交、继续下一子任务，不再逐次请求提交或启动确认。范围变更、无法验证的安全契约仍按实际阻断报告，不混入既有无关修改。

## 执行顺序与依赖

| 顺序 | 任务 | 必须先满足 |
| --- | --- | --- |
| 1 | download-contracts-store | 用户批准最新规划摘要 |
| 2 | download-plugin-engine | contracts-store 的模型、协议和存储测试通过 |
| 3 | download-android-engine | contracts-store 通过；可与 plugin-engine 独立推进但不默认并行写同一工作区 |
| 4 | download-file-storage | contracts-store 通过，两个引擎日志/回执边界可用 |
| 5 | download-repositories | contracts-store、plugin-engine、android-engine、file-storage 的安全原型门槛通过 |
| 6 | download-ui | repositories 契约可用，真实引擎与文件安全验证没有未解决阻断 |
| 7 | download-platform-validation | 前六项可集成；各子任务验证证据完整 |

依赖写入子任务文件，不将 parent/child 链接误当作依赖调度器。缺少设备的任务保持未验收，不为了开始界面而假定门槛通过；若需调整交付范围，回到用户决定。

## 每个子任务的执行闭环

1. task.py start 指向该子任务，按 implement.jsonl 及 prd/design/implement 加载上下文。
2. 按项目协议派发 trellis-implement，首行为实际 task.py current 路径；明确一个工作区一个写入者，不自行扩展范围或提交。
3. 加载 trellis-check 进行质量检查；先读后改，检查调用方、原生协议、测试、fixture、配置与导出。
4. 运行该任务的定向测试和 flutter analyze；记录失败及未验证环境。未满足验收不归档为完成。
5. 更新真实接口规范和进度，保留可审查变更；提交与推送须遵守用户授权，不擅自包含原有修改。

## 集成检查

- [ ] flutter analyze、flutter test 及相关原生/平台测试。
- [ ] 五项审查问题的故障注入记录与实际 GET 服务端请求证据。
- [ ] Android/macOS/Windows release 构建及运行；iOS 真机后台/恢复与文件验证。
- [ ] 逐项关闭父 PRD 的 49 项验收引用，不以样板计数器测试替代。
- [ ] 更新未实现、受限及待用户决定事项；只在证据齐全后宣布交付。

## 回滚点

每个子任务独立审阅差异；补丁、平台配置、schema 和 UI 分开审查。回滚仅撤回本次拥有的文件变更，不清理用户未跟踪的 docs、spec 或代理配置。
