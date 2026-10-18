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
    private var pendingNowPlayingInfo: [String: Any]?
    private var artworkLoadTimeoutWorkItem: DispatchWorkItem?
    private var screenScale: CGFloat = 3.0

    private var baseArtist: String = ""
    private var baseTitle: String = ""
    private var currentLyric: String = ""
    private var isCurrentlyPlaying: Bool = false

    private init() {
        // 保持近期播放歌曲封面缓存 (30 首)，确保切歌与上下首秒出封面无空白延迟
        imageCache.countLimit = 30
        if Thread.isMainThread {
            self.screenScale = UIScreen.main.scale
        } else {
            DispatchQueue.main.async {
                self.screenScale = UIScreen.main.scale
            }
        }
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
        AudioSessionManager.shared.cancelRecoveryWorkItems()
        AudioSessionManager.shared.reactivateAudioSession()
        isCurrentlyPlaying = true
        var info = self.currentInfo
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        if let cached = cachedArtwork ?? (self.currentInfo[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork) {
            info[MPMediaItemPropertyArtwork] = cached
        }
        currentInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing
        dispatchRemoteCommand("play")
    }

    private func handleRemotePause() {
        isCurrentlyPlaying = false
        var info = self.currentInfo
        info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        if let cached = cachedArtwork ?? (self.currentInfo[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork) {
            info[MPMediaItemPropertyArtwork] = cached
        }
        currentInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .paused
        AudioSessionManager.shared.scheduleInterruptionRecovery()
        scheduleDelayedReassert()
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
        var info = self.currentInfo
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        if let cached = cachedArtwork ?? (self.currentInfo[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork) {
            info[MPMediaItemPropertyArtwork] = cached
        }
        currentInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        dispatchRemoteCommand("changePlaybackPosition", arg: position)
    }

    /// 当被其他应用或系统打断播放时调用：保持控制中心存在，展示暂停状态
    func handleInterruptionBegan() {
        print("[NowPlayingManager] 处理音频打断开始，更新控制中心为暂停状态")
        isCurrentlyPlaying = false
        var info = self.currentInfo
        info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        if let cached = cachedArtwork ?? (self.currentInfo[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork) {
            info[MPMediaItemPropertyArtwork] = cached
        }
        currentInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .paused
        enforceRemoteCommands()
        scheduleDelayedReassert()
        dispatchRemoteCommand("pause")
    }

    /// 当音频打断结束时调用：维持控制中心暂停状态与元数据，支持用户点击继续播放
    func handleInterruptionEnded(shouldResume: Bool) {
        print("[NowPlayingManager] 处理音频打断结束，维持控制中心信息，保持暂停状态，shouldResume: \(shouldResume)")
        isCurrentlyPlaying = false
        enforceRemoteCommands()
        var info = self.currentInfo
        info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        if let cached = cachedArtwork ?? (self.currentInfo[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork) {
            info[MPMediaItemPropertyArtwork] = cached
        }
        currentInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .paused
    }

    /// 确保当前歌曲元数据与控制中心同步（音频服务重置或应用激活时使用）
    func reassertNowPlayingInfo() {
        guard !currentInfo.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.enforceRemoteCommands()
            var info = self.currentInfo
            info[MPNowPlayingInfoPropertyPlaybackRate] = self.isCurrentlyPlaying ? 1.0 : 0.0
            info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
            info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
            info[MPNowPlayingInfoPropertyIsLiveStream] = false
            if let cached = self.cachedArtwork ?? (self.currentInfo[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork) {
                info[MPMediaItemPropertyArtwork] = cached
            }
            self.currentInfo = info
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            MPNowPlayingInfoCenter.default().playbackState = self.isCurrentlyPlaying ? .playing : .paused
        }
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

            // 若当前正在等待封面加载，仅更新暂存字典，绝不提前向系统推送无封面元数据
            if var pending = self.pendingNowPlayingInfo {
                pending[MPMediaItemPropertyArtist] = trimmed
                if let currentTime = currentTime, currentTime >= 0 {
                    pending[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
                }
                if let duration = duration, duration > 0 {
                    pending[MPMediaItemPropertyPlaybackDuration] = duration
                }
                self.pendingNowPlayingInfo = pending
                return
            }

            var info = self.currentInfo
            if !self.baseTitle.isEmpty {
                let combinedTitle = self.baseArtist.isEmpty ? self.baseTitle : "\(self.baseTitle) - \(self.baseArtist)"
                info[MPMediaItemPropertyTitle] = combinedTitle
            }
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
            if let cached = self.cachedArtwork ?? (self.currentInfo[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork) {
                info[MPMediaItemPropertyArtwork] = cached
            }
            self.currentInfo = info
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            MPNowPlayingInfoCenter.default().playbackState = self.isCurrentlyPlaying ? .playing : .paused
        }
    }

    /// 更新锁屏及控制中心播放信息
    func updateNowPlaying(info: PlaybackStateInfo) {
        if info.isPlaying {
            AudioSessionManager.shared.cancelRecoveryWorkItems()
            AudioSessionManager.shared.reactivateAudioSession()
        } else {
            AudioSessionManager.shared.scheduleInterruptionRecovery()
        }
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
        let duration = info.duration > 0 ? info.duration : (self.currentInfo[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0.0)
        if duration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, info.currentTime)
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = info.isPlaying ? (info.playbackRate > 0 ? info.playbackRate : 1.0) : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        // 显式声明媒体类型为 Audio 并声明非直播流，激活 iOS 16/17/18 灵动岛 (Dynamic Island) 实时活动与波形动画
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = false

        // 规范化封面 URL (转 https，替换 1024/800 为标准 500y500)
        let cleanArtworkUrl = sanitizeArtworkUrl(info.artworkUrl)

        // Case 1: 歌曲没有封面
        if cleanArtworkUrl.isEmpty {
            artworkLoadTimeoutWorkItem?.cancel()
            artworkLoadTimeoutWorkItem = nil
            pendingNowPlayingInfo = nil
            self.currentInfo = nowPlayingInfo
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            MPNowPlayingInfoCenter.default().playbackState = info.isPlaying ? .playing : .paused
            if !info.isPlaying {
                scheduleDelayedReassert()
            }
            return
        }

        // Case 2: 正在等待这首歌曲的封面异步下载中
        if pendingNowPlayingInfo != nil, cleanArtworkUrl == currentArtworkUrl {
            // 只更新 pendingNowPlayingInfo 中的最新播放进度和状态，坚决不向系统泄露无封面元数据
            self.pendingNowPlayingInfo = nowPlayingInfo
            return
        }

        // Case 3: 同一首歌曲且封面已有缓存
        if cleanArtworkUrl == currentArtworkUrl, let cached = cachedArtwork ?? (self.currentInfo[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork) {
            artworkLoadTimeoutWorkItem?.cancel()
            artworkLoadTimeoutWorkItem = nil
            pendingNowPlayingInfo = nil
            cachedArtwork = cached
            nowPlayingInfo[MPMediaItemPropertyArtwork] = cached
            self.currentInfo = nowPlayingInfo
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            MPNowPlayingInfoCenter.default().playbackState = info.isPlaying ? .playing : .paused
            if !info.isPlaying {
                scheduleDelayedReassert()
            }
            return
        }

        // Case 4: 新歌曲或封面 URL 改变
        currentArtworkUrl = cleanArtworkUrl
        cachedArtwork = nil

        // 检查内存图片缓存
        if let cachedImage = imageCache.object(forKey: cleanArtworkUrl as NSString) {
            artworkLoadTimeoutWorkItem?.cancel()
            artworkLoadTimeoutWorkItem = nil
            pendingNowPlayingInfo = nil
            let artwork = createArtwork(from: cachedImage)
            cachedArtwork = artwork
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
            self.currentInfo = nowPlayingInfo
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            MPNowPlayingInfoCenter.default().playbackState = info.isPlaying ? .playing : .paused
            if !info.isPlaying {
                scheduleDelayedReassert()
            }
            return
        }

        // Case 5: 新歌曲且未缓存封面 -> 绝对原子等待
        // 暂存 pendingNowPlayingInfo，坚决不在封面就绪前向系统推送无封面元数据！
        artworkLoadTimeoutWorkItem?.cancel()
        self.pendingNowPlayingInfo = nowPlayingInfo

        // 设置 1.2 秒保底超时：若极端网络超时/离线，则保底推送无封面元数据，确保播放控制手势可用
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self = self, let pending = self.pendingNowPlayingInfo else { return }
            print("[NowPlayingManager] 封面下载超时，保底推送播放信息")
            self.pendingNowPlayingInfo = nil
            self.currentInfo = pending
            MPNowPlayingInfoCenter.default().nowPlayingInfo = pending
            MPNowPlayingInfoCenter.default().playbackState = self.isCurrentlyPlaying ? .playing : .paused
            if !self.isCurrentlyPlaying {
                self.scheduleDelayedReassert()
            }
        }
        self.artworkLoadTimeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: timeoutWorkItem)

        // 启动异步下载
        loadArtwork(from: cleanArtworkUrl, isPreload: false)
    }

    /// 延迟重申，确保覆盖 WebKit 异步暂停可能带来的媒体中心清空
    func scheduleDelayedReassert() {
        let delays = [0.15, 0.45]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.isCurrentlyPlaying, !self.currentInfo.isEmpty else { return }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = self.currentInfo
                MPNowPlayingInfoCenter.default().playbackState = .paused
            }
        }
    }

    /// 规范化封面图片 URL
    private func sanitizeArtworkUrl(_ urlString: String) -> String {
        var clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.lowercased().hasPrefix("http://") {
            clean = "https://" + clean.dropFirst(7)
        }
        clean = clean.replacingOccurrences(of: "param=1024y1024", with: "param=500y500")
        clean = clean.replacingOccurrences(of: "param=800y800", with: "param=500y500")
        return clean
    }

    /// 预加载下一首歌曲封面至原生内存缓存，确保切歌瞬间封面 0 延迟秒现
    func preloadArtwork(from urlString: String) {
        let clean = sanitizeArtworkUrl(urlString)
        guard !clean.isEmpty else { return }
        if imageCache.object(forKey: clean as NSString) != nil {
            return
        }
        loadArtwork(from: clean, isPreload: true)
    }

    /// 构造具备动态尺寸适配与无损高清渲染能力的 MPMediaItemArtwork
    private func createArtwork(from image: UIImage) -> MPMediaItemArtwork {
        return MPMediaItemArtwork(boundsSize: image.size) { requestedSize in
            guard requestedSize.width > 0 && requestedSize.height > 0 else {
                return image
            }
            if abs(requestedSize.width - image.size.width) < 1 && abs(requestedSize.height - image.size.height) < 1 {
                return image
            }
            let renderer = UIGraphicsImageRenderer(size: requestedSize)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: requestedSize))
            }
        }
    }

    /// 异步请求专辑封面图片并生成 MPMediaItemArtwork
    private func loadArtwork(from urlString: String, isPreload: Bool = false) {
        let cleanUrlString = sanitizeArtworkUrl(urlString)
        if !isPreload {
            currentArtworkUrl = cleanUrlString
        }

        // 检查内存缓存
        if let cachedImage = imageCache.object(forKey: cleanUrlString as NSString) {
            if !isPreload {
                applyArtwork(cachedImage, for: cleanUrlString)
            }
            return
        }

        // 1. 支持 base64 Data URL (本地导入或插件音乐封面)
        if cleanUrlString.hasPrefix("data:image/") {
            if let commaIndex = cleanUrlString.firstIndex(of: ",") {
                let base64String = String(cleanUrlString[cleanUrlString.index(after: commaIndex)...])
                if let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
                   let image = UIImage(data: data) {
                    imageCache.setObject(image, forKey: cleanUrlString as NSString)
                    if !isPreload {
                        applyArtwork(image, for: cleanUrlString)
                    }
                    return
                }
            }
        }

        // 2. 支持本地文件路径
        if cleanUrlString.hasPrefix("file://"), let fileUrl = URL(string: cleanUrlString) {
            if let image = UIImage(contentsOfFile: fileUrl.path) {
                imageCache.setObject(image, forKey: cleanUrlString as NSString)
                if !isPreload {
                    applyArtwork(image, for: cleanUrlString)
                }
                return
            }
        } else if cleanUrlString.hasPrefix("/") && FileManager.default.fileExists(atPath: cleanUrlString) {
            if let image = UIImage(contentsOfFile: cleanUrlString) {
                imageCache.setObject(image, forKey: cleanUrlString as NSString)
                if !isPreload {
                    applyArtwork(image, for: cleanUrlString)
                }
                return
            }
        }

        // 3. 网络请求
        guard let url = URL(string: cleanUrlString) ?? URL(string: cleanUrlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            print("[NowPlayingManager] 封面 URL 解析失败: \(urlString)")
            return
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")

        // 仅网易云域名附带 163.com Referer，避免第三方 CDN (QQ音乐、B站、酷狗等) 报 403/404 防盗链错误
        if let host = url.host?.lowercased(), host.contains("163.com") || host.contains("126.net") {
            request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        }

        // 优先请求标准 JPEG / PNG 格式，确保 UIImage(data:) 100% 成功解码
        request.setValue("image/jpeg,image/png,image/*;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                print("[NowPlayingManager] 封面网络请求失败: \(error.localizedDescription), URL: \(urlString)")
                return
            }
            guard let data = data, let image = UIImage(data: data) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[NowPlayingManager] 封面图片解码失败, 状态码: \(statusCode), 数据长度: \(data?.count ?? 0), URL: \(urlString)")
                return
            }

            self.imageCache.setObject(image, forKey: cleanUrlString as NSString)

            DispatchQueue.main.async {
                if !isPreload || self.currentArtworkUrl == cleanUrlString {
                    self.applyArtwork(image, for: cleanUrlString)
                }
            }
        }.resume()
    }

    /// 应用封面并通知系统媒体中心
    private func applyArtwork(_ image: UIImage, for urlString: String) {
        guard currentArtworkUrl == urlString else { return }

        artworkLoadTimeoutWorkItem?.cancel()
        artworkLoadTimeoutWorkItem = nil

        let artwork = createArtwork(from: image)
        cachedArtwork = artwork

        // 如果存在 pendingNowPlayingInfo，合并封面并向系统首次原子发布完整元数据
        var info = pendingNowPlayingInfo ?? currentInfo
        pendingNowPlayingInfo = nil

        info[MPMediaItemPropertyArtwork] = artwork
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        info[MPNowPlayingInfoPropertyPlaybackRate] = isCurrentlyPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        currentInfo = info

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isCurrentlyPlaying ? .playing : .paused
    }

    /// 清除所有封面图片缓存，响应整软件资源缓存清理或不缓存策略
    func clearArtworkCache() {
        artworkLoadTimeoutWorkItem?.cancel()
        artworkLoadTimeoutWorkItem = nil
        pendingNowPlayingInfo = nil
        imageCache.removeAllObjects()
        cachedArtwork = nil
        currentArtworkUrl = nil
    }
}
