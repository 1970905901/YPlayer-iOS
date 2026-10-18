import Foundation
import MediaPlayer
import UIKit

/// 播放信息数据模型（值类型，避免跨线程共享可变状态）
struct PlaybackStateInfo {
    let isPlaying: Bool
    let title: String
    let artist: String
    let album: String
    let artworkUrl: String
    let duration: Double
    let currentTime: Double
    let playbackRate: Double
    /// 用户是否希望播放。系统打断造成的 pause 不会清除该意图。
    let userPlayIntent: Bool
    /// WKWebView 是否已提供 Media Session；此时 Now Playing 由 WebKit 单方持有。
    let mediaSessionAvailable: Bool
}

/// 负责系统媒体中心 (MPNowPlayingInfoCenter) 及远程控制 (MPRemoteCommandCenter) 的管理。
/// 所有对外状态更新都会收敛到主线程，并以 `currentInfo` 作为唯一状态源，
/// 避免和 WKWebView 的 Media Session 双写时读取到彼此尚未落定的中间状态。
final class NowPlayingManager {
    static let shared = NowPlayingManager()

    /// 远端指令派发回调（通知 WKWebView 中的音乐播放核心）
    var onCommandReceived: ((String, Double?) -> Void)?

    private let imageCache = NSCache<NSString, UIImage>()
    private var currentArtworkURL: String?
    private var loadingArtworkURL: String?
    private var cachedArtwork: MPMediaItemArtwork?
    private var pendingNowPlayingInfo: [String: Any]?
    private var artworkLoadTimeoutWorkItem: DispatchWorkItem?
    private var currentInfo = [String: Any]()

    private var baseArtist: String = ""
    private var baseTitle: String = ""
    private var currentLyric: String = ""
    private var currentTrackKey: String = ""
    private var currentPlaybackRate: Double = 1.0
    private var isCurrentlyPlaying: Bool = false
    private var pausedReassertWorkItem: DispatchWorkItem?
    private var shouldResumeAfterInterruption = false
    private var lastPlaybackIntent = false
    private var automaticResumeAttempts = 0
    private var webMediaSessionAvailable = false
    private let maxAutomaticResumeAttempts = 5

    /// 给音频会话恢复逻辑使用；仅表示当前仍有一首需要展示的歌曲。
    var hasActiveNowPlayingItem: Bool {
        !currentInfo.isEmpty || pendingNowPlayingInfo != nil
    }

    var isCurrentlyPlayingForAudioSession: Bool {
        isCurrentlyPlaying
    }

    /// 打断前正在播放、当前已暂停且仍有媒体项时，调度真实播放。
    /// 不在这里乐观改写播放状态：只有 WKWebView 真正恢复播放后才清除恢复意图。
    func resumeAfterInterruptionIfPossible() -> Bool {
        guard shouldResumeAfterInterruption, !isCurrentlyPlaying, hasActiveNowPlayingItem else {
            return false
        }
        guard automaticResumeAttempts < maxAutomaticResumeAttempts else {
            shouldResumeAfterInterruption = false
            return false
        }

        automaticResumeAttempts += 1
        lastPlaybackIntent = true
        pausedReassertWorkItem?.cancel()
        pausedReassertWorkItem = nil
        AudioSessionManager.shared.reactivateAudioSession()
        print("[NowPlayingManager] 调度打断恢复播放，第 \(automaticResumeAttempts) 次")
        dispatchRemoteCommand("play")
        return true
    }

    private init() {
        // 保持近期播放歌曲封面缓存（30 首），确保切歌与上下首秒出封面无空白延迟。
        imageCache.countLimit = 30
        imageCache.totalCostLimit = 64 * 1024 * 1024
        setupRemoteCommands()
    }

    // MARK: - Threading

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    // MARK: - Remote Commands

    /// 设置锁屏、控制中心与灵动岛控制命令。
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // 停用 15 秒快进/快退，避免系统以其替代上一首/下一首。
        // 即使控制隐藏，preferredIntervals 仍保留合法值，避免运行时异常。
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false

        commandCenter.seekForwardCommand.removeTarget(nil)
        commandCenter.seekBackwardCommand.removeTarget(nil)
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false

        // stop 会与播放/暂停产生语义竞争，始终由应用显式控制。
        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.stopCommand.isEnabled = false

        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self, self.onCommandReceived != nil else { return .commandFailed }
            self.dispatchRemoteCommand("previousTrack")
            return .success
        }

        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self, self.onCommandReceived != nil else { return .commandFailed }
            self.dispatchRemoteCommand("nextTrack")
            return .success
        }

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self, self.onCommandReceived != nil else { return .commandFailed }
            self.onMain { self.handleRemotePlay() }
            return .success
        }

        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self, self.onCommandReceived != nil else { return .commandFailed }
            self.onMain { self.handleRemotePause() }
            return .success
        }

        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self, self.onCommandReceived != nil else { return .commandFailed }
            self.onMain { self.handleRemoteToggle() }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  self.onCommandReceived != nil,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.onMain { self.handleRemoteSeek(to: positionEvent.positionTime) }
            return .success
        }

        enforceRemoteCommands()
    }

    /// 统一校准控制中心按钮状态。
    private func enforceRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        let hasItem = !currentInfo.isEmpty || pendingNowPlayingInfo != nil

        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.stopCommand.isEnabled = false

        commandCenter.previousTrackCommand.isEnabled = hasItem
        commandCenter.nextTrackCommand.isEnabled = hasItem
        commandCenter.playCommand.isEnabled = hasItem
        commandCenter.pauseCommand.isEnabled = hasItem
        commandCenter.togglePlayPauseCommand.isEnabled = hasItem
        commandCenter.changePlaybackPositionCommand.isEnabled = hasItem
    }

    private func handleRemotePlay() {
        pausedReassertWorkItem?.cancel()
        pausedReassertWorkItem = nil
        shouldResumeAfterInterruption = false
        automaticResumeAttempts = 0
        lastPlaybackIntent = true
        AudioSessionManager.shared.cancelPausedItemRecovery()
        let wasPlaying = isCurrentlyPlaying
        isCurrentlyPlaying = true
        if !wasPlaying {
            AudioSessionManager.shared.reactivateAudioSession()
        }
        publishCurrentInfo()
        dispatchRemoteCommand("play")
    }

    private func handleRemotePause() {
        shouldResumeAfterInterruption = false
        automaticResumeAttempts = 0
        lastPlaybackIntent = false
        isCurrentlyPlaying = false
        publishCurrentInfo()
        schedulePausedStateReassert()
        AudioSessionManager.shared.schedulePausedItemRecovery()
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
        guard position.isFinite else { return }
        var target = max(0, position)
        var info = pendingNowPlayingInfo ?? currentInfo
        if let duration = info[MPMediaItemPropertyPlaybackDuration] as? Double, duration > 0 {
            target = min(target, duration)
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = target
        if pendingNowPlayingInfo != nil {
            pendingNowPlayingInfo = info
        } else {
            currentInfo = info
            publishCurrentInfo()
        }
        dispatchRemoteCommand("changePlaybackPosition", arg: target)
    }

    /// 当被其他应用或系统打断播放时调用：暂停并保持控制中心中的歌曲信息。
    func handleInterruptionBegan(allowAutoResume: Bool = true) {
        onMain { [weak self] in
            guard let self = self else { return }
            // WKWebView 可能先因打断收到 pause，再收到 AVAudioSession 通知。
            // lastPlaybackIntent 能保留“用户原本要播放”的事实，避免漏掉自动恢复。
            let wasPlayingBeforeInterruption = self.isCurrentlyPlaying || self.lastPlaybackIntent
            if allowAutoResume {
                // 同一次打断可能重复上报 began；不能把第一次记录的恢复意图覆盖成 false。
                self.shouldResumeAfterInterruption = self.shouldResumeAfterInterruption
                    || wasPlayingBeforeInterruption
                self.automaticResumeAttempts = 0
            } else {
                self.shouldResumeAfterInterruption = false
                self.automaticResumeAttempts = 0
                self.lastPlaybackIntent = false
            }
            self.isCurrentlyPlaying = false
            self.publishCurrentInfo()
            self.schedulePausedStateReassert()
            if self.hasActiveNowPlayingItem {
                // 区分系统打断与用户暂停：前者保留播放意图，打断结束后才能自动恢复。
                self.dispatchRemoteCommand(allowAutoResume ? "interruptionPause" : "pause")
            }
        }
    }

    /// 音频打断结束：系统允许恢复时自动继续播放，否则保持暂停卡片等待用户操作。
    func handleInterruptionEnded(shouldResume: Bool) {
        onMain { [weak self] in
            guard let self = self else { return }

            // 用户在打断期间已经手动恢复，或 WebKit 已自行恢复时，不要把状态改回暂停。
            if self.isCurrentlyPlaying {
                self.shouldResumeAfterInterruption = false
                self.publishCurrentInfo()
                return
            }

            // 以用户真实播放意图为主；系统 shouldResume 仅作为诊断信息。
            let canResume = self.shouldResumeAfterInterruption

            if canResume, self.resumeAfterInterruptionIfPossible() {
                print("[NowPlayingManager] 音频打断结束，调度恢复真实播放（系统建议: \(shouldResume)）")
                return
            }

            self.shouldResumeAfterInterruption = false
            self.isCurrentlyPlaying = false
            self.publishCurrentInfo()
            self.schedulePausedStateReassert()
            print("[NowPlayingManager] 音频打断结束，保持控制中心暂停状态（系统建议恢复: \(shouldResume)）")
        }
    }

    /// 重新发布当前状态（音频服务重置、应用回到前台时使用）。
    /// 不在这里反复激活/配置 AVAudioSession，避免打断正在运行的 WKWebView 音频。
    func reassertNowPlayingInfo() {
        onMain { [weak self] in
            guard let self = self, !self.currentInfo.isEmpty else { return }
            self.enforceRemoteCommands()
            self.publishCurrentInfo()
        }
    }

    /// 向前端分发远程事件。
    func dispatchRemoteCommand(_ command: String, arg: Double? = nil) {
        onMain { [weak self] in
            self?.onCommandReceived?(command, arg)
        }
    }

    // MARK: - Now Playing State

    /// 更新锁屏、控制中心及灵动岛的播放信息。
    func updateNowPlaying(info: PlaybackStateInfo) {
        onMain { [weak self] in
            self?.applyNowPlaying(info)
        }
    }

    private func applyNowPlaying(_ info: PlaybackStateInfo) {
        let title = normalizedText(info.title, fallback: "未知曲目")
        let artist = normalizedText(info.artist, fallback: "")
        let album = normalizedText(info.album, fallback: "")
        let artworkURL = sanitizeArtworkUrl(info.artworkUrl)

        let duration = info.duration.isFinite && info.duration > 0 ? info.duration : 0
        var elapsed = info.currentTime.isFinite ? max(0, info.currentTime) : 0
        if duration > 0 {
            elapsed = min(elapsed, duration)
        }

        let rate = info.playbackRate.isFinite && info.playbackRate > 0 ? info.playbackRate : 1.0
        currentPlaybackRate = rate
        isCurrentlyPlaying = info.isPlaying
        lastPlaybackIntent = info.userPlayIntent
        webMediaSessionAvailable = info.mediaSessionAvailable

        let trackKey = [title, artist, album, artworkURL].joined(separator: "\u{1F}")
        let trackChanged = trackKey != currentTrackKey
        if trackChanged {
            currentLyric = ""
            currentTrackKey = trackKey
        }

        baseTitle = title
        baseArtist = artist

        // 不在每次状态同步时改音频会话：WebKit 正在播放时 setCategory 会打断自身音频。
        if info.isPlaying {
            shouldResumeAfterInterruption = false
            automaticResumeAttempts = 0
        } else if !info.userPlayIntent {
            // 用户在 App 或控制中心明确暂停时，取消尚未完成的打断恢复。
            shouldResumeAfterInterruption = false
            automaticResumeAttempts = 0
        }

        let combinedTitle = artist.isEmpty ? title : "\(title) - \(artist)"
        let displayArtist = currentLyric.isEmpty ? (artist.isEmpty ? " " : artist) : currentLyric

        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: combinedTitle,
            MPMediaItemPropertyArtist: displayArtist,
            MPMediaItemPropertyAlbumTitle: album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: info.isPlaying ? currentPlaybackRate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]

        if duration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }
        let shouldPublishNow = prepareArtwork(for: artworkURL, nowPlayingInfo: &nowPlayingInfo)
        if !shouldPublishNow {
            // 控制中心首次建卡时等待封面就绪，避免先发布无图卡片后系统不再刷新封面。
            enforceRemoteCommands()
            return
        }

        currentInfo = nowPlayingInfo
        enforceRemoteCommands()
        publishCurrentInfo()

        if info.isPlaying {
            pausedReassertWorkItem?.cancel()
            pausedReassertWorkItem = nil
            AudioSessionManager.shared.cancelPausedItemRecovery()
        } else {
            schedulePausedStateReassert()
            AudioSessionManager.shared.schedulePausedItemRecovery()
        }
    }

    /// 更新控制中心副标题中的实时歌词，并同步最新播放进度。
    func updateLyric(text: String, currentTime: Double? = nil, duration: Double? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        onMain { [weak self] in
            guard let self = self,
                  !self.currentInfo.isEmpty || self.pendingNowPlayingInfo != nil else { return }
            self.currentLyric = trimmed

            var info = self.pendingNowPlayingInfo ?? self.currentInfo
            if !self.baseTitle.isEmpty {
                let combinedTitle = self.baseArtist.isEmpty
                    ? self.baseTitle
                    : "\(self.baseTitle) - \(self.baseArtist)"
                info[MPMediaItemPropertyTitle] = combinedTitle
            }
            info[MPMediaItemPropertyArtist] = trimmed.isEmpty
                ? (self.baseArtist.isEmpty ? " " : self.baseArtist)
                : trimmed

            if let currentTime = currentTime, currentTime.isFinite, currentTime >= 0 {
                var elapsed = currentTime
                if let total = info[MPMediaItemPropertyPlaybackDuration] as? Double, total > 0 {
                    elapsed = min(elapsed, total)
                }
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
            }
            if let duration = duration, duration.isFinite, duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }

            if self.pendingNowPlayingInfo != nil {
                self.pendingNowPlayingInfo = info
                return
            }
            self.currentInfo = info
            self.publishCurrentInfo()
        }
    }

    /// WebKit 可能在暂停后短暂清空 Now Playing；延迟一次重申即可，绝不轮询或抢占音频会话。
    private func schedulePausedStateReassert() {
        pausedReassertWorkItem?.cancel()
        guard !isCurrentlyPlaying, !currentInfo.isEmpty, pendingNowPlayingInfo == nil else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pausedReassertWorkItem = nil
            guard !self.isCurrentlyPlaying,
                  !self.currentInfo.isEmpty,
                  self.pendingNowPlayingInfo == nil else { return }
            self.performPublish()
        }
        pausedReassertWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    /// 将当前状态真正写入系统媒体中心。封面等待期间只更新 pending，不提前泄露无图状态。
    private func publishCurrentInfo() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.publishCurrentInfo()
            }
            return
        }

        if var pending = pendingNowPlayingInfo {
            pending[MPNowPlayingInfoPropertyPlaybackRate] = isCurrentlyPlaying
                ? max(0.1, currentPlaybackRate)
                : 0.0
            pending[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
            pending[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
            pending[MPNowPlayingInfoPropertyIsLiveStream] = false
            pendingNowPlayingInfo = pending
            return
        }

        performPublish()
    }

    private func performPublish() {
        guard pendingNowPlayingInfo == nil, !currentInfo.isEmpty else { return }

        var info = currentInfo
        info[MPNowPlayingInfoPropertyPlaybackRate] = isCurrentlyPlaying
            ? max(0.1, currentPlaybackRate)
            : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false

        if let artwork = cachedArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
        }

        currentInfo = info

        // WKWebView 的 Media Session 会覆盖 MPNowPlayingInfoCenter；
        // 有 Web 会话时只让 WebKit 单方持有 Now Playing，避免双写把卡片清空。
        guard !webMediaSessionAvailable else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isCurrentlyPlaying ? .playing : .paused
    }

    private func normalizedText(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    // MARK: - Artwork

    /// 准备封面。返回 false 表示需要等待异步封面，期间不得发布 Now Playing 信息。
    private func prepareArtwork(for artworkURL: String, nowPlayingInfo: inout [String: Any]) -> Bool {
        if artworkURL.isEmpty {
            cancelArtworkWait()
            pendingNowPlayingInfo = nil
            currentArtworkURL = nil
            loadingArtworkURL = nil
            cachedArtwork = nil
            return true
        }

        if artworkURL == currentArtworkURL, let cached = cachedArtwork {
            cancelArtworkWait()
            pendingNowPlayingInfo = nil
            nowPlayingInfo[MPMediaItemPropertyArtwork] = cached
            return true
        }

        if let image = imageCache.object(forKey: artworkURL as NSString) {
            cancelArtworkWait()
            pendingNowPlayingInfo = nil
            currentArtworkURL = artworkURL
            loadingArtworkURL = nil
            cachedArtwork = createArtwork(from: image)
            if let artwork = cachedArtwork {
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
            }
            return true
        }

        if artworkURL == currentArtworkURL, pendingNowPlayingInfo != nil {
            pendingNowPlayingInfo = nowPlayingInfo
            return false
        }

        if artworkURL == currentArtworkURL, loadingArtworkURL == artworkURL {
            pendingNowPlayingInfo = nowPlayingInfo
            scheduleArtworkTimeout()
            return false
        }

        pausedReassertWorkItem?.cancel()
        pausedReassertWorkItem = nil
        currentArtworkURL = artworkURL
        loadingArtworkURL = nil
        cachedArtwork = nil
        pendingNowPlayingInfo = nowPlayingInfo
        scheduleArtworkTimeout()
        loadArtwork(from: artworkURL, isPreload: false)
        return false
    }

    /// 封面等待最长 1.2 秒；超时后仍发布元数据，保证缓冲/离线时控制中心可用。
    private func scheduleArtworkTimeout() {
        artworkLoadTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, let pending = self.pendingNowPlayingInfo else { return }
            self.artworkLoadTimeoutWorkItem = nil
            self.pendingNowPlayingInfo = nil
            self.currentInfo = pending
            self.enforceRemoteCommands()
            self.publishCurrentInfo()
            if !self.isCurrentlyPlaying {
                self.schedulePausedStateReassert()
                AudioSessionManager.shared.schedulePausedItemRecovery()
            }
        }
        artworkLoadTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    private func cancelArtworkWait() {
        artworkLoadTimeoutWorkItem?.cancel()
        artworkLoadTimeoutWorkItem = nil
    }

    /// 规范化封面 URL，并使用已验证稳定的 500px 首图，兼顾加载成功率与清晰度。
    private func sanitizeArtworkUrl(_ urlString: String) -> String {
        var clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }

        if clean.lowercased().hasPrefix("http://"),
           let host = URL(string: clean)?.host?.lowercased(),
           host.contains("163.com") || host.contains("126.net") {
            clean = "https://" + clean.dropFirst(7)
        }
        clean = clean.replacingOccurrences(of: "param=1024y1024", with: "param=500y500")
        clean = clean.replacingOccurrences(of: "param=800y800", with: "param=500y500")
        return clean
    }

    /// 预加载下一首歌曲封面至原生内存缓存，确保切歌瞬间封面秒现。
    func preloadArtwork(from urlString: String) {
        let clean = sanitizeArtworkUrl(urlString)
        guard !clean.isEmpty else { return }
        if imageCache.object(forKey: clean as NSString) != nil {
            return
        }
        loadArtwork(from: clean, isPreload: true)
    }

    /// 构造系统请求尺寸的 MPMediaItemArtwork，保持与已验证可用的渲染路径一致。
    private func createArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { requestedSize in
            guard requestedSize.width > 0, requestedSize.height > 0 else {
                return image
            }
            if abs(requestedSize.width - image.size.width) < 1,
               abs(requestedSize.height - image.size.height) < 1 {
                return image
            }
            let renderer = UIGraphicsImageRenderer(size: requestedSize)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: requestedSize))
            }
        }
    }

    /// 异步请求专辑封面图片；仅在原始 URL 无尺寸参数时追加一次 800px 兼容回退。
    private func loadArtwork(from urlString: String, isPreload: Bool = false) {
        let cleanURL = sanitizeArtworkUrl(urlString)
        guard !cleanURL.isEmpty else { return }

        if !isPreload {
            currentArtworkURL = cleanURL
        }

        if let cachedImage = imageCache.object(forKey: cleanURL as NSString) {
            if !isPreload {
                applyArtwork(cachedImage, for: cleanURL)
            }
            return
        }

        if cleanURL.hasPrefix("data:image/"),
           let commaIndex = cleanURL.firstIndex(of: ",") {
            let base64String = String(cleanURL[cleanURL.index(after: commaIndex)...])
            if let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
               let image = UIImage(data: data) {
                imageCache.setObject(image, forKey: cleanURL as NSString, cost: imageCacheCost(image))
                if !isPreload {
                    applyArtwork(image, for: cleanURL)
                }
                return
            }
        }

        if cleanURL.hasPrefix("file://"), let fileURL = URL(string: cleanURL),
           let image = UIImage(contentsOfFile: fileURL.path) {
            imageCache.setObject(image, forKey: cleanURL as NSString, cost: imageCacheCost(image))
            if !isPreload {
                applyArtwork(image, for: cleanURL)
            }
            return
        }

        if cleanURL.hasPrefix("/"), FileManager.default.fileExists(atPath: cleanURL),
           let image = UIImage(contentsOfFile: cleanURL) {
            imageCache.setObject(image, forKey: cleanURL as NSString, cost: imageCacheCost(image))
            if !isPreload {
                applyArtwork(image, for: cleanURL)
            }
            return
        }

        if !isPreload {
            loadingArtworkURL = cleanURL
        }

        let candidates = artworkURLCandidates(for: cleanURL)
        fetchArtwork(
            candidates: candidates,
            index: 0,
            cacheKey: cleanURL,
            isPreload: isPreload
        )
    }

    /// 尝试网络封面，失败后逐级降低请求尺寸，最多三次。
    private func fetchArtwork(
        candidates: [String],
        index: Int,
        cacheKey: String,
        isPreload: Bool
    ) {
        guard index < candidates.count else {
            if !isPreload {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.loadingArtworkURL == cacheKey else { return }
                    self.loadingArtworkURL = nil
                }
            }
            print("[NowPlayingManager] 封面加载失败: \(cacheKey)")
            return
        }

        let candidate = candidates[index]
        guard let url = URL(string: candidate)
            ?? URL(string: candidate.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            fetchArtwork(candidates: candidates, index: index + 1, cacheKey: cacheKey, isPreload: isPreload)
            return
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 10
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        if let host = url.host?.lowercased(), host.contains("163.com") || host.contains("126.net") {
            request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        }
        request.setValue("image/jpeg,image/png,image/webp,image/*;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if error == nil,
               let data = data,
               let image = UIImage(data: data) {
                self.imageCache.setObject(image, forKey: cacheKey as NSString, cost: self.imageCacheCost(image))
                DispatchQueue.main.async {
                    if !isPreload {
                        guard self.loadingArtworkURL == cacheKey else { return }
                        self.loadingArtworkURL = nil
                        self.applyArtwork(image, for: cacheKey)
                    } else if self.currentArtworkURL == cacheKey {
                        self.applyArtwork(image, for: cacheKey)
                    }
                }
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[NowPlayingManager] 封面请求失败，状态码: \(statusCode)，URL: \(candidate)")
            self.fetchArtwork(
                candidates: candidates,
                index: index + 1,
                cacheKey: cacheKey,
                isPreload: isPreload
            )
        }.resume()
    }

    /// 将封面更新到当前 Now Playing 信息。
    private func applyArtwork(_ image: UIImage, for urlString: String) {
        onMain { [weak self] in
            guard let self = self, self.currentArtworkURL == urlString else { return }
            self.cancelArtworkWait()
            self.cachedArtwork = self.createArtwork(from: image)

            var info = self.pendingNowPlayingInfo ?? self.currentInfo
            self.pendingNowPlayingInfo = nil
            if let artwork = self.cachedArtwork {
                info[MPMediaItemPropertyArtwork] = artwork
            }
            self.currentInfo = info
            self.publishCurrentInfo()

            if !self.isCurrentlyPlaying {
                self.schedulePausedStateReassert()
                AudioSessionManager.shared.schedulePausedItemRecovery()
            }
        }
    }

    private func artworkURLCandidates(for urlString: String) -> [String] {
        var candidates = [urlString]

        // 尺寸参数失败时回退到原始封面地址，避免 CDN 不支持缩放参数导致封面空白。
        if var components = URLComponents(string: urlString),
           !urlString.contains("thumbnail=") {
            let filteredItems = components.queryItems?.filter { $0.name != "param" }
            components.queryItems = (filteredItems?.isEmpty == true) ? nil : filteredItems
            if let fallback = components.string, fallback != urlString {
                candidates.append(fallback)
            }
        }

        if !urlString.contains("param="), !urlString.contains("thumbnail=") {
            let separator = urlString.contains("?") ? "&" : "?"
            candidates.append("\(urlString)\(separator)param=800y800")
        }

        var uniqueCandidates: [String] = []
        for candidate in candidates where !candidate.isEmpty && !uniqueCandidates.contains(candidate) {
            uniqueCandidates.append(candidate)
        }
        return uniqueCandidates
    }

    private func imageCacheCost(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// 清除封面图片网络/内存缓存，但保留当前正在显示的封面，避免控制中心瞬间变空。
    func clearArtworkCache() {
        imageCache.removeAllObjects()
        loadingArtworkURL = nil
    }
}
