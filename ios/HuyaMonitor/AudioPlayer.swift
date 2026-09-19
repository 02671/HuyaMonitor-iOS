import AVFoundation
import MediaPlayer

@MainActor
final class AudioPlayer {

    static let refreshSec: TimeInterval = 120
    static let overlapSec: TimeInterval = 2.0

    var onStatus: ((_ text: String, _ ok: Bool) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private var player: AVPlayer?
    private var overlapPlayer: AVPlayer?
    private var itemObservation: NSKeyValueObservation?
    private var endedObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var remoteCommandsConfigured = false

    private var roomId = ""
    private var lineIndex = 0
    private var gen = 0
    private var wanted = false
    private var volume: Float = 1.0
    private var loopTask: Task<Void, Never>?
    private var lastTitle: String?
    private var currentDead = false

    var isRunning: Bool { wanted }
    var isPlaying: Bool { player?.timeControlStatus == .playing }

    func start(roomId: String) {
        stop(notify: false)
        wanted = true
        gen += 1
        let currentGen = gen
        self.roomId = roomId
        self.lineIndex = 0
        currentDead = false
        lastTitle = nil
        configureSession()
        configureRemoteCommands()
        observeInterruptions()
        StreamProxy.shared.resetForNewSession()
        onStatus?("音频连接中", false)
        loopTask = Task { await self.runLoop(gen: currentGen) }
    }

    func stop(notify: Bool = true) {
        wanted = false
        gen += 1
        loopTask?.cancel()
        loopTask = nil
        dropPlayers()
        StreamProxy.shared.stop()
        currentDead = false
        lastTitle = nil
        if notify {
            onStatus?("音频未连接", false)
        }
    }

    func setVolume(_ value: Double) {
        volume = Float(max(0, min(1, value)))
        player?.volume = volume
        overlapPlayer?.volume = volume
    }

    func ensurePlaying() {
        guard wanted else { return }
        configureSession()
        if player?.currentItem == nil { return }
        if player?.timeControlStatus != .playing {
            player?.play()
            updateNowPlaying()
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
        updateNowPlaying()
    }

    private func runLoop(gen currentGen: Int) async {
        var fail = 0
        var first = true
        while wanted, currentGen == gen, !Task.isCancelled {
            do {
                if first {
                    onStatus?("音频连接中", false)
                }
                try await StreamProxy.shared.start()
                let room = try await HuyaAPI.fetchRoom(roomId)
                let result = try await HuyaAPI.buildPlayURL(room, lineIndex: lineIndex, ratio: HuyaAPI.defaultBitRate)
                lineIndex = result.lineIndex
                guard wanted, currentGen == gen else { return }
                let incoming = try makePlayer(urlString: result.url, title: room.nick.isEmpty ? room.title : room.nick)
                incoming.play()
                guard wanted, currentGen == gen else {
                    incoming.pause()
                    incoming.replaceCurrentItem(with: nil)
                    return
                }
                let leftover = swap(incoming)
                fail = 0
                first = false
                currentDead = false
                onDiagnostic?("")
                onStatus?("音频已连接", true)
                updateNowPlaying(title: lastTitle)
                if leftover != nil {
                    if await shouldStop(after: Self.overlapSec, gen: currentGen) { return }
                    killOverlap()
                }
                let started = Date()
                var died = false
                while wanted, currentGen == gen, !Task.isCancelled {
                    if isDead(player) || currentDead {
                        died = true
                        break
                    }
                    if Date().timeIntervalSince(started) >= Self.refreshSec {
                        break
                    }
                    if await shouldStop(after: 0.35, gen: currentGen) { return }
                }
                guard wanted, currentGen == gen else { return }
                if died {
                    clearIfCurrent(player)
                    onStatus?("音频重连中", false)
                    lineIndex += 1
                    if await shouldStop(after: 0.4, gen: currentGen) { return }
                }
            } catch {
                guard wanted, currentGen == gen else { return }
                fail += 1
                if !hasPlayingProcess {
                    onStatus?("音频重连中", false)
                }
                onDiagnostic?(error.localizedDescription)
                lineIndex += 1
                first = false
                let delay = min(8.0, 1.2 * Double(fail))
                if await shouldStop(after: delay, gen: currentGen) { return }
            }
        }
        if currentGen == gen {
            wanted = false
            dropPlayers()
            onStatus?("音频未连接", false)
        }
    }

    private func makePlayer(urlString: String, title: String) throws -> AVPlayer {
        guard let httpsURL = URL(string: urlString) else {
            throw HuyaError.message("音频地址无效")
        }
        let playURL = try StreamProxy.shared.playbackURL(from: httpsURL)
        let asset = AVURLAsset(url: playURL, options: ["AVURLAssetHTTPHeaderFieldsKey": HuyaAPI.playbackHeaders])
        let item = AVPlayerItem(asset: asset)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        item.preferredForwardBufferDuration = 8
        let next = AVPlayer(playerItem: item)
        next.automaticallyWaitsToMinimizeStalling = true
        next.volume = volume
        lastTitle = title.isEmpty ? nil : title
        return next
    }

    private func swap(_ incoming: AVPlayer) -> AVPlayer? {
        let leftover = overlapPlayer
        overlapPlayer = player
        player = incoming
        leftover?.pause()
        leftover?.replaceCurrentItem(with: nil)
        observe(incoming)
        return overlapPlayer
    }

    private var hasPlayingProcess: Bool {
        if player?.timeControlStatus == .playing { return true }
        if overlapPlayer?.timeControlStatus == .playing { return true }
        return false
    }

    private func isDead(_ target: AVPlayer?) -> Bool {
        guard let target, let item = target.currentItem else { return true }
        if item.status == .failed { return true }
        if item.error != nil { return true }
        if let events = item.errorLog()?.events {
            for event in events {
                if Self.looksExpired(event.errorComment ?? event.errorDomain) {
                    return true
                }
            }
        }
        return false
    }

    private func shouldStop(after seconds: TimeInterval, gen currentGen: Int) async -> Bool {
        let ns = UInt64(max(0, seconds) * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: ns)
        } catch {
            return true
        }
        return !wanted || gen != currentGen || Task.isCancelled
    }

    private func observe(_ target: AVPlayer) {
        teardownObservers()
        guard let item = target.currentItem else { return }
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.wanted, self.player === target else { return }
                if item.status == .failed {
                    self.currentDead = true
                } else if item.status == .readyToPlay {
                    self.onStatus?("音频已连接", true)
                    self.updateNowPlaying()
                }
            }
        }
        let center = NotificationCenter.default
        failureObserver = center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wanted, self.player === target else { return }
                self.currentDead = true
            }
        }
        endedObserver = center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wanted, self.player === target else { return }
                self.currentDead = true
            }
        }
        stallObserver = center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wanted, self.player === target else { return }
                self.player?.play()
            }
        }
    }

    private func teardownObservers() {
        itemObservation?.invalidate()
        itemObservation = nil
        let center = NotificationCenter.default
        if let failureObserver { center.removeObserver(failureObserver); self.failureObserver = nil }
        if let endedObserver { center.removeObserver(endedObserver); self.endedObserver = nil }
        if let stallObserver { center.removeObserver(stallObserver); self.stallObserver = nil }
    }

    private func killOverlap() {
        overlapPlayer?.pause()
        overlapPlayer?.replaceCurrentItem(with: nil)
        overlapPlayer = nil
    }

    private func clearIfCurrent(_ target: AVPlayer?) {
        teardownObservers()
        if player === target {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
        if overlapPlayer === target {
            overlapPlayer?.pause()
            overlapPlayer?.replaceCurrentItem(with: nil)
            overlapPlayer = nil
        }
    }

    private func dropPlayers() {
        teardownObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        overlapPlayer?.pause()
        overlapPlayer?.replaceCurrentItem(with: nil)
        overlapPlayer = nil
    }

    private static func looksExpired(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("403") || lower.contains("forbidden")
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            onDiagnostic?(error.localizedDescription)
        }
    }

    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, self.wanted else { return }
                let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let type = typeValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                if type == .ended {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.player?.play()
                    self.updateNowPlaying()
                }
            }
        }
    }

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.player?.play()
                self?.updateNowPlaying()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.player?.pause()
                self?.updateNowPlaying()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
    }

    private func updateNowPlaying(title: String? = nil) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        if let title, !title.isEmpty {
            info[MPMediaItemPropertyTitle] = title
        }
        if info[MPMediaItemPropertyTitle] == nil {
            info[MPMediaItemPropertyTitle] = lastTitle ?? "虎牙监控"
        }
        info[MPMediaItemPropertyArtist] = "虎牙监控"
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = (player?.timeControlStatus == .playing) ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
