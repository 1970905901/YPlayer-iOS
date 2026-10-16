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
}
