// src/services/nativeStatusBar.ts
//
// 状态栏文字颜色按平台校正。
//
// capacitor.config.json 里的 StatusBar.style 是全局值，两端语义相反：
//   Android：LIGHT = 浅色（深色背景上的白字）
//   iOS：    LIGHT = darkContent（深色文字），DARK = lightContent（浅色文字）
// App 背景固定为 #09090b，所以 iOS 必须在启动时显式改成 DARK，否则状态栏文字看不见。
import { Capacitor } from '@capacitor/core';
import { StatusBar, Style } from '@capacitor/status-bar';

export const installPlatformStatusBarStyle = (): void => {
    if (typeof window === 'undefined' || Capacitor.getPlatform() !== 'ios') return;
    // 深色背景 + 白色状态栏文字；关闭 overlaysWebView 让 WebView 从状态栏下方开始，
    // 避免 App 里大量的 fixed/absolute 全屏容器被状态栏压住。
    void StatusBar.setStyle({ style: Style.Dark }).catch(() => undefined);
    void StatusBar.setOverlaysWebView({ overlay: false }).catch(() => undefined);
};
