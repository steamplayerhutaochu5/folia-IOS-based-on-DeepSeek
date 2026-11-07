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
    }

    /// 激活后台音频会话；失败不抛给 JS —— 前台播放不该因为锁屏权限失败而中断。
    func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            // 静默失败：调用方只关心界面上的播放状态。
        }
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
        activateAudioSession()

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
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused

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
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
