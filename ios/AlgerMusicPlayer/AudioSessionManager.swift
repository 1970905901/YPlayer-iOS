import Foundation
import AVFoundation

/// 管理应用音频会话及系统音频中断/路由变化事件。
/// 次级音频提示不改变播放状态；真实打断结束后按系统建议恢复，暂停时仅在无其他音频时恢复卡片资格。
final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var silenceSecondaryObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var recoveryWorkItems = [DispatchWorkItem]()

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

    /// 打断会临时撤销音频会话资格。若当前没有其他音频在播放，
    /// 在限定时间内恢复会话并重申暂停中的 Now Playing 卡片；不恢复实际音频。
    func schedulePausedItemRecovery() {
        cancelPausedItemRecovery()
        guard NowPlayingManager.shared.hasActiveNowPlayingItem,
              !NowPlayingManager.shared.isCurrentlyPlayingForAudioSession else {
            return
        }

        let intervals = [0.5, 1.5, 3.0, 5.0, 8.0, 12.0, 18.0, 25.0, 35.0, 45.0, 60.0]
        for delay in intervals {
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard NowPlayingManager.shared.hasActiveNowPlayingItem,
                      !NowPlayingManager.shared.isCurrentlyPlayingForAudioSession else {
                    self.cancelPausedItemRecovery()
                    return
                }
                guard !AVAudioSession.sharedInstance().isOtherAudioPlaying else { return }

                // 打断前正在播放时恢复真实播放，Control Center 才能重新持有 Now Playing 资格。
                if NowPlayingManager.shared.resumeAfterInterruptionIfPossible() {
                    self.cancelPausedItemRecovery()
                    return
                }

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
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetoothA2DP]
            )
            if activate {
                try session.setActive(true)
                print("[AudioSessionManager] 音频会话已激活")
            } else {
                print("[AudioSessionManager] 音频会话类别已配置（待播放时激活）")
            }
            return true
        } catch {
            print("[AudioSessionManager] 配置音频会话失败: \(error.localizedDescription)")
            return false
        }
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
            NowPlayingManager.shared.handleInterruptionBegan()
            schedulePausedItemRecovery()

        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let shouldResume = options.contains(.shouldResume)
            print("[AudioSessionManager] 收到音频打断结束，shouldResume: \(shouldResume)")

            // 不自动恢复实际播放，但在没有其他音频时恢复暂停中的控制中心卡片。
            NowPlayingManager.shared.handleInterruptionEnded(shouldResume: shouldResume)
            if !NowPlayingManager.shared.isCurrentlyPlayingForAudioSession,
               !AVAudioSession.sharedInstance().isOtherAudioPlaying,
               self.reactivateAudioSession() {
                NowPlayingManager.shared.reassertNowPlayingInfo()
            }
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
