# iOS 移植计划

保持 android 和上游文档。以 docs/rain-classroom-api.md、docs/classroom-activity-api.md 和 RainApi.java 为协议依据，以脱敏历史记录为解析测试依据。

| Android 模块 | iOS 对应方案 | 阶段 |
|---|---|---|
| RainApi、QrLoginController、AccountStore、SessionVault | 账号隔离的 URLSession、二维码授权、Keychain | 1 |
| CourseCatalog、LessonQr、课堂连接 | 课程与在课列表、ID 与相机扫码、A13、WebSocket hello | 2 |
| FeedStore、FeedTimeline、LessonReport | 分页、报告、账号隔离缓存 | 3 |
| SlideExporter、PptxWriter | 课件预览、照片权限、图片嵌入 PPTX 与 ZIP | 4 |
| Gradle 和 Android CI | XcodeGen、模拟测试、macOS 编译与未签名 IPA | 5 |

每阶段核对方法、路径、业务码及字段，再运行测试并检查 macOS CI 日志。密码和短信所需腾讯人机验证依赖上游网页流程，首轮以二维码登录替代。自定义位置签到、答题、AI 与多账户同步不在本次功能清单。iOS 后台挂起时断开课堂连接，回到前台使用已有凭证重连。
