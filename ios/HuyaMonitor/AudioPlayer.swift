import AVFoundation
import MediaPlayer

@MainActor
final class AudioPlayer {

    var onStatus: ((_ text: String, _ ok: Bool) -> Void)?

    private var player: AVPlayer?
    private var refreshTimer: Timer?
    private var itemObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var remoteCommandsConfigured = false

    private var roomId = ""
    private var lineIndex = 0
    private var generation = 0
    private var wanted = false
    private var volume: Float = 1.0

    private let refreshInterval: TimeInterval = 300

    var isRunning: Bool { wanted }
    var isPlaying: Bool { player?.timeControlStatus == .playing }

    // MARK: - Control

    func start(roomId: String) {
        stop(notify: false)
        wanted = true
        generation += 1
        self.roomId = roomId
        self.lineIndex = 0
        configureSession()
        configureRemoteCommands()
        onStatus?("音频连接中", false)
        let gen = generation
        Task { await self.loadAndPlay(generation: gen) }
    }

    func stop(notify: Bool = true) {
        wanted = false
        generation += 1
        refreshTimer?.invalidate()
        refreshTimer = nil
        itemObservation = nil
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if notify {
            onStatus?("音频未连接", false)
        }
    }

    func setVolume(_ value: Double) {
        volume = Float(max(0, min(1, value)))
        player?.volume = volume
    }

    func ensurePlaying() {
        guard wanted else { return }
        if player == nil {
            let gen = generation
            Task { await self.loadAndPlay(generation: gen) }
        } else if player?.timeControlStatus != .playing {
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

    // MARK: - Loading

    private func loadAndPlay(generation gen: Int) async {
        guard wanted, gen == generation else { return }
        do {
            let room = try await HuyaAPI.fetchRoom(roomId)
            let result = try await HuyaAPI.buildPlayURL(room, lineIndex: lineIndex)
            lineIndex = result.lineIndex
            guard wanted, gen == generation else { return }
            replaceItem(urlString: result.url, room: room, generation: gen)
        } catch {
            guard wanted, gen == generation else { return }
            onStatus?("音频重连中", false)
            scheduleReload(generation: gen, delay: 3, advanceLine: true)
        }
    }

    private func replaceItem(urlString: String, room: HuyaRoom, generation gen: Int) {
        guard let url = URL(string: urlString) else {
            scheduleReload(generation: gen, delay: 2, advanceLine: true)
            return
        }
        let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": HuyaAPI.playbackHeaders]
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2
        // Belt and braces: `ratio` pins the CDN rendition, and this caps HLS variant
        // selection so AVPlayer cannot quietly upgrade to a higher-bitrate rendition.
        if let lowest = room.lowestBitRate, lowest > 0 {
            item.preferredPeakBitRate = Double(lowest) * 1200
        }

        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.automaticallyWaitsToMinimizeStalling = true
            player = newPlayer
        }
        player?.volume = volume
        observe(item: item, generation: gen)
        player?.play()
        onStatus?("音频已连接", true)
        let title = room.nick.isEmpty ? room.title : room.nick
        updateNowPlaying(title: title.isEmpty ? nil : title)
        scheduleRefresh(generation: gen)
    }

    private func scheduleRefresh(generation gen: Int) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wanted, gen == self.generation else { return }
                await self.loadAndPlay(generation: gen)
            }
        }
    }

    private func scheduleReload(generation gen: Int, delay: TimeInterval, advanceLine: Bool) {
        if advanceLine {
            lineIndex += 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in
                guard let self, self.wanted, gen == self.generation else { return }
                await self.loadAndPlay(generation: gen)
            }
        }
    }

    private func observe(item: AVPlayerItem, generation gen: Int) {
        removeObservers()
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, self.wanted, gen == self.generation else { return }
                self.onStatus?("音频重连中", false)
                self.scheduleReload(generation: gen, delay: 1.5, advanceLine: true)
            }
        }
        let center = NotificationCenter.default
        failureObserver = center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wanted, gen == self.generation else { return }
                self.onStatus?("音频重连中", false)
                self.scheduleReload(generation: gen, delay: 1.5, advanceLine: true)
            }
        }
        stallObserver = center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wanted, gen == self.generation else { return }
                self.player?.play()
            }
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        if let failureObserver {
            center.removeObserver(failureObserver)
            self.failureObserver = nil
        }
        if let stallObserver {
            center.removeObserver(stallObserver)
            self.stallObserver = nil
        }
    }

    // MARK: - Background audio session

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            // Foreground playback still works; the .playback category is what enables lock-screen audio.
        }
    }

    // MARK: - Lock screen controls

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.pause() }
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
            info[MPMediaItemPropertyTitle] = "虎牙监控"
        }
        info[MPMediaItemPropertyArtist] = "虎牙监控"
        info[MPNowPlayingInfoPropertyPlaybackRate] = (player?.timeControlStatus == .playing) ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
