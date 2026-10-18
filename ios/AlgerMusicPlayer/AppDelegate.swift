import UIKit
import AVFoundation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 原生 AVPlayer 负责音频、后台恢复与 Now Playing
        NativeAudioManager.shared.start()

        // 注册远程控制事件（耳机按钮、锁屏控制、AirPods 触控等）
        application.beginReceivingRemoteControlEvents()

        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        application.beginReceivingRemoteControlEvents()
        NativeAudioManager.shared.refreshStateForForeground()
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
