# Android 执行实施计划

## 前置

contracts-store 的模型和协议测试通过后激活；无需等待 PluginEngine，不与其同时写共享文件。

- [ ] 阅读 MainActivity、manifest、Gradle 及生成边界，确认最低 SDK/target 与 Java 配置。
- [ ] 实现会话握手、类型校验、稳定命令、原生日志及非破坏性 inspect/ack。
- [ ] 实现前台服务、持久暂存、HTTP/HTTPS 与重定向、未知总长字节及安全续传。
- [ ] 接入 AndroidEngine，暂停/取消等待真实停止并保存回执，断连不等于取消。
- [ ] 配置最小权限和服务，处理通知拒绝、后台启动与系统超时；不加自动启动下载路径。
- [ ] 进行协议、原生和设备故障测试，记录 file-storage 所需日志/发布扩展边界。

## 检查

flutter analyze、flutter test；在 android/ 下运行 ./gradlew :app:testDebugUnitTest，实际任务存在时执行相应 instrumentation 测试；flutter build apk --release 验证构建。release 当前 debug 签名只能作本地验证，不宣称完成分发签名。

受控 HTTP 服务核对 Range/ETag/字节和请求次数。设备矩阵覆盖 API 29/30/33/35/36：切后台、滑走 Activity、重连、强杀、重启、通知拒绝、超时。无用户操作重开后新请求为零；旧会话/旧代次/超前 ack 均无副作用。暂停回执和确认前后分别中断验证重放。

## 停点与回滚

不因单个模拟器通过宣称全部平台通过；缺设备记录未测，不能完成本任务验收。保留未完成日志和材料；协议变化同步 Dart、Kotlin、测试和源规范，不删库、不回退其他任务变更。
