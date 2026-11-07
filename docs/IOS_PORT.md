# Folia for iOS（未签名 ipa 构建）

本仓库在 [folia-android](https://github.com/whycfawa/folia-android) 的 Web 前端与
FoliaNative 桥协议之上，新增了 Capacitor iOS 容器。目标是在 iOS 27 真机上安装、
播放和导入本地音乐；产物是无签名的 `.ipa`，由使用者自行签名安装。

> 本文档只描述当前 fork 的 iOS 实现与构建方式。上游许可为 **AGPL-3.0**：
> 分发 ipa 时必须同时提供完整对应源码；在线音乐服务的内容与接口由各服务方提供，
> 本项目不声称拥有任何音乐版权，也不建议上架 App Store。

## 1. 环境与工具链

| 角色 | 版本 / 说明 |
| --- | --- |
| macOS | 构建必须使用 macOS；Windows/Linux 只能生成工程与 Web 产物 |
| Xcode | 26.x（稳定）或 27.x（iOS 27 SDK，Capacitor 8.5+ 已适配 UIScene） |
| Node.js | 24 |
| Capacitor | 8.6.x（core / cli / ios / android 同一 minor） |
| iOS Deployment Target | 15.0（可运行于 iOS 15–27） |
| 依赖管理 | Swift Package Manager（不使用 CocoaPods） |

Capacitor 8 要求 Xcode 26+；Xcode 27 强制 UIKit 的 scene 生命周期，因此
`ios/App/App/SceneDelegate.swift` 与 `Info.plist` 的 `UIApplicationSceneManifest`
由 `cap add ios` 模板生成并保留。

## 2. 架构对照（Android → iOS）

```
React/Vite 前端（src/ 原样复用）
  -> window.Capacitor.Plugins.FoliaNative（插件名、方法名、参数、返回结构一致）
  -> iOS: FoliaNativePlugin.swift
       - Cookie:   FoliaCookieJar（JSON 持久化 + WKHTTPCookieStore 镜像）
       - HTTP:     URLSession（可选禁重定向、超时、Cookie 注入/回写）
       - 文件:     UIDocumentPickerViewController -> Documents/imported-audio
       - 音频流:   FoliaLocalAudioServer（127.0.0.1，支持 Range/HEAD/OPTIONS/CORS）
       - 锁屏:     FoliaMediaSession（AVAudioSession + MPNowPlayingInfoCenter + MPRemoteCommandCenter）
       - 诊断:     FoliaDiagnostics（Documents/diagnostics）
```

### 2.1 已实现的方法（与安卓 `FoliaNativePlugin.java` 同名）

| 分组 | 方法 |
| --- | --- |
| Cookie | `cookiesGetAll` / `cookiesGet` / `cookiesSet` / `cookiesRemove` / `cookiesRemoveBatch` |
| 网络 | `httpRequest` |
| 文件 | `pickAudioFiles` / `pickAudioFolder` / `deleteImportedAudio` |
| 本地音频 | `localAudioServerPort` / `registerRemoteAudio` |
| 媒体 | `updatePlaybackState` / `clearPlaybackState` / `mediaAction` 事件 |
| 系统 | `setKeepScreenOn` / `shareTextFile` / `moveTaskToBack` / `exitApp` |
| 布局 | `getPhoneFitLayout` / `setPhoneFitLayout` / `setAdaptiveLayout` / `getAdaptiveLayout` / `getDisplayCutout` |
| 诊断 | `getCrashDiagnostics` / `recordPlaybackHeartbeat` / `recordRuntimeDiagnostic` / `clearCrashDiagnostics` / `deleteDiagnosticFiles` / `getPlaybackDiagnostics` |
| 兼容空实现 | `scanLocalAudio`（iOS 无 MediaStore，返回空数组） |

### 2.2 iOS 上不可用 / 不等价的能力

- **设备音乐库扫描**：iOS 没有 Android MediaStore 的等价物（`MPMediaQuery` 只能读 Apple Music 资料库，且需用户额外授权）。本地音乐只通过「文件」App 导入副本。
- **退出应用 / 退到后台**：iOS 不允许程序化退出，两个方法都是空实现；回到桌面由系统负责。
- **挖孔 / 手机适配 / 沉浸式**：这些是 Android 窗口特性，iOS 上设置项自动隐藏，安全区由 `env(safe-area-inset-*)` 处理。
- **灵动岛/锁屏歌词**：当前只做到系统「正在播放」信息与基础控制，不做 ColorOS 式实时歌词。
- **后台音频**：已配置 `UIBackgroundModes: audio` + `AVAudioSession(.playback)`，但 WKWebView 在后台是否续播需要真机验证；若被系统挂起，后续需要原生 `AVPlayer` 接管。

## 3. 构建

### 3.1 GitHub Actions（推荐，当前 Windows 环境可用）

`.github/workflows/ios-ipa.yml` 会在 macOS runner 上：

1. `npm ci`
2. `npm run build:capacitor`
3. `npx cap sync ios`
4. `xcodebuild archive`（`CODE_SIGNING_ALLOWED=NO`）
5. 把 `.xcarchive` 里的 `App.app` 打成 `Payload/` 结构的 `Folia-unsigned.ipa`
6. 上传 artifact

触发方式：

- 推送到 `main` 且改动命中 `ios/**`、`src/**` 等路径；
- 或在 Actions 页面手动 `Run workflow`，runner 可选 `macos-26`（默认）或 `xcode-27`（preview）。

### 3.2 本地 macOS

```bash
npm ci
npm run build:capacitor
npx cap sync ios
npx cap open ios        # 用 Xcode 打开并配置签名
```

命令行未签名构建：

```bash
xcodebuild -project ios/App/App.xcodeproj -scheme App -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath build/App.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" archive
mkdir -p build/Payload && cp -R build/App.xcarchive/Products/Applications/App.app build/Payload/
cd build && zip -qry Folia-unsigned.ipa Payload
```

## 4. 安装到 iOS 27 真机

未签名 ipa 不能直接安装，必须签名。免费 Apple ID 的方案：

1. Windows 安装 [Sideloadly](https://sideloadly.io/)（或 AltStore），并准备 Apple ID；
2. 用 USB 连接 iPhone，把 `Folia-unsigned.ipa` 拖进 Sideloadly；
3. 输入 Apple ID 签名并安装（bundle id 保持 `top.izuna.foliamajor`）；
4. iPhone：设置 → 通用 → VPN 与设备管理 → 信任开发者证书；
5. 设置 → 隐私与安全性 → 开发者模式 → 打开并重启。

免费证书的有效期是 7 天，到期后需要重新签名安装；付费开发者账号可延长到 1 年。
如果使用付费证书，也可以直接用 Xcode 的 `Signing & Capabilities` 配置
`Team` 后 `Run` 到真机。

## 5. 验证清单

1. App 启动无白屏，设置页可打开；
2. 在线搜索与播放（网易云 / QQ / 酷狗任一）走原生 `httpRequest`；
3. 扫码/网页登录（Cookie 由 `FoliaCookieJar` 持有）；
4. 「文件」App 导入音频 → 列表出现 → 播放 → 拖动进度（Range）；
5. 锁屏/控制中心显示歌曲，播放/暂停/上一首/下一首有响应；
6. 退到后台 30 秒后是否续播（记录结果，当前不保证）；
7. 出问题时在设置里导出诊断数据（`Documents/diagnostics`）。

## 6. 已知风险

- **后台播放**：WKWebView 的音频在 App 进入后台后可能被 WebContent 进程挂起。当前只保证前台播放；若真机验证失败，需要在 `FoliaMediaSession` 旁边增加原生 `AVPlayer` 播放通道，并把播放进度回传给 JS（工作量较大，单独迭代）。
- **本地音频的跨源访问**：页面源是 `capacitor://localhost`，`<audio>` 请求 `http://127.0.0.1:<port>` 属于跨源，服务端已回 `Access-Control-Allow-Origin: *`；`Info.plist` 已加 `NSAllowsLocalNetworking`。若 iOS 27 收紧了混合内容策略，需要改为自定义 scheme 或 `AVPlayer` 方案。
- **内存**：iOS 的 WKWebView 内存上限比桌面低，3D 可视化在部分主题下可能触顶崩溃；先跑通最小版本，再按崩溃日志做视觉降级。
- **`xcode-27` runner 是 preview**：CI 默认 `macos-26`；需要 iOS 27 SDK 时手动选择 `xcode-27`，并接受它可能不稳定。
- **合法性与分发**：AGPL-3.0 要求提供源码；第三方音乐 API 与内容版权风险由使用者承担；不要提交到 App Store。

## 7. 开发约定

- 新增原生能力时，**先对齐 Android 的 `FoliaNativePlugin` 方法名与返回结构**，再实现 Swift 侧；JS 桥只认 `window.Capacitor.Plugins.FoliaNative`。
- 原生方法需要 `@objc`，并同时登记到 `pluginMethods`（`CAPPluginMethod(name:returnType:)`），否则 JSExport 不会暴露。
- 插件不在 `node_modules`，因此由 `FoliaBridgeViewController.capacitorDidLoad()` 显式 `registerPluginInstance`。
- 修改 `ios/App/App.xcodeproj/project.pbxproj` 增加 Swift 文件时，要同时补 `PBXBuildFile`、`PBXFileReference`、`PBXGroup`、`PBXSourcesBuildPhase` 四处。
