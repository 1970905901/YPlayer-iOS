import Foundation
import MediaPlayer
import UIKit

/// 播放信息数据模型 (遵循 write-swift 规范，值类型优先)
struct PlaybackStateInfo {
    let isPlaying: Bool
    let title: String
    let artist: String
    let album: String
    let artworkUrl: String
    let duration: Double
    let currentTime: Double
    let playbackRate: Double
}

/// 负责系统媒体中心 (MPNowPlayingInfoCenter) 及远程控制 (MPRemoteCommandCenter) 的管理
final class NowPlayingManager {
    static let shared = NowPlayingManager()

    /// 远端指令派发回调 (通知 WKWebView 中的音乐播放核心)
    var onCommandReceived: ((String, Double?) -> Void)?

    private var currentArtworkUrl: String?
    private var cachedArtwork: MPMediaItemArtwork?
    private var currentInfo = [String: Any]()

    private init() {
        setupRemoteCommands()
    }

    /// 设置 MPRemoteCommandCenter 锁屏控制命令
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.dispatchRemoteCommand("play")
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.dispatchRemoteCommand("pause")
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.dispatchRemoteCommand("togglePlayPause")
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.dispatchRemoteCommand("nextTrack")
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.dispatchRemoteCommand("previousTrack")
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let positionEvent = event as? MPChangePlaybackPositionCommandEvent {
                self?.dispatchRemoteCommand("changePlaybackPosition", arg: positionEvent.positionTime)
                return .success
            }
            return .commandFailed
        }
    }

    /// 向前端分发远程事件
    func dispatchRemoteCommand(_ command: String, arg: Double? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.onCommandReceived?(command, arg)
        }
    }

    /// 更新锁屏及控制中心播放信息
    func updateNowPlaying(info: PlaybackStateInfo) {
        var nowPlayingInfo = [String: Any]()

        nowPlayingInfo[MPMediaItemPropertyTitle] = info.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = info.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = info.album
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = info.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = info.currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = info.isPlaying ? (info.playbackRate > 0 ? info.playbackRate : 1.0) : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        // 复用已缓存的封面，避免重复网络加载
        if let cached = cachedArtwork, currentArtworkUrl == info.artworkUrl {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = cached
        }

        self.currentInfo = nowPlayingInfo
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo

        // 如果封面 URL 发生改变且不为空，后台异步请求封面图片
        if !info.artworkUrl.isEmpty && info.artworkUrl != currentArtworkUrl {
            loadArtwork(from: info.artworkUrl)
        }
    }

    /// 异步请求专辑封面图片并生成 MPMediaItemArtwork
    private func loadArtwork(from urlString: String) {
        currentArtworkUrl = urlString
        guard let url = URL(string: urlString) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self,
                  let data = data,
                  let image = UIImage(data: data),
                  error == nil else {
                return
            }

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.cachedArtwork = artwork

            DispatchQueue.main.async {
                if self.currentArtworkUrl == urlString {
                    self.currentInfo[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = self.currentInfo
                }
            }
        }.resume()
    }
}
