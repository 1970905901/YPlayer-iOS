import Foundation
import WebKit
import UIKit

/// 原生与 Web 前端通信中介 (遵循 write-swift 弱引用与安全规程)
final class NativeBridge: NSObject, WKScriptMessageHandler {

    private weak var viewController: ViewController?

    init(viewController: ViewController) {
        self.viewController = viewController
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "nativePlayer",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            return
        }

        switch action {
        case "updatePlayState":
            handleUpdatePlayState(payload: body)

        case "hapticFeedback":
            handleHapticFeedback(payload: body)

        case "setStatusBarStyle":
            handleStatusBarStyle(payload: body)

        case "share":
            handleShare(payload: body)

        case "httpRequest":
            handleHttpRequest(payload: body)

        case "openExternalUrl":
            handleOpenExternalUrl(payload: body)

        case "updateLyric":
            handleUpdateLyric(payload: body)

        case "clearNativeCache":
            handleClearNativeCache()

        case "setNativeCacheLimit":
            handleSetNativeCacheLimit(payload: body)

        default:
            print("[NativeBridge] 未知操作类型: \(action)")
        }
    }

    private func handleUpdatePlayState(payload: [String: Any]) {
        let isPlaying = payload["isPlaying"] as? Bool ?? false
        let title = payload["title"] as? String ?? ""
        let artist = payload["artist"] as? String ?? ""
        let album = payload["album"] as? String ?? ""
        let artworkUrl = payload["artworkUrl"] as? String ?? ""
        let duration = payload["duration"] as? Double ?? 0.0
        let currentTime = payload["currentTime"] as? Double ?? 0.0
        let playbackRate = payload["playbackRate"] as? Double ?? 1.0

        let info = PlaybackStateInfo(
            isPlaying: isPlaying,
            title: title,
            artist: artist,
            album: album,
            artworkUrl: artworkUrl,
            duration: duration,
            currentTime: currentTime,
            playbackRate: playbackRate
        )

        NowPlayingManager.shared.updateNowPlaying(info: info)
    }

    private func handleHapticFeedback(payload: [String: Any]) {
        let style = payload["style"] as? String ?? "selection"

        DispatchQueue.main.async {
            switch style {
            case "light":
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.prepare()
                generator.impactOccurred()
            case "medium":
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.prepare()
                generator.impactOccurred()
            case "heavy":
                let generator = UIImpactFeedbackGenerator(style: .heavy)
                generator.prepare()
                generator.impactOccurred()
            case "selection":
                let generator = UISelectionFeedbackGenerator()
                generator.prepare()
                generator.selectionChanged()
            case "success":
                let generator = UINotificationFeedbackGenerator()
                generator.prepare()
                generator.notificationOccurred(.success)
            case "warning":
                let generator = UINotificationFeedbackGenerator()
                generator.prepare()
                generator.notificationOccurred(.warning)
            case "error":
                let generator = UINotificationFeedbackGenerator()
                generator.prepare()
                generator.notificationOccurred(.error)
            default:
                break
            }
        }
    }

    private func handleStatusBarStyle(payload: [String: Any]) {
        let styleStr = payload["style"] as? String ?? "light"
        let statusBarStyle: UIStatusBarStyle = (styleStr == "light") ? .lightContent : .darkContent

        DispatchQueue.main.async { [weak self] in
            self?.viewController?.updateStatusBarStyle(statusBarStyle)
        }
    }

    private func handleShare(payload: [String: Any]) {
        guard let vc = viewController else { return }
        var items: [Any] = []

        if let title = payload["title"] as? String, !title.isEmpty {
            items.append(title)
        }
        if let urlStr = payload["url"] as? String, let url = URL(string: urlStr) {
            items.append(url)
        }

        guard !items.isEmpty else { return }

        DispatchQueue.main.async {
            let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = vc.view
                popover.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            vc.present(activityVC, animated: true, completion: nil)
        }
    }

    private func handleHttpRequest(payload: [String: Any]) {
        guard let reqId = payload["id"] as? String,
              let urlStr = payload["url"] as? String,
              let url = URL(string: urlStr) else {
            return
        }

        let method = (payload["method"] as? String ?? "GET").uppercased()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20.0

        if let headers = payload["headers"] as? [String: String] {
            for (headerKey, headerVal) in headers {
                request.setValue(headerVal, forHTTPHeaderField: headerKey)
            }
        }

        if let dataStr = payload["data"] as? String, !dataStr.isEmpty {
            request.httpBody = dataStr.data(using: .utf8)
        }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? (error == nil ? 200 : 500)
            let bodyString = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let errorMsg = error?.localizedDescription

            var responseHeaders: [String: String] = [:]
            if let allHeaders = httpResponse?.allHeaderFields {
                for (k, v) in allHeaders {
                    responseHeaders[String(describing: k).lowercased()] = String(describing: v)
                }
            }

            var responsePayload: [String: Any] = [
                "id": reqId,
                "status": statusCode,
                "data": bodyString,
                "headers": responseHeaders
            ]
            if let errorMsg = errorMsg {
                responsePayload["error"] = errorMsg
            }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: responsePayload),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return
            }

            DispatchQueue.main.async {
                self?.viewController?.evaluateJavaScript(
                    "if (window.__nativeHttpCallback) { window.__nativeHttpCallback(\(jsonString)); }"
                )
            }
        }
        task.resume()
    }

    private func handleOpenExternalUrl(payload: [String: Any]) {
        guard let urlStr = payload["url"] as? String,
              let url = URL(string: urlStr) else {
            return
        }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    private func handleUpdateLyric(payload: [String: Any]) {
        guard let text = payload["text"] as? String else { return }
        let currentTime = payload["currentTime"] as? Double
        let duration = payload["duration"] as? Double
        NowPlayingManager.shared.updateLyric(text: text, currentTime: currentTime, duration: duration)
    }

    private func handleClearNativeCache() {
        DispatchQueue.main.async {
            URLCache.shared.removeAllCachedResponses()
            NowPlayingManager.shared.clearArtworkCache()
        }
    }

    private func handleSetNativeCacheLimit(payload: [String: Any]) {
        let limitMB = payload["limitMB"] as? Int ?? 512
        DispatchQueue.main.async {
            if limitMB <= 0 {
                URLCache.shared.removeAllCachedResponses()
                URLCache.shared.memoryCapacity = 0
                URLCache.shared.diskCapacity = 0
                NowPlayingManager.shared.clearArtworkCache()
            } else {
                URLCache.shared.memoryCapacity = min(limitMB, 64) * 1024 * 1024
                URLCache.shared.diskCapacity = limitMB * 1024 * 1024
            }
        }
    }
}
