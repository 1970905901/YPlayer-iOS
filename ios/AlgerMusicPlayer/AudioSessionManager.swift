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

    /// 监听耳机拔出等线路变更
    private func setupObservers() {
        // 耳机拔出 / 蓝牙断开自动暂停，避免公放尴尬
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification: notification)
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
