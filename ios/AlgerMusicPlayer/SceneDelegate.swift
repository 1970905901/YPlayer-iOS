import UIKit

@available(iOS 13.0, *)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        let window = UIWindow(windowScene: windowScene)
        let rootViewController = ViewController()
        window.rootViewController = rootViewController
        window.backgroundColor = .systemBackground
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidDisconnect(_ scene: UIScene) {}

    func sceneDidBecomeActive(_ scene: UIScene) {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        // 刷新 Now Playing 元数据；仅正在播放时才确保音频会话有效。
        NowPlayingManager.shared.reassertNowPlayingInfo()
    }

    func sceneWillResignActive(_ scene: UIScene) {}

    func sceneWillEnterForeground(_ scene: UIScene) {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        // 刷新 Now Playing 元数据；仅正在播放时才确保音频会话有效。
        NowPlayingManager.shared.reassertNowPlayingInfo()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // 进入后台时重申当前状态；若已暂停，只保留元数据，不激活音频会话。
        NowPlayingManager.shared.reassertNowPlayingInfo()
    }
}
