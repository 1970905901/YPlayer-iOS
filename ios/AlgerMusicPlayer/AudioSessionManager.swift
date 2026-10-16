import Foundation
import AVFoundation

/// 管理应用音频会话及系统音频中断/插拔事件
final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

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
        } catch {
            print("[AudioSessionManager] 配置音频会话失败: \(error.localizedDescription)")
        }
    }

    /// 监听音频中断与拔出耳机等线路变更
    private func setupObservers() {
        // 电话接入、闹钟等音频打断处理
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification: notification)
        }

        // 耳机拔出 / 蓝牙断开自动暂停，避免公放尴尬
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification: notification)
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
            print("[AudioSessionManager] 音频被打断，暂停播放")
            NowPlayingManager.shared.dispatchRemoteCommand("pause")
        case .ended:
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("[AudioSessionManager] 打断结束，恢复播放")
                    NowPlayingManager.shared.dispatchRemoteCommand("play")
                }
            }
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
            print("[AudioSessionManager] 旧音频设备断开连接 (耳机拔出/蓝牙断开)，自动暂停")
            NowPlayingManager.shared.dispatchRemoteCommand("pause")
        default:
            break
        }
    }
}
