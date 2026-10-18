import UIKit
import WebKit

final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    private var webView: WKWebView!
    private var nativeBridge: NativeBridge!
    private var currentStatusBarStyle: UIStatusBarStyle = .default
    private var remoteCommandBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var remoteCommandTimeoutWorkItem: DispatchWorkItem?
    private var remoteCommandGeneration = 0

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return currentStatusBarStyle
    }

    override var canBecomeFirstResponder: Bool {
        return true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        setupNativeAudioBridge()
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
        // 禁用浏览器历史原生的边缘前进后退拦截手势，确保侧滑返回完全由页面抽屉与播放器手势响应
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .clear

        // 允许页面贯通至状态栏与刘海/灵动岛底部 (符合 mobile-native 的 viewport-fit=cover 规则)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        // 彻底禁止缩放手势，杜绝双击放大页面
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.bouncesZoom = false

        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupNativeAudioBridge() {
        NativeAudioManager.shared.start()
        NativeAudioManager.shared.onEvent = { [weak self] event, payload in
            self?.sendNativeAudioEvent(event, payload)
        }
        NativeAudioManager.shared.onRemoteCommand = { [weak self] command in
            self?.sendRemoteCommandToWeb(command: command, arg: nil)
        }
    }

    private func sendNativeAudioEvent(_ event: String, _ payload: [String: Any]) {
        guard let webView = self.webView else { return }
        webView.callAsyncJavaScript(
            "return window.__NATIVE_AUDIO_EVENT__ ? window.__NATIVE_AUDIO_EVENT__(event, payload) : null;",
            arguments: ["event": event, "payload": payload],
            in: nil,
            in: .page
        ) { _ in }
    }

    private func sendRemoteCommandToWeb(command: String, arg: Double?, attempt: Int = 0) {
        guard let webView = self.webView else { return }

        endRemoteCommandBackgroundTask()
        remoteCommandGeneration &+= 1
        let generation = remoteCommandGeneration
        let taskId = UIApplication.shared.beginBackgroundTask(withName: "RemoteCommand-\(command)") { [weak self] in
            self?.endRemoteCommandBackgroundTask()
        }
        if taskId != .invalid {
            remoteCommandBackgroundTask = taskId
        }

        var arguments: [String: Any] = ["command": command]
        // 无参数命令传 0 即可；远程命令处理器只在 seek 时读取数值参数。
        arguments["arg"] = arg ?? 0

        let script = """
        if (!window.__NATIVE_BRIDGE__ || typeof window.__NATIVE_BRIDGE__.handleRemoteCommand !== 'function') {
            throw new Error('native-bridge-not-ready');
        }
        return await window.__NATIVE_BRIDGE__.handleRemoteCommand(command, arg);
        """

        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.remoteCommandGeneration == generation else { return }
                if case let .failure(error) = result {
                    print("[ViewController] 远端指令派发至 Web 异常: \(error.localizedDescription)")
                    if attempt < 1 {
                        self.endRemoteCommandBackgroundTask()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            guard self.remoteCommandGeneration == generation else { return }
                            self.sendRemoteCommandToWeb(command: command, arg: arg, attempt: attempt + 1)
                        }
                        return
                    }
                }
                self.endRemoteCommandBackgroundTask()
            }
        }

        remoteCommandTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.remoteCommandGeneration == generation,
                  self.remoteCommandBackgroundTask == taskId else { return }
            self.endRemoteCommandBackgroundTask()
        }
        remoteCommandTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 25.0, execute: timeout)
    }

    private func endRemoteCommandBackgroundTask() {
        remoteCommandTimeoutWorkItem?.cancel()
        remoteCommandTimeoutWorkItem = nil
        if remoteCommandBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(remoteCommandBackgroundTask)
            remoteCommandBackgroundTask = .invalid
        }
    }

    private func loadWebApp() {
        if let url = URL(string: "app://localhost/index.html") {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // 外部链接 (如 GitHub、第三方文档) 跳出至系统 Safari 打开
        if let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
           url.host != "localhost" && url.host != "127.0.0.1" {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

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

    /// 执行 JavaScript
    func evaluateJavaScript(_ script: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        webView?.evaluateJavaScript(script, completionHandler: completionHandler)
    }
}
