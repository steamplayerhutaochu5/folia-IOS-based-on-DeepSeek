import Foundation
import AVFoundation
import MediaPlayer
import UIKit

// src/ios/App/App/FoliaMediaSession.swift
// 锁屏 / 控制中心的「正在播放」与远程控制。
//
// 安卓版是 FoliaPlaybackService（前台服务 + MediaSession + 通知栏）；
// iOS 的等价物是 AVAudioSession(.playback) + MPNowPlayingInfoCenter + MPRemoteCommandCenter。
// 这里只桥接元数据与按钮事件，音频仍由 WebView 的 <audio> 播放：
// 按钮事件通过 CAPPlugin.notifyListeners("mediaAction", ...) 回到 JS，
// 和安卓的 emitMediaAction 使用同一个事件名与 action 取值（play/pause/next/previous）。

final class FoliaMediaSession {
    static let shared = FoliaMediaSession()

    weak var plugin: FoliaNativePlugin?

    private var commandsConfigured = false
    private var audioSessionConfigured = false
    private var interruptionObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var artworkTask: URLSessionDataTask?
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var currentCoverURL = ""
    private var lastPositionSeconds: Double = 0
    private var lastDurationSeconds: Double = 0
    private var lastPlaying = false
    private var lastTitle = ""
    private var lastArtist = ""
    private var lastAlbum = ""

    private init() {}

    func configure() {
        guard !commandsConfigured else { return }
        commandsConfigured = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.emit("play")
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.emit("pause")
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.emit("toggle")
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.emit("next")
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.emit("previous")
            return .success
        }
        center.stopCommand.isEnabled = true
        center.stopCommand.addTarget { [weak self] _ in
            self?.emit("stop")
            return .success
        }

        observeAudioSession()
    }

    /**
     * AVAudioSession 被电话/Siri/其他 App 中断后不会自己回到 active；
     * WKWebView 的 AudioContext 会一直停在 `interrupted`（有声音缓冲但没有输出、进度不走）。
     * 这里在中断结束与 App 回前台时重新激活会话，并通知 JS 恢复 AudioContext。
     */
    private func observeAudioSession() {
        let center = NotificationCenter.default
        if interruptionObserver == nil {
            interruptionObserver = center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    self.audioSessionConfigured = false
                case .ended:
                    self.audioSessionConfigured = false
                    self.activateAudioSession()
                    self.notifyAudioSessionResumed()
                @unknown default:
                    break
                }
            }
        }
        if activationObserver == nil {
            // 不再监听 didBecomeActive：回前台时重新 setCategory/setActive 会让
            // WebKit 的媒体会话进入 interrupted（iOS 27 上表现为播放几秒后自动暂停）。
            // 中断恢复交给下面的 interruptionNotification；普通前后台切换由 WebKit 自己恢复。
            activationObserver = nil
        }
    }

    private func notifyAudioSessionResumed() {
        DispatchQueue.main.async { [weak self] in
            self?.plugin?.notifyListeners("mediaAction", data: ["action": "audio-session-resumed"])
        }
    }

    /// 激活后台音频会话。
    ///
    /// 只在会话尚未配置时调用：`updatePlaybackState` 每秒都会走到这里，若每次都
    /// setCategory/setActive，iOS 会反复重配音频路由，WKWebView 的 AudioContext 随之
    /// 进入 interrupted，表现就是「音频在缓冲、播放键亮着，却没有声音、进度也不走」。
    func activateAudioSession() {
        guard !audioSessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            audioSessionConfigured = true
        } catch {
            // 静默失败：调用方只关心界面上的播放状态。
        }
    }

    /// App 启动、WebView 开始播放之前就配置好音频会话。
    ///
    /// 关键：不能在每次 updatePlaybackState（播放中每秒一次）里 setCategory/setActive ——
    /// iOS 27 的 WebKit 会因此把 Audio/WebAudio/DOMMediaSession 判为 interrupted，
    /// 音频播放几秒后自动暂停（真机 syslog 的 MediaSessionManageriOS dump 已确认）。
    func prepareForPlayback() {
        configure()
        activateAudioSession()
    }

    func update(
        title: String,
        artist: String,
        album: String,
        coverURL: String,
        playing: Bool,
        positionMs: Double,
        durationMs: Double
    ) {
        configure()

        lastTitle = title
        lastArtist = artist
        lastAlbum = album
        lastPlaying = playing
        lastPositionSeconds = max(0, positionMs / 1000.0)
        lastDurationSeconds = max(0, durationMs / 1000.0)

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? "Unknown Song" : title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album,
            MPMediaItemPropertyPlaybackDuration: lastDurationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: lastPositionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        if let artwork = artwork(for: coverURL) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // 不设置 MPNowPlayingInfoCenter.playbackState：签名包没有
        // com.apple.mediaremote.set-playback-state entitlement，iOS 27 会报错并可能
        // 干扰 WebKit 的媒体会话；playbackRate 已足以表达播放/暂停。

        if coverURL != currentCoverURL {
            currentCoverURL = coverURL
            loadArtwork(coverURL)
        }
    }

    func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        currentCoverURL = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        // 不在这里 setActive(false)：JS 在无歌/初始化时会调用 clear，停用会话会让
        // WKWebView 的 AudioContext 进入 interrupted，下一首歌就再也发不出声音。
        // 也不设置 playbackState（同上：无 entitlement）。
    }

    private func artwork(for url: String) -> MPMediaItemArtwork? {
        artworkCache[url]
    }

    private func loadArtwork(_ urlString: String) {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return }
        if artworkCache[urlString] != nil { return }
        artworkTask?.cancel()
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(FoliaLocalAudioServer.remoteUserAgentForArtwork, forHTTPHeaderField: "User-Agent")
        artworkTask = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data, let image = UIImage(data: data) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            DispatchQueue.main.async {
                self.artworkCache[urlString] = artwork
                // 只有当前还在放这一首时才补封面，避免切歌后旧封面覆盖新元数据。
                guard self.currentCoverURL == urlString else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
        artworkTask?.resume()
    }

    private func emit(_ action: String) {
        DispatchQueue.main.async { [weak self] in
            self?.plugin?.notifyListeners("mediaAction", data: ["action": action])
        }
    }
}

extension FoliaLocalAudioServer {
    static let remoteUserAgentForArtwork =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
}
