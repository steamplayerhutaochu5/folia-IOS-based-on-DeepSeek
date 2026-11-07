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

        webView?.allowsLinkPreview = false
        webView?.isOpaque = false
        webView?.backgroundColor = UIColor(red: 9.0 / 255.0, green: 9.0 / 255.0, blue: 11.0 / 255.0, alpha: 1.0)
        webView?.scrollView.backgroundColor = webView?.backgroundColor
        webView?.scrollView.bounces = true
    }
}
