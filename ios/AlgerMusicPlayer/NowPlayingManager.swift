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
    private let imageCache = NSCache<NSString, UIImage>()
    private var currentInfo = [String: Any]()

    private var baseArtist: String = ""
    private var baseTitle: String = ""
    private var currentLyric: String = ""
    private var isCurrentlyPlaying: Bool = false

    private init() {
        setupRemoteCommands()
    }

    /// 设置 MPRemoteCommandCenter 锁屏、控制中心与灵动岛控制命令
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // 彻底停用快进/快退区间指令 (15s)，杜绝控制中心显示 15s 按钮
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

        // 彻底停用 stopCommand 避免与播放/暂停产生语义竞争
        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.stopCommand.isEnabled = false

        // 启用上一首
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.dispatchRemoteCommand("previousTrack")
            return .success
        }

        // 启用下一首
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.dispatchRemoteCommand("nextTrack")
            return .success
        }

        // 启用播放指令 (立即乐观更新 playbackRate 为 1.0，保证控制中心瞬时响应)
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.handleRemotePlay()
            return .success
        }

        // 启用暂停指令 (立即乐观更新 playbackRate 为 0.0，保证控制中心瞬时响应)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.handleRemotePause()
            return .success
        }

        // 启用播放/暂停切换指令 (控制中心和耳机按键的单键切换核心指令)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleRemoteToggle()
            return .success
        }

        // 启用播放进度拖动指令
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let positionEvent = event as? MPChangePlaybackPositionCommandEvent {
                self?.handleRemoteSeek(to: positionEvent.positionTime)
                return .success
            }
            return .commandFailed
        }

        enforceRemoteCommands()
    }

    /// 强制校准控制中心按钮状态：彻底禁用 15 秒快进快退，确保上一首/下一首/播放/暂停/切换始终处于可用状态
    private func enforceRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.skipForwardCommand.preferredIntervals = []
        commandCenter.skipBackwardCommand.preferredIntervals = []
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.stopCommand.isEnabled = false

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
    }

    private func handleRemotePlay() {
        isCurrentlyPlaying = true
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? currentInfo
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        currentInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        dispatchRemoteCommand("play")
    }

    private func handleRemotePause() {
        isCurrentlyPlaying = false
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? currentInfo
        info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        currentInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        dispatchRemoteCommand("pause")
    }

    private func handleRemoteToggle() {
        if isCurrentlyPlaying {
            handleRemotePause()
        } else {
            handleRemotePlay()
        }
    }

    private func handleRemoteSeek(to position: Double) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? currentInfo
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        currentInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        dispatchRemoteCommand("changePlaybackPosition", arg: position)
    }

    /// 向前端分发远程事件
    func dispatchRemoteCommand(_ command: String, arg: Double? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.onCommandReceived?(command, arg)
        }
    }

    /// 更新锁屏、控制中心与灵动岛实时单句歌词及同步播放进度
    func updateLyric(text: String, currentTime: Double? = nil, duration: Double? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentLyric = trimmed

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? self.currentInfo
            info[MPMediaItemPropertyArtist] = trimmed
            info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
            info[MPNowPlayingInfoPropertyIsLiveStream] = false
            if let currentTime = currentTime, currentTime >= 0 {
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            }
            if let duration = duration, duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }
            info[MPNowPlayingInfoPropertyPlaybackRate] = self.isCurrentlyPlaying ? 1.0 : 0.0
            info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
            if let cached = self.cachedArtwork {
                info[MPMediaItemPropertyArtwork] = cached
            }
            self.currentInfo = info
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// 更新锁屏及控制中心播放信息
    func updateNowPlaying(info: PlaybackStateInfo) {
        baseArtist = info.artist
        baseTitle = info.title
        currentLyric = ""
        isCurrentlyPlaying = info.isPlaying

        enforceRemoteCommands()

        var nowPlayingInfo = [String: Any]()

        // 将歌手名放置在歌曲名后面（同字号、同粗细、同颜色显示在标题行）
        let combinedTitle = info.artist.isEmpty ? info.title : "\(info.title) - \(info.artist)"
        nowPlayingInfo[MPMediaItemPropertyTitle] = combinedTitle

        // 副标题展示：若当前有歌词则展示歌词，否则展示歌手名（或空格防空），确保 MediaPlayer 元数据完整不被系统置灰
        let displayArtist = currentLyric.isEmpty ? (info.artist.isEmpty ? " " : info.artist) : currentLyric
        nowPlayingInfo[MPMediaItemPropertyArtist] = displayArtist

        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = info.album
        if info.duration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = info.duration
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, info.currentTime)
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = info.isPlaying ? (info.playbackRate > 0 ? info.playbackRate : 1.0) : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        // 显式声明媒体类型为 Audio 并声明非直播流，激活 iOS 16/17/18 灵动岛 (Dynamic Island) 实时活动与波形动画
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = false

        // 如果封面 URL 发生改变且不为空，清空旧封面并请求新封面图片
        if info.artworkUrl.isEmpty {
            cachedArtwork = nil
            currentArtworkUrl = nil
        } else if info.artworkUrl != currentArtworkUrl {
            currentArtworkUrl = info.artworkUrl
            // 检查内存图片缓存，若已存在则直接构造 Artwork 避免空白与延迟
            if let cachedImage = imageCache.object(forKey: info.artworkUrl as NSString) {
                cachedArtwork = createArtwork(from: cachedImage)
            } else {
                cachedArtwork = nil
                loadArtwork(from: info.artworkUrl)
            }
        }

        // 复用已缓存的封面，避免重复网络加载，新封面加载完成后会自动无缝替换
        if let cached = cachedArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = cached
        }

        self.currentInfo = nowPlayingInfo
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    /// 构造具备无损高清渲染能力的 MPMediaItemArtwork
    private func createArtwork(from image: UIImage) -> MPMediaItemArtwork {
        return MPMediaItemArtwork(boundsSize: image.size) { _ in
            // 返回无损高清图片，由 iOS 系统根据显示场景（锁屏全屏放大、控制中心小卡片、灵动岛）
            // 自动进行高质量 GPU 抗锯齿超采样渲染，彻底解决锁屏放大或灵动岛封面模糊、不清晰的问题
            return image
        }
    }

    /// 异步请求专辑封面图片并生成 MPMediaItemArtwork
    private func loadArtwork(from urlString: String) {
        currentArtworkUrl = urlString
        let secureUrlString = urlString.replacingOccurrences(of: "^http://", with: "https://", options: .regularExpression)
        guard let url = URL(string: secureUrlString) else { return }

        // 检查内存缓存
        if let cachedImage = imageCache.object(forKey: urlString as NSString) {
            applyArtwork(cachedImage, for: urlString)
            return
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self,
                  let data = data,
                  let image = UIImage(data: data),
                  error == nil else {
                return
            }

            self.imageCache.setObject(image, forKey: urlString as NSString)

            DispatchQueue.main.async {
                self.applyArtwork(image, for: urlString)
            }
        }.resume()
    }

    /// 应用封面并通知系统媒体中心
    private func applyArtwork(_ image: UIImage, for urlString: String) {
        guard currentArtworkUrl == urlString else { return }
        let artwork = createArtwork(from: image)
        cachedArtwork = artwork

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? currentInfo
        info[MPMediaItemPropertyArtwork] = artwork
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        currentInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // 触发一次轻量延迟刷新，确保 SpringBoard 立即捕获新封面，无论折叠还是展开均完整同步
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.currentArtworkUrl == urlString else { return }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = self.currentInfo
        }
    }
}
