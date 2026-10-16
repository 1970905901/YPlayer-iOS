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

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let positionEvent = event as? MPChangePlaybackPositionCommandEvent {
                self?.dispatchRemoteCommand("changePlaybackPosition", arg: positionEvent.positionTime)
                return .success
            }
            return .commandFailed
        }

        enforceRemoteCommands()
    }

    /// 强制校准控制中心按钮：彻底禁用 15 秒快进快退，启用标准的上一首/下一首按钮
    private func enforceRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // 彻底停用快进/快退区间指令 (15s)，清空首选间隔
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.preferredIntervals = []
        commandCenter.skipBackwardCommand.preferredIntervals = []
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false

        commandCenter.seekForwardCommand.removeTarget(nil)
        commandCenter.seekBackwardCommand.removeTarget(nil)
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false

        // 强力启用上一首与下一首指令并挂载原生事件
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.dispatchRemoteCommand("previousTrack")
            return .success
        }

        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.dispatchRemoteCommand("nextTrack")
            return .success
        }
    }

    /// 向前端分发远程事件
    func dispatchRemoteCommand(_ command: String, arg: Double? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.onCommandReceived?(command, arg)
        }
    }

    private var baseArtist: String = ""
    private var baseTitle: String = ""
    private var currentLyric: String = ""

    /// 更新锁屏、控制中心与灵动岛实时单句歌词及同步播放进度
    func updateLyric(text: String, currentTime: Double? = nil, duration: Double? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentLyric = trimmed

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? self.currentInfo
            info[MPMediaItemPropertyArtist] = trimmed
            if let currentTime = currentTime, currentTime >= 0 {
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            }
            if let duration = duration, duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }
            info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
            self.currentInfo = info
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// 更新锁屏及控制中心播放信息
    func updateNowPlaying(info: PlaybackStateInfo) {
        baseArtist = info.artist
        baseTitle = info.title
        currentLyric = ""

        enforceRemoteCommands()

        var nowPlayingInfo = [String: Any]()

        // 将歌手名放置在歌曲名后面（同字号、同粗细、同颜色显示在标题行）
        let combinedTitle = info.artist.isEmpty ? info.title : "\(info.title) - \(info.artist)"
        nowPlayingInfo[MPMediaItemPropertyTitle] = combinedTitle
        nowPlayingInfo[MPMediaItemPropertyArtist] = "" // 专属预留给动态滚动的单句歌词
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
                    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? self.currentInfo
                    info[MPMediaItemPropertyArtwork] = artwork
                    self.currentInfo = info
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        }.resume()
    }
}
