import UIKit
import WebKit

final class ViewController: UIViewController {

    private var webView: WKWebView!
    private var nativeBridge: NativeBridge!
    private var currentStatusBarStyle: UIStatusBarStyle = .default

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return currentStatusBarStyle
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        setupRemoteCommandHandler()
        loadWebApp()
    }

    private func setupViews() {
        view.backgroundColor = .systemBackground

        let config = WKWebViewConfiguration()

        // 注册自定义本地 Scheme 处理器
        let schemeHandler = LocalSchemeHandler()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "app")

        // 允许自动内联媒体播放
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // 注册原生通信 Bridge
        let contentController = WKUserContentController()
        nativeBridge = NativeBridge(viewController: self)
        contentController.add(nativeBridge, name: "nativePlayer")
        config.userContentController = contentController

        // 初始化 WKWebView
        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear

        // 允许页面贯通至状态栏与刘海/灵动岛底部 (符合 mobile-native 的 viewport-fit=cover 规则)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false

        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupRemoteCommandHandler() {
        NowPlayingManager.shared.onCommandReceived = { [weak self] command, arg in
            self?.sendRemoteCommandToWeb(command: command, arg: arg)
        }
    }

    private func sendRemoteCommandToWeb(command: String, arg: Double?) {
        guard let webView = self.webView else { return }

        let argString: String
        if let val = arg {
            argString = "\(val)"
        } else {
            argString = "null"
        }

        let js = "window.__NATIVE_BRIDGE__ && window.__NATIVE_BRIDGE__.handleRemoteCommand('\(command)', \(argString));"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("[ViewController] 远端指令派发至 Web 异常: \(error.localizedDescription)")
            }
        }
    }

    private func loadWebApp() {
        if let url = URL(string: "app://localhost/index.html") {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }

    /// 动态修改状态栏颜色
    func updateStatusBarStyle(_ style: UIStatusBarStyle) {
        currentStatusBarStyle = style
        UIView.animate(withDuration: 0.25) {
            self.setNeedsStatusBarAppearanceUpdate()
        }
    }
}
