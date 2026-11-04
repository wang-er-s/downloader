# 插件补丁实施计划

## 依赖与顺序

contracts-store 的协议/存储测试已通过（48 项），并以 e58df05、1edb779 提交、归档；本任务已于 2026-11-04 激活。用户已授权按既定规划直接实施、检查、提交并推进，无需逐次确认。该任务与 android-engine 可独立，但默认顺序推进，一个工作区只有一个写入者。

- [ ] 获取并核对固定 9.5.9 归档；保存许可证、校验及补丁说明，配置显式 path 依赖。
- [ ] 搜索所有回执 pop、异步状态写入、终态/恢复材料清理调用方，补齐持久 read/ack 和受控释放；测试不保留旧破坏路径。
- [ ] 增加不依赖总长的累计字节事件，校准恢复偏移和时钟窗口。
- [ ] 桌面实际 GET 写前验证，阻止 isResume=false/FileMode.write/deleteTempFile 静默降级。
- [ ] 实现 PluginEngine、幂等命令、inspect/ack 以及启动关联；保护 iOS 后台临时文件。
- [ ] 做故障注入和本地可控 HTTP 测试，记录桌面及 iOS 原型结论，再交给仓库/文件任务。

## 验证

flutter analyze、flutter test，以及补丁自身相关测试；新增测试文件创建后在本计划记录实际路径。macOS 用 flutter build macos --release 验证原生集成；Windows 必须在 Windows 机器 flutter build windows --release 并运行测试；iOS 可先 flutter build ios --no-codesign 验证编译，后台/强退/恢复必须实体设备执行。

必须断言：三处回执交付中断可重放；重复/旧 ack 不丢新材料；零重试 failed 保留引用；无长度响应中途字节增长；续传不安全时原部分文件散列不变；桌面重开无自动请求；iOS 关联不重复提交且按系统事件落盘。

## 风险与停点

没有设备、Windows 环境或 iOS 安全续传证据时保持未验收，记录命令/环境/错误，不将 fake 通过当作平台通过。不得未经确认采用“总是从头重下”或忽略 iOS。回滚只处理本任务的补丁和适配，不覆盖其他任务已用的 schema。

## 开工交接

- implement/check 上下文已增加 [持久化契约](../../spec/frontend/persistence.md)，复用实际 ExecutionKey/EngineCommand/Receipt/Ack 与 AppStore 边界，不重建业务事实库。
- 精确基础依赖保持 sqlite3 3.5.2、path_provider 2.1.6；不升级 SDK、不加依赖覆盖。上游插件引入及任何必要配置变更需记录实际原因和检查结果。
- 源设计当前 570 行、55,463 字节，超过注入上限；实施和审查代理必须分段完整读文件，不能只依赖自动上下文。
- 首个子任务只验证当前主机真实 SQLite；本任务所有尚未运行的原生、Windows 和 iOS 真机条目保持未验证，不借用前一任务结果宣称平台通过。
