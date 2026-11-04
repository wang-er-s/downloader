# Flutter 界面设计

## 前置与范围

依赖 repositories 的稳定业务 API，且前四项安全原型无未解决阻断。按[源设计](../../../.agents/specs/download-manager/design.md)和[截图评审](../../../.agents/specs/download-manager/review.md)呈现已确认交互，不重新做产品风格选择。

## 结构

app 组装入口、主题和功能依赖；features/downloads、saved_downloads、settings 放自身页面和 Controller。Riverpod Notifier 承担 ViewModel；StreamProvider 订阅唯一任务流，分类和数量派生。局部输入/当前分类可留 Widget，不再增设另一套 ViewModel。

## 交互

下载与设置两个入口，三类下载分类；failed/paused/waitingRecovery/publishing 仍归下载中。新建/编辑字段共享校验，保存配置不执行。删除默认记录-only，删除文件和从零重下明确确认。未知总长保留真实字节，不显示假百分比/剩余时间；系统无新事件不伪造速度。

移动弹窗避让键盘、可滚动；窄桌面采用紧凑导航，宽屏分配列表空间。长名称截断后可查看，支持字体缩放、语义、焦点和键盘操作。桌面关闭窗口/菜单退出走协调流程，活动任务先确认停止；不增加托盘。

## 失败与验证

读取失败不当空态；操作等待与业务状态分开；发布 uncertain、权限、空间、清理失败有可行动反馈。Widget 测试验证交互和语义，平台真机/桌面截图验证布局与关闭流程，不能只用 golden 图宣称下载通过。

## 回滚

替换计数器首页及旧 smoke test 与业务入口一起进行；不修改底层安全契约以适应页面。保留原用户资料，UI 回滚不删除任务或用户文件。
