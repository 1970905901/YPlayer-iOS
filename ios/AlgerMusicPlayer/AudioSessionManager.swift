import Foundation
import AVFoundation

/// 管理应用音频会话及系统音频中断/插拔事件
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

    /// 配置 AVAudioSession 支持后台持续播放
    func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetooth]
            )
            try session.setActive(true)
            print("[AudioSessionManager] 音频会话配置成功并激活")
        } catch {
            print("[AudioSessionManager] 配置音频会话失败: \(error.localizedDescription)")
        }
    }

    /// 重新激活音频会话（系统打断结束或重新恢复播放时调用，确保控制中心资格不丢失）
    func reactivateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetooth]
            )
            try session.setActive(true)
            print("[AudioSessionManager] 音频会话重新激活成功")
        } catch {
            print("[AudioSessionManager] 重新激活音频会话失败: \(error.localizedDescription)")
        }
    }

    /// 监听耳机拔出、系统打断、主导音频切换及音频服务重置
    private func setupObservers() {
        // 1. 监听系统音频中断通知 (来电、Siri、其他应用播放音视频抢占音频焦点)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification: notification)
        }

        // 2. 耳机拔出 / 蓝牙断开自动暂停，避免外放尴尬并同步控制中心
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification: notification)
        }

        // 3. 监听其他主导音频开始/结束播放提示 (如短视频应用或游戏播放声音)
        silenceSecondaryObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleSilenceSecondaryAudioHint(notification: notification)
        }

        // 4. 监听系统音频服务重置 (mediaserverd 进程崩溃或重启)
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[AudioSessionManager] 系统音频服务重置，重新初始化")
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
            print("[AudioSessionManager] 收到音频打断开始 (interruption began)，保持控制中心显示暂停状态")
            NowPlayingManager.shared.handleInterruptionBegan()

        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let shouldResume = options.contains(.shouldResume)
            print("[AudioSessionManager] 收到音频打断结束 (interruption ended), shouldResume: \(shouldResume)")

            // 打断结束后重新激活音频会话，确保控制中心不会因为会话失活而消失
            reactivateAudioSession()
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
            print("[AudioSessionManager] 旧音频设备断开连接 (耳机拔出/蓝牙断开)，自动切换为暂停状态")
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
            print("[AudioSessionManager] 收到主导音频抢占提示，保持控制中心显示暂停状态")
            NowPlayingManager.shared.handleInterruptionBegan()
        case .end:
            print("[AudioSessionManager] 主导音频播放完毕，重新激活音频会话并保持控制中心信息")
            reactivateAudioSession()
            NowPlayingManager.shared.handleInterruptionEnded(shouldResume: false)
        @unknown default:
            break
        }
    }
}
