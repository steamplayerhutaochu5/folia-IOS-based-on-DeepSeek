<p align="center">
  <img src="https://github.com/user-attachments/assets/b5d0e863-48be-497b-b0e9-4bd8d8ce9bf0" alt="Folia" width="100%" />
</p>

<div align="center">

# Folia for iOS

Lyrics Reimagined // 辞曲新境 · iOS 非官方移植

[![License](https://img.shields.io/github/license/chthollyphile/folia-major)](https://github.com/chthollyphile/folia-major/blob/main/LICENSE)
[![Node.js](https://img.shields.io/badge/node-%3E%3D24-339933?logo=node.js&logoColor=white)](https://nodejs.org/)
[![iOS](https://img.shields.io/badge/iOS-15%2B%20%C2%B7%20tested%20on%2027-000000?logo=apple&logoColor=white)](#)
[![Build](https://img.shields.io/badge/build-GitHub%20Actions%20%C2%B7%20unsigned%20ipa-2088FF?logo=githubactions&logoColor=white)](.github/workflows/ios-ipa.yml)

[项目定位](#项目定位)
·
[功能状态](#功能状态)
·
[构建与安装](#构建与安装)
·
[开发说明](#开发说明)
·
[已知限制](#已知限制)
·
[免责声明](#法律与免责声明)

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

## 架构

```text
React/Vite 前端（来自 folia-android，src/ 原样复用）
  │  window.Capacitor.Plugins.FoliaNative（与 Android 同名、同协议）
  ▼
FoliaNativePlugin.swift
  ├── FoliaCookieJar        Cookie 持久化 + WKHTTPCookieStore 镜像
  ├── URLSession            httpRequest：Cookie 注入、超时、可选禁重定向、Set-Cookie 回写
  ├── UIDocumentPicker      pickAudioFiles / pickAudioFolder → Documents/imported-audio
  ├── FoliaLocalAudioServer 127.0.0.1 HTTP 服务：Range / HEAD / OPTIONS / CORS
  ├── FoliaMediaSession     AVAudioSession + Now Playing + 远程控制
  └── FoliaDiagnostics      Documents/diagnostics 诊断落盘
```

## 功能状态

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 在线搜索与播放 | ✅ | 网易云 / QQ / 酷狗，网络请求走原生桥 |
| 扫码 / 网页登录 | ✅ | Cookie 保存在原生仓库 |
| 全屏歌词与动画 | ✅ | 复用 Web 端可视化；iOS 内存上限需实测 |
| 本地音乐（Files 导入） | ✅ | 文件复制进 App 私有目录，通过本地 HTTP 播放 |
| 屏幕常亮 | ✅ | `UIApplication.isIdleTimerDisabled` |
| 锁屏 / 控制中心 | ✅ | 元数据 + 播放/暂停/上一首/下一首 |
| 后台播放 | ⚠️ | 已配置 `UIBackgroundModes: audio`，真机续播能力待验证 |
| 设备音乐库扫描 | ❌ | iOS 没有 Android MediaStore 的等价能力 |
| 手机适配 / 沉浸式 / 灵动岛歌词 | ❌ | Android 窗口特性，iOS 侧不适用 |
| 未签名 ipa 构建 | ✅ | GitHub Actions `macos-26` / `xcode-27` |

## 构建与安装

### 1. 云端构建（推荐，无需 Mac）

推送代码后，在 GitHub Actions 页面运行 **iOS unsigned IPA**：

- runner 可选 `macos-26`（Xcode 26 GA，稳定）或 `xcode-27`（preview，iOS 27 SDK）；
- 构建产物 `Folia-unsigned.ipa` 以 artifact 形式提供，保留 30 天；
- 工作流定义：[.github/workflows/ios-ipa.yml](.github/workflows/ios-ipa.yml)。

本仓库的 `main` 分支已经配置好该工作流，也可以手动触发：

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

未签名 ipa 不能直接安装，必须签名。免费 Apple ID 方案：

1. Windows 安装 [Sideloadly](https://sideloadly.io/) 或 AltStore，并准备 Apple ID；
2. 用 USB 连接设备，把 `Folia-unsigned.ipa` 拖进 Sideloadly；
3. 输入 Apple ID 签名并安装（bundle id：`top.izuna.foliamajor`）；
4. iPhone：设置 → 通用 → VPN 与设备管理 → 信任开发者证书；
5. 设置 → 隐私与安全性 → 开发者模式 → 打开并重启。

免费证书 7 天有效，到期需要重新签名；付费开发者账号可延长到 1 年。
若使用付费证书，也可以直接在 Xcode 的 `Signing & Capabilities` 里选择 Team 后安装到真机。

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
- 新增 Swift 文件时，需要同时更新 `project.pbxproj` 的 `PBXBuildFile`、`PBXFileReference`、`PBXGroup`、`PBXSourcesBuildPhase`。

## 已知限制

- **后台播放**：WKWebView 的音频在 App 进入后台后可能被系统挂起；当前配置了后台音频模式，但是否续播需要真机验证。若失败，后续需要增加原生 `AVPlayer` 播放通道。
- **本地音频跨源**：页面源是 `capacitor://localhost`，`<audio>` 请求 `http://127.0.0.1:<port>` 属于跨源，服务端已返回 `Access-Control-Allow-Origin: *`，`Info.plist` 已允许本地网络；若 iOS 27 收紧策略需要另做方案。
- **内存**：iOS 的 WKWebView 内存上限低于桌面，部分 3D 可视化主题可能触顶崩溃，需要按崩溃日志做视觉降级。
- **设备音乐库**：iOS 不支持扫描系统音乐库，本地音乐只能通过「文件」App 导入。
- **分发**：第三方音乐接口与内容版权风险由使用者承担，不建议也不能上架 App Store。

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
