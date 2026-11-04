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
