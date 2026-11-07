// src/services/localLibraryAvailability.ts
// Centralizes the secure-context requirement for browser local-library access.

export interface LocalLibraryAvailability {
  supported: boolean;
  reason: 'insecure-http' | 'file-system-api-unavailable' | null;
}

export const getLocalLibraryAvailability = (): LocalLibraryAvailability => {
  if (typeof window === 'undefined') return { supported: false, reason: 'file-system-api-unavailable' };
  if (window.electron) return { supported: true, reason: null };
  // 原生容器（Android/iOS）的本地曲库由 FoliaNative 插件负责：安卓走 SAF 与 MediaStore，
  // iOS 走 UIDocumentPicker + App 私有目录副本；WebView 本身没有 File System Access API。
  const platform = (window as any).Capacitor?.getPlatform?.();
  if (platform === 'android' || platform === 'ios') {
    return { supported: true, reason: null };
  }
  const currentLocation = window.location;
  if (!currentLocation) return { supported: false, reason: 'file-system-api-unavailable' };
  const isLocalhost = ['localhost', '127.0.0.1', '[::1]'].includes(currentLocation.hostname);
  if (!(currentLocation.protocol === 'https:' || isLocalhost) || !window.isSecureContext) {
    return { supported: false, reason: 'insecure-http' };
  }
  if (!('showDirectoryPicker' in window) || typeof navigator.storage?.getDirectory !== 'function') {
    return { supported: false, reason: 'file-system-api-unavailable' };
  }
  return { supported: true, reason: null };
};
