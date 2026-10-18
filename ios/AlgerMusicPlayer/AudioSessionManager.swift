import Foundation
import AVFoundation

/// 管理应用音频会话及系统音频中断/路由变化事件。
/// 音频会话只在用户真正开始播放时激活，暂停或回到前台时不会抢占其他 App 的音频焦点。
final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var silenceSecondaryObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?

    private init() {
        setupObservers()
    }

    deinit {
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
    func configureAudioSession() {
        applyAudioSession(activate: false)
    }

    /// 在用户明确开始播放或从控制中心点击播放时激活音频会话。
    func reactivateAudioSession() {
        applyAudioSession(activate: true)
    }

    private func applyAudioSession(activate: Bool) {
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
        } catch {
            print("[AudioSessionManager] 配置音频会话失败: \(error.localizedDescription)")
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

        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let shouldResume = options.contains(.shouldResume)
            print("[AudioSessionManager] 收到音频打断结束，shouldResume: \(shouldResume)")

            // 不自动重新激活会话或恢复播放，避免来电/通知结束后抢断其他 App。
            // 用户再次点击播放时，NowPlayingManager 会重新激活会话。
            NowPlayingManager.shared.handleInterruptionEnded(shouldResume: shouldResume)

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
            NowPlayingManager.shared.handleInterruptionBegan()
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
            print("[AudioSessionManager] 主音频抢占提示，暂停并保持控制中心信息")
            NowPlayingManager.shared.handleInterruptionBegan()
        case .end:
            print("[AudioSessionManager] 主音频结束，保持暂停，等待用户明确恢复")
            NowPlayingManager.shared.handleInterruptionEnded(shouldResume: false)
        @unknown default:
            break
        }
    }
}
