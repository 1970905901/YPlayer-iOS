import AVFoundation
import MediaPlayer
import UIKit

/// Native audio/Now Playing owner for iOS.
/// WKWebView cannot reliably start audio or restore Now Playing while backgrounded,
/// so actual playback lives in AVPlayer and the web UI mirrors its state.
final class NativeAudioManager {
    static let shared = NativeAudioManager()

    var onEvent: ((String, [String: Any]) -> Void)?
    var onRemoteCommand: ((String) -> Void)?

    private let player = AVPlayer()
    private var currentItem: AVPlayerItem?
    private var itemStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    private var currentURL = ""
    private var metadata: [String: Any] = [:]
    private var baseArtist = ""
    private var currentLyric = ""
    private var artwork: MPMediaItemArtwork?
    private var artworkURL = ""
    private var artworkTask: URLSessionDataTask?
    private let artworkCache = NSCache<NSString, UIImage>()

    private var isPlaying = false
    private var userPlayIntent = false
    private var pendingAutoplay = false
    private var pendingStartTime: Double = 0
    private var currentRate: Float = 1
    private var currentVolume: Float = 1
    private var duration: Double = 0
    private var currentTime: Double = 0
    private var isInterruptionActive = false
    private var isCategoryConfigured = false
    private var remoteCommandsConfigured = false
    private var isStarted = false

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true

        artworkCache.countLimit = 30
        artworkCache.totalCostLimit = 64 * 1024 * 1024
        configureAudioSession(activate: false)
        setupObservers()
        setupRemoteCommands()
        setupTimeObserver()
    }

    // MARK: - Audio Session

    private func configureAudioSession(activate: Bool = true) {
        do {
            let session = AVAudioSession.sharedInstance()
            if !isCategoryConfigured || session.category != .playback {
                try session.setCategory(
                    .playback,
                    mode: .default,
                    options: [.mixWithOthers, .allowAirPlay, .allowBluetoothA2DP]
                )
                isCategoryConfigured = true
            }
            if activate {
                try session.setActive(true)
            }
        } catch {
            print("[NativeAudioManager] configure audio session failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Observers

    private func setupObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }

        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isCategoryConfigured = false
            self.configureAudioSession(activate: false)
            if self.userPlayIntent {
                self.play()
            }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.emitStateSnapshot()
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }

        switch type {
        case .began:
            isInterruptionActive = true
            emit("interruptionBegan", ["intent": userPlayIntent])
            pauseInternal(preserveIntent: true)
            print("[NativeAudioManager] interruption began; user intent preserved: \(userPlayIntent)")
        case .ended:
            isInterruptionActive = false
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            emit("interruptionEnded", [
                "intent": userPlayIntent,
                "shouldResume": options.contains(.shouldResume)
            ])
            print("[NativeAudioManager] interruption ended; shouldResume=\(options.contains(.shouldResume)); intent=\(userPlayIntent)")
            if userPlayIntent {
                play()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
              reason == .oldDeviceUnavailable else {
            return
        }
        pause()
    }

    private func setupTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            let seconds = time.seconds
            if seconds.isFinite {
                self.currentTime = max(0, seconds)
            }
            if let itemDuration = self.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                self.duration = itemDuration
            }
            if UIApplication.shared.applicationState == .active {
                self.emit("timeupdate", [
                    "currentTime": self.currentTime,
                    "duration": self.duration
                ])
            }
        }
    }

    // MARK: - Load / Playback

    func load(_ payload: [String: Any]) {
        guard let urlString = payload["url"] as? String, !urlString.isEmpty else {
            emit("error", ["code": 4, "message": "invalid-audio-url"])
            return
        }

        let url: URL
        if urlString.hasPrefix("local://"), let parsed = URL(string: urlString) {
            let path = parsed.path.removingPercentEncoding ?? parsed.path
            url = URL(fileURLWithPath: path)
        } else if let remote = URL(string: urlString) {
            url = remote
        } else {
            emit("error", ["code": 4, "message": "invalid-audio-url"])
            return
        }

        stopInternal(clearMetadata: false)
        currentURL = urlString
        applyMetadata(payload)
        pendingStartTime = number(payload["position"])
        currentRate = Float(number(payload["rate"]) > 0 ? number(payload["rate"]) : 1)
        currentVolume = Float(number(payload["volume"]) > 0 ? number(payload["volume"]) : 1)
        pendingAutoplay = payload["autoplay"] as? Bool ?? false
        userPlayIntent = pendingAutoplay
        player.volume = currentVolume

        let item = AVPlayerItem(url: url)
        currentItem = item
        observeItem(item)
        observeEnd(item)
        player.replaceCurrentItem(with: item)
        updateNowPlaying()
        print("[NativeAudioManager] load \(urlString)")
    }

    func play() {
        userPlayIntent = true
        guard let item = currentItem else {
            emit("error", ["code": 4, "message": "native-audio-not-loaded"])
            return
        }
        guard item.status == .readyToPlay else {
            pendingAutoplay = true
            return
        }
        playInternal()
    }

    func pause() {
        pauseInternal(preserveIntent: false)
    }

    func stop() {
        stopInternal(clearMetadata: true)
    }

    func seek(to time: Double) {
        guard time.isFinite, time >= 0 else { return }
        currentTime = time
        guard let item = currentItem else { return }
        if item.status != .readyToPlay {
            pendingStartTime = time
            return
        }
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            guard finished, let self = self else { return }
            self.updateNowPlaying()
            self.emit("seeked", [
                "currentTime": self.currentTime,
                "duration": self.duration
            ])
        }
    }

    func setRate(_ rate: Double) {
        currentRate = Float(rate > 0 ? rate : 1)
        if isPlaying {
            player.rate = currentRate
            updateNowPlaying()
        }
    }

    func setVolume(_ volume: Double) {
        currentVolume = Float(max(0, min(1, volume)))
        player.volume = currentVolume
    }

    func updateMetadata(_ payload: [String: Any]) {
        applyMetadata(payload)
        updateNowPlaying()
    }

    func updateLyric(_ text: String) {
        currentLyric = text.trimmingCharacters(in: .whitespacesAndNewlines)
        updateNowPlaying()
    }

    func refreshStateForForeground() {
        emitStateSnapshot()
        updateNowPlaying()
    }

    func prefetchArtwork(from urlString: String) {
        guard !urlString.isEmpty,
              artworkCache.object(forKey: urlString as NSString) == nil,
              let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 12
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self, error == nil,
                  let data = data, let image = UIImage(data: data) else { return }
            self.artworkCache.setObject(
                image,
                forKey: urlString as NSString,
                cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
            )
        }.resume()
    }

    func clearArtworkCache() {
        artworkCache.removeAllObjects()
        artworkTask?.cancel()
        artworkTask = nil
    }

    private func playInternal() {
        guard let item = currentItem, item.status == .readyToPlay else {
            pendingAutoplay = true
            return
        }
        configureAudioSession()
        player.play()
        player.rate = currentRate
        isPlaying = true
        pendingAutoplay = false
        updateNowPlaying()
        emit("play", [
            "currentTime": currentTime,
            "duration": duration
        ])
    }

    private func pauseInternal(preserveIntent: Bool) {
        if !preserveIntent {
            userPlayIntent = false
        }
        player.pause()
        pendingAutoplay = false
        isPlaying = false
        updateNowPlaying()
        emit("pause", [
            "currentTime": currentTime,
            "duration": duration
        ])
    }

    private func stopInternal(clearMetadata: Bool) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        pendingAutoplay = false
        currentItem = nil
        itemStatusObservation = nil
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
        artworkTask?.cancel()
        artworkTask = nil
        if clearMetadata {
            userPlayIntent = false
            currentURL = ""
            metadata = [:]
            baseArtist = ""
            currentLyric = ""
            artwork = nil
            artworkURL = ""
            duration = 0
            currentTime = 0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
    }

    private func observeItem(_ item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                self?.handleItemStatus(observedItem)
            }
        }
    }

    private func handleItemStatus(_ item: AVPlayerItem) {
        guard item === currentItem else { return }
        switch item.status {
        case .readyToPlay:
            let itemDuration = item.duration.seconds
            if itemDuration.isFinite, itemDuration > 0 {
                duration = itemDuration
            }
            if pendingStartTime > 0 {
                currentTime = pendingStartTime
                player.seek(to: CMTime(seconds: pendingStartTime, preferredTimescale: 600))
                pendingStartTime = 0
            }
            emit("loadedmetadata", [
                "currentTime": currentTime,
                "duration": duration
            ])
            emit("durationchange", ["duration": duration])
            emit("canplay", ["duration": duration])
            updateNowPlaying()
            if pendingAutoplay {
                playInternal()
            }
        case .failed:
            let message = item.error?.localizedDescription ?? "native-audio-item-failed"
            print("[NativeAudioManager] item failed: \(message)")
            emit("error", ["code": 4, "message": message])
        default:
            break
        }
    }

    private func observeEnd(_ item: AVPlayerItem) {
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isPlaying = false
            self.userPlayIntent = false
            self.updateNowPlaying()
            self.emit("ended", [
                "currentTime": self.duration,
                "duration": self.duration
            ])
        }
    }

    // MARK: - Metadata / Now Playing

    private func applyMetadata(_ payload: [String: Any]) {
        let previousTitle = string(metadata["title"])
        let newTitle = string(payload["title"])
        metadata = payload
        baseArtist = string(payload["artist"])
        if !newTitle.isEmpty, newTitle != previousTitle {
            currentLyric = ""
        }
        let newArtworkURL = string(payload["artworkUrl"])
        if newArtworkURL != artworkURL {
            artwork = nil
            artworkURL = newArtworkURL
            if newArtworkURL.isEmpty {
                artworkTask?.cancel()
                artworkTask = nil
            } else {
                loadArtwork(from: newArtworkURL)
            }
        }
    }

    private func updateNowPlaying() {
        let title = string(metadata["title"]).isEmpty ? "未知曲目" : string(metadata["title"])
        let album = string(metadata["album"])
        let displayArtist = currentLyric.isEmpty
            ? (baseArtist.isEmpty ? " " : baseArtist)
            : currentLyric

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: displayArtist,
            MPMediaItemPropertyAlbumTitle: album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(currentRate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork = artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func loadArtwork(from urlString: String) {
        artworkURL = urlString
        if let cached = artworkCache.object(forKey: urlString as NSString) {
            artwork = createArtwork(from: cached)
            updateNowPlaying()
            return
        }

        if urlString.hasPrefix("local://"), let parsed = URL(string: urlString) {
            let path = parsed.path.removingPercentEncoding ?? parsed.path
            if let image = UIImage(contentsOfFile: path) {
                artworkCache.setObject(
                    image,
                    forKey: urlString as NSString,
                    cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
                )
                artwork = createArtwork(from: image)
                updateNowPlaying()
            }
            return
        }

        guard let url = URL(string: urlString) else { return }
        artworkTask?.cancel()
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 12
        if let host = url.host?.lowercased(), host.contains("163.com") || host.contains("126.net") {
            request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        }

        artworkTask = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self, error == nil,
                  let data = data, let image = UIImage(data: data) else {
                return
            }
            self.artworkCache.setObject(
                image,
                forKey: urlString as NSString,
                cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
            )
            DispatchQueue.main.async {
                guard self.artworkURL == urlString else { return }
                self.artwork = self.createArtwork(from: image)
                self.updateNowPlaying()
            }
        }
        artworkTask?.resume()
    }

    private func createArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { requestedSize in
            guard requestedSize.width > 0, requestedSize.height > 0 else { return image }
            if abs(requestedSize.width - image.size.width) < 1,
               abs(requestedSize.height - image.size.height) < 1 {
                return image
            }
            let renderer = UIGraphicsImageRenderer(size: requestedSize)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: requestedSize))
            }
        }
    }

    // MARK: - Remote Commands

    private func setupRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.stopCommand.isEnabled = false

        center.playCommand.removeTarget(nil)
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.play() }
            return .success
        }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }
            return .success
        }

        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPlaying ? self.pause() : self.play()
            }
            return .success
        }

        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            DispatchQueue.main.async { self?.seek(to: positionEvent.positionTime) }
            return .success
        }

        center.nextTrackCommand.removeTarget(nil)
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onRemoteCommand?("nextTrack") }
            return .success
        }

        center.previousTrackCommand.removeTarget(nil)
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onRemoteCommand?("previousTrack") }
            return .success
        }
    }

    // MARK: - Events

    private func emitStateSnapshot() {
        emit("durationchange", ["duration": duration])
        emit("timeupdate", ["currentTime": currentTime, "duration": duration])
        emit(isPlaying ? "play" : "pause", ["currentTime": currentTime, "duration": duration])
    }

    private func emit(_ event: String, _ payload: [String: Any] = [:]) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event, payload)
        }
    }

    private func number(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Int { return Double(value) }
        return 0
    }

    private func string(_ value: Any?) -> String {
        value as? String ?? ""
    }
}
