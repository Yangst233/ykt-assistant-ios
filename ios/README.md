# 雨课堂助手 iOS

原生 SwiftUI 客户端，最低支持 iOS 17.0，使用 MVVM、Swift Concurrency 和 URLSession。原 Android 工程保留在 android/。功能与接口对应关系见 [移植计划](PLAN.md)。

## 构建与测试

在安装完整 Xcode 和 iOS 模拟器运行时的 macOS 上运行。

```sh
brew install xcodegen
cd ios
xcodegen generate
open RainAssistant.xcodeproj
```

在 Xcode 中选择 RainAssistant scheme，运行 Product → Test。测试通过 URLProtocol 模拟接口，无需真实账号。提交到有权限的 GitHub 仓库后，Actions 中的 Build iOS 工作流支持手动触发，也会在相关源码变更的 push 和 pull request 上运行。先执行模拟器测试，再编译 arm64 真机 App 和上传未签名 IPA。测试报告可从 ios-test-results artifact 下载。

## 签名与安装

1. 在 Xcode 中选择 RainAssistant 应用 target，打开 Signing & Capabilities，启用 Automatically manage signing 并选择自己的 Team。若 Bundle ID 已被占用，在 project.yml 修改 PRODUCT_BUNDLE_IDENTIFIER 后重新运行 XcodeGen。
2. 连接并解锁 iPhone，信任 Mac。在设备上按提示启用开发者模式，然后在 Xcode 中选择该设备运行。
3. 如果需要分发，在 Xcode 使用 Product → Archive，再通过 Organizer 选择适合所用 Team 的 TestFlight、Ad Hoc 或其他分发方式。可直接下载 CI 的未签名 IPA 查看或供后续签名。真机安装需要有效签名和匹配的描述文件。

证书及签名材料由本机或组织的签名系统管理。登录后，Cookie 和课堂凭证保存在仅本机可访问的 Keychain。动态分页在会话内保留，图片缓存仅在内存中，切换账号后清空。导出在本机完成，从系统分享菜单保存到文件或发送给其他 App。

## 使用与平台差异

- 在「账号」选择服务并生成登录二维码。在另一台设备上用微信扫码确认，保持 iOS App 在前台等待授权。账号可切换和移除。
- 在「课程」点击正在上课的课堂，或输入课堂 ID、粘贴二维码链接、使用支持 VisionKit 的设备扫码。缺少课堂凭证时会先要求确认签到。相机不可用时仍可手动输入。
- 在「动态」加载记录，按课程和类型筛选，查看历史签到和可见课件。课堂页的实时课件使用课堂凭证。PPTX 将页面图片嵌入幻灯片，ZIP 包含编号 JPEG。
- iOS 后台挂起期间课堂连接暂停，回到前台用已有凭证重连。课堂结束、凭证失效或网络连接异常会在界面提示。凭证本地保留上限为 24 小时。
- 密码和短信登录涉及 Android 端使用的网页人机验证。iOS 使用二维码授权。自定义位置签到、课堂答题、AI 和多账号同步未移植。
- 当前 Windows 工作区可以检查源码和文件格式。Xcode 编译、模拟器测试与 IPA 生成须由 macOS 工作流验证。真实登录、入课、相机和照片权限还需要在 iPhone 上验收。
