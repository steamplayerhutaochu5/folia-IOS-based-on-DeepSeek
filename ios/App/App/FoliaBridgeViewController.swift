import UIKit
import Capacitor

// src/ios/App/App/FoliaBridgeViewController.swift
// Capacitor 桥接控制器子类：在 WebView 完成初始化后注册 FoliaNative 插件。
//
// 自定义插件不在 node_modules 里，Capacitor 的自动注册（capacitor.config.json 的
// packageClassList）看不到它，因此必须在这里显式 registerPluginInstance。
// 顺便把 WebView 的交互细节调到与安卓容器一致（链接预览关闭、背景色对齐）。

class FoliaBridgeViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        bridge?.registerPluginInstance(FoliaNativePlugin())

        // App 启动、WebView 开始播放之前就配置好 AVAudioSession；
        // 不要在播放过程中重配，否则 iOS 27 会把 WebKit 的媒体会话判为 interrupted。
        FoliaMediaSession.shared.prepareForPlayback()

        webView?.allowsLinkPreview = false
        webView?.isOpaque = false
        webView?.backgroundColor = UIColor(red: 9.0 / 255.0, green: 9.0 / 255.0, blue: 11.0 / 255.0, alpha: 1.0)
        webView?.scrollView.backgroundColor = webView?.backgroundColor
        webView?.scrollView.bounces = true
        // App 背景固定 #09090b，状态栏用浅色文字；StatusBar 插件会按全局配置再设一次，
        // 这里与 viewDidAppear 一起兜底，避免因插件通知时序变成深色文字。
        statusBarStyle = .lightContent
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // super 里的 StatusBar 插件会把样式改成配置值（iOS 的 LIGHT = 深色文字），
        // 在深色背景上不可见；这里在插件之后覆盖回浅色。
        statusBarStyle = .lightContent
        setNeedsStatusBarAppearanceUpdate()
    }
}
