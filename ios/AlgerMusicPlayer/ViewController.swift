import UIKit
import WebKit

final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

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

        // 注入全局错误与控制台捕获脚本，便于排查白屏与加载异常
        let debugScript = """
        window.addEventListener('error', function(e) {
            console.error('[Web Error]', e.message, e.filename, e.lineno);
        });
        window.addEventListener('unhandledrejection', function(e) {
            console.error('[Unhandled Promise Rejection]', e.reason);
        });
        """
        let userScript = WKUserScript(source: debugScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)

        // 注册原生通信 Bridge
        let contentController = WKUserContentController()
        contentController.addUserScript(userScript)
        nativeBridge = NativeBridge(viewController: self)
        contentController.add(nativeBridge, name: "nativePlayer")
        config.userContentController = contentController

        // 初始化 WKWebView
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
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

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[ViewController] 页面加载失败: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("[ViewController] 页面初次导航失败: \(error.localizedDescription)")
        // 如果 app:// 协议加载失败，尝试使用 loadFileURL 本地回退加载
        if let bundleAssets = Bundle.main.url(forResource: "AppAssets", withExtension: nil) {
            let indexFile = bundleAssets.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: indexFile.path) {
                webView.loadFileURL(indexFile, allowingReadAccessTo: bundleAssets)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[ViewController] 页面加载完成")
    }

    /// 动态修改状态栏颜色
    func updateStatusBarStyle(_ style: UIStatusBarStyle) {
        currentStatusBarStyle = style
        UIView.animate(withDuration: 0.25) {
            self.setNeedsStatusBarAppearanceUpdate()
        }
    }
}
