import Foundation
import WebKit

/// 自定义 WKURLSchemeHandler，用于从 App Bundle 中直接安全加载打包后的 Web 静态资源
/// 支持标准 SPA 路由回退，解决本地 file:// 协议跨域、模块导入与缓存等问题
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {

    private let assetsDirectory: URL

    override init() {
        if let bundleAssets = Bundle.main.url(forResource: "AppAssets", withExtension: nil) {
            self.assetsDirectory = bundleAssets
        } else if let resourceURL = Bundle.main.resourceURL {
            self.assetsDirectory = resourceURL.appendingPathComponent("AppAssets")
        } else {
            self.assetsDirectory = Bundle.main.bundleURL
        }
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let requestURL = urlSchemeTask.request.url ?? URL(fileURLWithPath: "/")
        var relativePath = requestURL.path

        if relativePath.isEmpty || relativePath == "/" {
            relativePath = "/index.html"
        }

        if relativePath.hasPrefix("/") {
            relativePath = String(relativePath.dropFirst())
        }

        var fileURL = assetsDirectory.appendingPathComponent(relativePath)

        // SPA 降级：如果请求的文件不存在且不带后缀，或者为非资源文件路由，则提供 index.html
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let indexURL = assetsDirectory.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: indexURL.path) {
                fileURL = indexURL
            }
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            let error = NSError(
                domain: "fun.alger.music",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Resource not found: \(relativePath)"]
            )
            urlSchemeTask.didFailWithError(error)
            return
        }

        let mimeType = mimeTypeFor(pathExtension: fileURL.pathExtension)
        let headers: [String: String] = [
            "Content-Type": mimeType,
            "Content-Length": "\(data.count)",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache"
        ]

        if let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) {
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } else {
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: "utf-8"
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 请求取消处理
    }

    private func mimeTypeFor(pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "js", "mjs":
            return "application/javascript; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        case "json":
            return "application/json; charset=utf-8"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        case "gif":
            return "image/gif"
        case "ico":
            return "image/x-icon"
        case "woff":
            return "font/woff"
        case "woff2":
            return "font/woff2"
        case "ttf":
            return "font/ttf"
        case "otf":
            return "font/otf"
        case "mp3":
            return "audio/mpeg"
        case "flac":
            return "audio/flac"
        case "wav":
            return "audio/wav"
        case "aac":
            return "audio/aac"
        default:
            return "application/octet-stream"
        }
    }
}
