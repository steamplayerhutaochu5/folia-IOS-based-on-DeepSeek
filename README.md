<p align="center">
  <img src="https://github.com/user-attachments/assets/b5d0e863-48be-497b-b0e9-4bd8d8ce9bf0" alt="Folia" width="100%" />
</p>

<div align="center">

# Folia for iOS

Lyrics Reimagined // 辞曲新境 · iOS 非官方移植

[![version](https://img.shields.io/badge/version-0.7.20--ios.1-blue)](#当前版本与下载)
[![License](https://img.shields.io/github/license/chthollyphile/folia-major)](https://github.com/chthollyphile/folia-major/blob/main/LICENSE)
[![Node.js](https://img.shields.io/badge/node-%3E%3D24-339933?logo=node.js&logoColor=white)](https://nodejs.org/)
[![iOS](https://img.shields.io/badge/iOS-15%2B%20%C2%B7%20tested%20on%2027.0.1-000000?logo=apple&logoColor=white)](#)
[![Build](https://img.shields.io/badge/build-GitHub%20Actions%20%C2%B7%20unsigned%20ipa-2088FF?logo=githubactions&logoColor=white)](.github/workflows/ios-ipa.yml)

[当前版本](#当前版本与下载)
·
[功能状态](#功能状态)
·
[与 Android 的差异](#与-android-版的差异)
·
[构建与安装](#构建与安装)
·
[开发说明](#开发说明)
·
[已知限制](#已知限制)
·
[更新日志](#更新日志)

</div>

---

> [!IMPORTANT]
> **本仓库是 Folia 的非官方 iOS 移植 fork，与上游作者无关。**
>
> - 上游项目：[chthollyphile/folia-major](https://github.com/chthollyphile/folia-major)
> - 上游许可证：**AGPL-3.0**（见 [LICENSE](LICENSE)）
> - 本 fork 从 [whycfawa/folia-android](https://github.com/whycfawa/folia-android)（Folia 的非官方 Android 移植）继续派生，
>   在其内置的 Web 前端与 `FoliaNative` 桥协议之上新增 Capacitor iOS 容器、Swift 原生实现与未签名 ipa 构建流水线
> - 本仓库整体仍以 **AGPL-3.0** 发布，许可证未作修改或附加限制；第三方组件与许可见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)
> - 上游 README 中「仅供个人学习、技术交流与非营利测试使用，请勿用于商业盈利用途」的声明同样适用于本 fork

## 项目定位

Folia 是一个以全屏沉浸式歌词为核心的在线音乐播放器，支持网易云、QQ 音乐、酷狗、Navidrome 与本地音乐。
本项目把它的 Web 前端装进 Capacitor 的 iOS 容器，并补齐 iOS 缺失的原生能力，让它在 iPhone / iPad 上可以像普通 App 一样安装使用。

与「用 Safari 把网页添加到主屏幕」的 PWA 方式相比，iOS 版多做了这些事：

- **绕开 CORS 的网络层**：在线音乐 API、封面、歌词请求全部交给原生 `URLSession`，不再受 WKWebView 的同源策略限制；
- **原生 Cookie 仓库**：网易云 / QQ / 酷狗的登录态在 `FoliaCookieJar` 中持久化，并镜像到 `WKHTTPCookieStore`；
- **Files 导入本地音乐**：通过系统文件选择器把音频复制进 App 私有目录，再由本地 HTTP 服务以支持 Range 的方式喂给 `<audio>`；
- **锁屏与控制中心**：`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` 显示歌曲信息并响应播放/暂停/上一首/下一首；
- **未签名 ipa 云构建**：由 GitHub Actions 的 macOS runner 编译，产物下载后自行签名安装，不依赖本地 Mac。

> 构建细节、方法映射与限制清单见 [docs/IOS_PORT.md](docs/IOS_PORT.md)。

## 当前版本与下载

**当前版本：`0.7.20-ios.1`**（首个 iOS 测试发行版，在 iPhone 17,4 / iOS 27.0.1 上实测）。

- 下载：[Releases 页面](https://github.com/zhumuzhumuzhumu/folia-IOS/releases/latest) 中的 `Folia-unsigned.ipa`；
- 这是**未签名**包，不能直接安装，必须先用 Apple ID / 开发者证书签名（见 [安装](#3-安装到-iphone--ipad)）；
- 版本号同时写入 `package.json` 与 iOS 工程的 `MARKETING_VERSION`；
- 同一版本的源码、构建日志和校验值见对应 Release 说明。

## 架构

```text
React/Vite 前端（来自 folia-android，src/ 原样复用）
  │  window.Capacitor.Plugins.FoliaNative（与 Android 同名、同协议）
  ▼
FoliaNativePlugin.swift
  ├── FoliaCookieJar        Cookie 持久化 + WKHTTPCookieStore 镜像
  ├── URLSession            httpRequest：Cookie 注入、超时、可选禁重定向、Set-Cookie 回写
  ├── UIDocumentPicker      pickAudioFiles / pickAudioFolder → Documents/imported-audio
  ├── FoliaLocalAudioServer 127.0.0.1 HTTP 服务：Range / HEAD / OPTIONS / CORS / 流式转发
  ├── FoliaMediaSession     AVAudioSession + Now Playing + 远程控制
  └── FoliaDiagnostics      Documents/diagnostics 诊断落盘
```

## 功能状态

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 在线搜索与播放 | ✅ | 网易云 / QQ / 酷狗，网络请求走原生桥 |
| 扫码 / 网页登录 | ✅ | Cookie 保存在原生仓库 |
| 全屏歌词与动画 | ✅ | 复用 Web 端可视化 |
| 本地音乐（Files 导入） | ✅ | 文件复制进 App 私有目录，通过本地 HTTP 播放 |
| 屏幕常亮 | ✅ | `UIApplication.isIdleTimerDisabled` |
| 锁屏 / 控制中心 | ✅ | 元数据 + 播放/暂停/上一首/下一首 |
| 后台 / 息屏播放 | ⚠️ | 已配置 `UIBackgroundModes: audio` 并在切后台时重申会话；真机续播仍在验证 |
| 设备音乐库扫描 | ❌ | iOS 没有 Android MediaStore 的等价能力 |
| 手机适配 / 沉浸式 / 灵动岛歌词 | ❌ | Android 窗口特性，iOS 侧不适用 |
| 未签名 ipa 构建 | ✅ | GitHub Actions `macos-26` / `xcode-27` |

## 与 Android 版的差异

两端共用同一套 Web 前端与 `FoliaNative` 桥协议，但原生实现按平台重写：

| 能力 | Android | iOS |
| --- | --- | --- |
| 网络栈 | OkHttp + `CookieManager` | `URLSession` + 自建 Cookie 仓库 |
| 本地音频服务 | Java `LocalAudioServer` | Swift POSIX socket + 流式转发 |
| 媒体控制 | 前台服务 + 通知栏 MediaSession | `AVAudioSession` + Now Playing + 远程控制，无通知栏 |
| 后台播放 | 前台服务保活 + WakeLock / WifiLock | `UIBackgroundModes: audio`，无前台服务 |
| 文件导入 | SAF 选择文件/目录 + MediaStore 扫描 | `UIDocumentPicker` 复制副本，无 MediaStore |
| 挖孔 / 沉浸式 / 方向锁定 | 原生窗口适配 | 由系统安全区接管，相关设置入口隐藏 |
| 程序化退出 / 退到后台 | 支持 | iOS 不允许，方法为空实现 |
| 厂商歌词桥（ColorOS） | 支持 | 未实现，只做系统 Now Playing |
| 分发 | Gradle 构建 APK | Xcode/SPM 构建未签名 IPA，需自签 |

## 构建与安装

### 1. 云端构建（推荐，无需 Mac）

推送代码后，在 GitHub Actions 页面运行 **iOS unsigned IPA**：

- runner 可选 `macos-26`（Xcode 26 GA，稳定）或 `xcode-27`（preview，iOS 27 SDK）；
- 构建产物 `Folia-unsigned.ipa` 以 artifact 形式提供，保留 30 天；
- 工作流定义：[.github/workflows/ios-ipa.yml](.github/workflows/ios-ipa.yml)。

```text
Actions → iOS unsigned IPA → Run workflow
```

### 2. 本地 macOS 构建

```bash
npm ci
npm run build:capacitor
npx cap sync ios
npx cap open ios        # 在 Xcode 中配置签名后 Run
```

命令行未签名打包：

```bash
npm run build:ios:archive
mkdir -p build/Payload
cp -R build/App.xcarchive/Products/Applications/App.app build/Payload/
cd build && zip -qry Folia-unsigned.ipa Payload
```

### 3. 安装到 iPhone / iPad

未签名 ipa 不能直接安装，必须签名。以下任选一种：

- **iLoader**：打开 iLoader，导入 `Folia-unsigned.ipa`，签名并安装；
- **Sideloadly**：USB 连接设备，把 ipa 拖入 Sideloadly，输入 Apple ID 签名安装；
- **AltStore**：通过 AltServer 安装；
- 有开发者账号时，也可以在 Xcode 的 `Signing & Capabilities` 中选择 Team 后直接 Run 到真机。

安装后如需手动信任：设置 → 通用 → VPN 与设备管理 → 信任开发者证书；并开启 设置 → 隐私与安全性 → 开发者模式。
免费 Apple ID 证书 7 天有效，到期需要重新签名；付费开发者账号可延长到 1 年。

## 开发说明

### 目录

```text
ios/
  App/App.xcodeproj/          Xcode 工程（SPM，共享 scheme App）
  App/App/
    AppDelegate.swift         模板入口
    SceneDelegate.swift       UIScene 生命周期
    FoliaBridgeViewController.swift  插件注册 / 状态栏 / WebView 配置
    FoliaNativePlugin.swift   FoliaNative 插件实现
    FoliaCookieJar.swift      Cookie 仓库
    FoliaLocalAudioServer.swift       本地音频 HTTP 服务
    FoliaMediaSession.swift   锁屏 / 控制中心
    FoliaDiagnostics.swift    诊断落盘
  App/CapApp-SPM/             Capacitor 的 SPM 依赖（由 CLI 生成）
src/services/                 前端平台适配（原生桥、本地音乐、状态栏）
.github/workflows/ios-ipa.yml 未签名 ipa 构建
docs/IOS_PORT.md              iOS 移植说明
```

### 常用命令

```bash
npm run build:capacitor   # 构建 Web 产物（FOLIA_BUILD_TARGET=capacitor）
npm run cap:sync:ios      # 构建 + 同步到 iOS 工程
npm run cap:open:ios      # 用 Xcode 打开工程
npm run build:ios:archive # 未签名 archive（仅 macOS）
npm run typecheck         # TypeScript 类型检查
```

### 约定

- 新增原生能力时，先对齐 Android 的 `FoliaNativePlugin` 方法名与返回结构，再实现 Swift 侧；
- Swift 方法需要 `@objc`，并同时登记到 `pluginMethods`；
- 自定义插件不在 `node_modules`，由 `FoliaBridgeViewController.capacitorDidLoad()` 显式注册；
- 新增 Swift 文件时，需要同时更新 `project.pbxproj` 的 `PBXBuildFile`、`PBXFileReference`、`PBXGroup`、`PBXSourcesBuildPhase`；
- 诊断文件写入 App 的 `Documents/diagnostics`，可通过「设置 → 帮助 → 导出诊断数据」取出。

## 已知限制

- **后台 / 息屏播放**：iOS 的 WKWebView 在切后台后可能被系统暂停媒体；当前已声明后台音频模式并在切后台时重申 `AVAudioSession`，但仍需真机确认。若最终无法维持，需要增加原生 `AVPlayer` 后台播放通道。
- **本地音频跨源**：页面源是 `capacitor://localhost`，`<audio>` 请求 `http://127.0.0.1:<port>` 属于跨源，服务端已返回 `Access-Control-Allow-Origin: *`，`Info.plist` 已允许本地网络。
- **内存**：iOS 的 WKWebView 内存上限低于桌面，部分 3D 可视化主题可能触顶崩溃，需要按崩溃日志做视觉降级。
- **设备音乐库**：iOS 不支持扫描系统音乐库，本地音乐只能通过「文件」App 导入。
- **厂商特性**：ColorOS 歌词、通知栏播放卡片、挖孔/沉浸式布局在 iOS 上没有对应实现。
- **分发**：第三方音乐接口与内容版权风险由使用者承担，不建议也不能上架 App Store。

## 更新日志

### 0.7.20-ios.1（首个 iOS 发行版）

- 新增 Capacitor iOS 容器（SPM、UIScene 模板、共享 scheme）与 GitHub Actions 未签名 ipa 构建；
- 实现 `FoliaNative` 的 Swift 端：Cookie 仓库、`URLSession` 网络代理、`UIDocumentPicker` 文件导入、本地音频 HTTP 服务、锁屏/控制中心媒体控制、诊断落盘；
- 本地音频转发改为流式，修复「点击播放长时间无首字节」；
- 修复 `FoliaDiagnostics` 心跳文件指数膨胀导致的 OOM 闪退（真机 `.ips` 崩溃栈确认）；
- 修复音频连接被 WebView 提前关闭时写 socket 触发 SIGPIPE 的闪退；
- 修复 `AVAudioSession`/AudioContext 被中断后「有缓冲但无声、进度不走」；
- 调整音频会话配置时机（播放前配置、播放中不重配），解决播放几秒后自动暂停；
- 后台/息屏时重申音频会话（续播能力持续验证中）；
- 修复酷狗音频直连 CDN 导致的 `MEDIA_ERR_SRC_NOT_SUPPORTED`：酷狗播放地址统一走本地回环代理，并补齐酷狗 Referer。

## 贡献者

本 iOS 移植由 [@zhumuzhumuzhumu](https://github.com/zhumuzhumuzhumu) 维护，构建流水线与真机测试由其完成；
代码实现过程中使用了 DeepSeek 作为 AI 编码协助（工具，不计入人类贡献者）。

- 上游 Folia：[chthollyphile](https://github.com/chthollyphile)（冬霧）及上游贡献者
- Android 移植：[whycfawa](https://github.com/whycfawa) 及 folia-android 贡献者
- iOS 移植与发行：[zhumuzhumuzhumu](https://github.com/zhumuzhumuzhumu)

完整名单与各角色说明见 [CONTRIBUTORS.md](CONTRIBUTORS.md)。

## Community

加入 Discord 社群交流与反馈：

[![Discord](https://img.shields.io/discord/1541051241822687232?logo=discord&logoColor=white&label=Join%20our%20Discord)](https://discord.gg/dMDBTHxeKd)

上游文档与使用指南：[Folia Guide](https://folia-site.cielaniska.top/guide/) ·
[技术与开发说明](docs/technical.md) ·
[本地音乐库管理](docs/local-library-management.md)

## 致谢

本项目建立在上游与 Android 移植的工作之上：

- [chthollyphile/folia-major](https://github.com/chthollyphile/folia-major) — Folia 上游
- [whycfawa/folia-android](https://github.com/whycfawa/folia-android) — Android 容器与 `FoliaNative` 桥协议
- [chenmozhijin/LDDC](https://github.com/chenmozhijin/LDDC)
- [NeteaseCloudMusicApiEnhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced)
- [chenglou/pretext](https://github.com/chenglou/pretext)
- [MakcRe/KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi)
- [paper-design/shaders](https://github.com/paper-design/shaders)
- [yakult-green-tea/qq-music-api](https://github.com/yakult-green-tea/qq-music-api)

## 法律与免责声明

本项目在 AI 的广泛协助下开发，因此仍可能存在细微或不易察觉的问题。若给你带来不便，敬请理解。

本项目主要用于展示播放动效、界面设计与相关工程实现。应用中涉及的在线音乐流媒体、歌词、专辑封面及其他内容，其版权均归对应权利人所有。

本仓库及其源代码仅供个人学习、技术交流与非营利测试使用。请勿将其用于商业盈利用途。若因对在线资源的传播、加工或再分发而引发版权纠纷或其他责任，均由使用者自行承担，项目开发者不承担相关责任。

请始终尊重数字版权，并在条件允许时通过官方平台支持正版音乐。

## 许可证

本项目基于 `AGPL-3.0` 许可证开源。
