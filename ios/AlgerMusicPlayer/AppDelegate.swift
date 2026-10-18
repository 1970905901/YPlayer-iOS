import UIKit
import AVFoundation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 配置音频会话以支持后台播放
        AudioSessionManager.shared.configureAudioSession()

        // 注册远程控制事件（耳机按钮、锁屏控制、AirPods 触控等）
        application.beginReceivingRemoteControlEvents()

        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        application.beginReceivingRemoteControlEvents()
        // 回到前台仅恢复媒体信息；暂停时不激活音频会话，避免抢占其他 App 的音频焦点。
        NowPlayingManager.shared.reassertNowPlayingInfo()
    }

    // MARK: - UISceneSession Lifecycle

    @available(iOS 13.0, *)
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    @available(iOS 13.0, *)
    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {
    }
}
