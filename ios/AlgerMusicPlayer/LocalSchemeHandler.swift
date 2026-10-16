import Foundation
import WebKit

/// 自定义 WKURLSchemeHandler，用于从 App Bundle 中直接安全加载打包后的 Web 静态资源
/// 支持标准 SPA 路由回退，解决本地 file:// 协议跨域、模块导入与缓存等问题
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {

    private let searchDirectories: [URL]

    override init() {
        var dirs: [URL] = []

        // 1. AppAssets 子目录 (Folder Reference)
        if let bundleAssets = Bundle.main.url(forResource: "AppAssets", withExtension: nil) {
            dirs.append(bundleAssets)
        }
        if let resourceURL = Bundle.main.resourceURL {
            dirs.append(resourceURL.appendingPathComponent("AppAssets"))
        }
        dirs.append(Bundle.main.bundleURL.appendingPathComponent("AppAssets"))

        // 2. Bundle 根目录备用
        if let resourceURL = Bundle.main.resourceURL {
            dirs.append(resourceURL)
        }
        dirs.append(Bundle.main.bundleURL)

        self.searchDirectories = dirs
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            let error = NSError(domain: "fun.alger.music", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            urlSchemeTask.didFailWithError(error)
            return
        }

        // 处理 OPTIONS 预检请求
        if urlSchemeTask.request.httpMethod?.uppercased() == "OPTIONS" {
            let preflightHeaders = [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS, HEAD",
                "Access-Control-Allow-Headers": "*",
                "Access-Control-Max-Age": "86400"
            ]
            if let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: preflightHeaders) {
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didFinish()
            }
            return
        }

        // 解析相对路径
        var relativePath = requestURL.path
        if relativePath.isEmpty || relativePath == "/" {
            relativePath = "index.html"
        }
        while relativePath.hasPrefix("/") {
            relativePath = String(relativePath.dropFirst())
        }

        // 如果 host 不是 localhost 且不是 127.0.0.1，可能为 app://assets/xxx 形式，拼接 host
        if let host = requestURL.host, !host.isEmpty && host != "localhost" && host != "127.0.0.1" {
            let combined = host + "/" + relativePath
            if let found = findFile(relativePath: combined) {
                serveFile(at: found, requestURL: requestURL, task: urlSchemeTask)
                return
            }
        }

        // 寻找目标文件
        if let fileURL = findFile(relativePath: relativePath) {
            serveFile(at: fileURL, requestURL: requestURL, task: urlSchemeTask)
            return
        }

        // SPA 降级回退：如果是页面路由（非静态资源后缀），回退返回 index.html
        let pathExt = (relativePath as NSString).pathExtension.lowercased()
        let isAssetRequest = ["js", "mjs", "css", "png", "jpg", "jpeg", "svg", "webp", "gif", "ico", "woff", "woff2", "ttf", "json", "map"].contains(pathExt)

        if !isAssetRequest, let indexURL = findFile(relativePath: "index.html") {
            serveFile(at: indexURL, requestURL: requestURL, task: urlSchemeTask)
            return
        }

        // 如果依然未找到，按文件名递归搜索
        let fileName = (relativePath as NSString).lastPathComponent
        if let fallbackURL = findFileByName(fileName: fileName) {
            serveFile(at: fallbackURL, requestURL: requestURL, task: urlSchemeTask)
            return
        }

        // 最终返回 404
        let error = NSError(
            domain: "fun.alger.music",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "Resource not found: \(relativePath)"]
        )
        urlSchemeTask.didFailWithError(error)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 请求取消处理，WKWebView 在页面卸载时会触发
    }

    private func findFile(relativePath: String) -> URL? {
        let fm = FileManager.default
        for dir in searchDirectories {
            let candidate = dir.appendingPathComponent(relativePath)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func findFileByName(fileName: String) -> URL? {
        let fm = FileManager.default
        for dir in searchDirectories {
            if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let fileURL as URL in enumerator {
                    if fileURL.lastPathComponent == fileName {
                        return fileURL
                    }
                }
            }
        }
        return nil
    }

    private func serveFile(at fileURL: URL, requestURL: URL, task: WKURLSchemeTask) {
        guard let data = try? Data(contentsOf: fileURL) else {
            let error = NSError(domain: "fun.alger.music", code: 404, userInfo: [NSLocalizedDescriptionKey: "Cannot read data from \(fileURL.path)"])
            task.didFailWithError(error)
            return
        }

        let mimeType = mimeTypeFor(pathExtension: fileURL.pathExtension)
        let headers: [String: String] = [
            "Content-Type": mimeType,
            "Content-Length": "\(data.count)",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS, HEAD",
            "Access-Control-Allow-Headers": "*",
            "Cache-Control": "no-cache"
        ]

        if let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) {
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } else {
            let response = URLResponse(url: requestURL, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: "utf-8")
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }
    }

    private func mimeTypeFor(pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "js", "mjs":
            // WebKit 严格要求 ES Module 脚本必须是 text/javascript
            return "text/javascript; charset=utf-8"
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
