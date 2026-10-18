import Foundation
import AVFoundation

/// 管理应用音频会话及系统音频中断/路由变化事件。
/// 使用混音类别避免游戏/短视频音频抢占独占会话；真实打断结束后按用户播放意图恢复。
final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var silenceSecondaryObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var recoveryWorkItems = [DispatchWorkItem]()
    private var isInterruptionActive = false
    // setCategory 在 WKWebView 正在播放时可能打断 WebKit 音频并撤销 Now Playing，只能配置一次。
    private var isCategoryConfigured = false

    private init() {
        setupObservers()
    }

    deinit {
        cancelPausedItemRecovery()
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = silenceSecondaryObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 配置播放类别，但不在启动阶段激活，避免应用一打开就打断其他 App 的音频。
    @discardableResult
    func configureAudioSession() -> Bool {
        applyAudioSession(activate: false)
    }

    /// 在用户明确开始播放或从控制中心点击播放时激活音频会话。
    @discardableResult
    func reactivateAudioSession() -> Bool {
        applyAudioSession(activate: true)
    }

    /// 取消打断后的暂停卡片恢复，避免用户已经重新播放仍继续恢复。
    func cancelPausedItemRecovery() {
        recoveryWorkItems.forEach { $0.cancel() }
        recoveryWorkItems.removeAll()
    }

    /// 打断会临时撤销音频会话资格；在限定时间内按用户播放意图恢复真实播放，
    /// 无法恢复时再重申暂停中的 Now Playing 卡片。
    func schedulePausedItemRecovery() {
        cancelPausedItemRecovery()
        guard NowPlayingManager.shared.hasActiveNowPlayingItem,
              !NowPlayingManager.shared.isCurrentlyPlayingForAudioSession else {
            return
        }

        // 首次恢复已由 .ended 立即派发；后续重试给 WKWebView 留出执行窗口，避免重叠命令互相取消。
        let intervals = [2.0, 4.0, 8.0, 12.0, 18.0, 25.0, 35.0, 45.0, 60.0]
        for delay in intervals {
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard NowPlayingManager.shared.hasActiveNowPlayingItem,
                      !NowPlayingManager.shared.isCurrentlyPlayingForAudioSession else {
                    self.cancelPausedItemRecovery()
                    return
                }
                // 打断仍在进行时不要提前消耗恢复次数；等待 .ended 后再恢复。
                guard !self.isInterruptionActive else { return }

                // 打断前正在播放时优先恢复真实播放，Control Center 才能重新持有 Now Playing 资格。
                // 混音会话允许在游戏仍在发声时恢复，不因 isOtherAudioPlaying 一直卡住。
                if NowPlayingManager.shared.resumeAfterInterruptionIfPossible() {
                    // 保留后续重试；WebKit 确认真正播放后会自动取消恢复任务。
                    return
                }

                // 仅暂停卡片需要避开其他 App 的独占会话；没有其他音频时重新激活并重申元数据。
                guard !AVAudioSession.sharedInstance().isOtherAudioPlaying else { return }
                guard self.reactivateAudioSession() else { return }
                self.cancelPausedItemRecovery()
                NowPlayingManager.shared.reassertNowPlayingInfo()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NowPlayingManager.shared.reassertNowPlayingInfo()
                }
            }
            recoveryWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func applyAudioSession(activate: Bool) -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try configureCategoryIfNeeded(session)

            if activate {
                // 正常播放时绝不重设分类；仅当系统/WebKit 已把分类改掉时才在播放前恢复。
                if session.category != .playback {
                    isCategoryConfigured = false
                    try configureCategoryIfNeeded(session)
                }
                do {
                    try session.setActive(true)
                } catch {
                    // 系统/WebKit 可能重置过分类；只在激活失败时重新配置，避免打断正在播放的 WebKit 音频。
                    isCategoryConfigured = false
                    try configureCategoryIfNeeded(session)
                    try session.setActive(true)
                }
                print("[AudioSessionManager] 音频会话已激活")
            } else {
                print("[AudioSessionManager] 音频会话类别已配置（待播放时激活）")
            }
            return true
        } catch {
            isCategoryConfigured = false
            print("[AudioSessionManager] 配置音频会话失败: \(error.localizedDescription)")
            return false
        }
    }

    private func configureCategoryIfNeeded(_ session: AVAudioSession) throws {
        guard !isCategoryConfigured else { return }
        try session.setCategory(
            .playback,
            mode: .default,
            // 游戏、短视频等音频不应把本 App 的独占会话打断；音乐可与其混音。
            options: [.mixWithOthers, .allowAirPlay, .allowBluetoothA2DP]
        )
        isCategoryConfigured = true
    }

    /// 监听耳机拔出、系统打断、主导音频切换及音频服务重置。
    private func setupObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification: notification)
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification: notification)
        }

        silenceSecondaryObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleSilenceSecondaryAudioHint(notification: notification)
        }

        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[AudioSessionManager] 系统音频服务重置，重新配置音频会话")
            self?.isInterruptionActive = false
            self?.isCategoryConfigured = false
            self?.configureAudioSession()
            NowPlayingManager.shared.reassertNowPlayingInfo()
            self?.schedulePausedItemRecovery()
        }
    }

    private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            print("[AudioSessionManager] 收到音频打断开始，保持控制中心暂停状态")
            isInterruptionActive = true
            NowPlayingManager.shared.handleInterruptionBegan()
            schedulePausedItemRecovery()

        case .ended:
            isInterruptionActive = false
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let shouldResume = options.contains(.shouldResume)
            print("[AudioSessionManager] 收到音频打断结束，shouldResume: \(shouldResume)")

            // 由 NowPlayingManager 按用户播放意图决定是否恢复；随后统一进入重试/暂停卡片恢复。
            NowPlayingManager.shared.handleInterruptionEnded(shouldResume: shouldResume)
            schedulePausedItemRecovery()

        @unknown default:
            break
        }
    }

    private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            print("[AudioSessionManager] 旧音频设备断开（耳机拔出/蓝牙断开），自动暂停")
            NowPlayingManager.shared.handleInterruptionBegan(allowAutoResume: false)
            schedulePausedItemRecovery()
        default:
            break
        }
    }

    private func handleSilenceSecondaryAudioHint(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
              let hintType = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: typeValue) else {
            return
        }

        switch hintType {
        case .begin:
            // 次级音频提示是系统混音建议，不是硬打断。游戏/短视频开始发声时不应强制暂停音乐。
            print("[AudioSessionManager] 次级音频提示开始，保持当前播放")
        case .end:
            print("[AudioSessionManager] 次级音频提示结束")
        @unknown default:
            break
        }
    }
}
