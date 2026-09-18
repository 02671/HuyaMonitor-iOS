import AVFoundation
import MediaPlayer

@MainActor
final class AudioPlayer {

    var onStatus: ((_ text: String, _ ok: Bool) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private var player: AVPlayer?
    private var itemObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var endedObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var errorLogObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var remoteCommandsConfigured = false

    private let loader = StreamLoader()
    private let loaderQueue = DispatchQueue(label: "huya.audio.resource")

    private var roomId = ""
    private var lineIndex = 0
    private var token = 0
    private var wanted = false
    private var volume: Float = 1.0
    private var reconnectItem: DispatchWorkItem?
    private var readyWatchdog: DispatchWorkItem?
    private var reconnectDelay: TimeInterval = 2.5
    private var loadTask: Task<Void, Never>?

    var isRunning: Bool { wanted }
    var isPlaying: Bool { player?.timeControlStatus == .playing }

    // MARK: - Control

    func start(roomId: String) {
        stop(notify: false)
        wanted = true
        self.roomId = roomId
        self.lineIndex = 0
        reconnectDelay = 2.5
        configureSession()
        configureRemoteCommands()
        observeInterruptions()
        onStatus?("音频连接中", false)
        open()
    }

    func stop(notify: Bool = true) {
        wanted = false
        token += 1
        loadTask?.cancel()
        loadTask = nil
        reconnectItem?.cancel()
        reconnectItem = nil
        readyWatchdog?.cancel()
        readyWatchdog = nil
        teardownItem()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
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
        if player?.currentItem == nil {
            open()
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

    private func open() {
        guard wanted else { return }
        token += 1
        let id = token
        reconnectItem?.cancel()
        reconnectItem = nil
        readyWatchdog?.cancel()
        readyWatchdog = nil
        loadTask?.cancel()
        onStatus?("音频连接中", false)
        loadTask = Task { await self.loadAndPlay(id: id) }
    }

    private func loadAndPlay(id: Int) async {
        guard wanted, id == token else { return }
        do {
            let room = try await HuyaAPI.fetchRoom(roomId)
            let result = try await HuyaAPI.buildPlayURL(room, lineIndex: lineIndex)
            lineIndex = result.lineIndex
            guard wanted, id == token else { return }
            replaceItem(urlString: result.url, room: room, id: id)
        } catch {
            guard wanted, id == token else { return }
            fail(id: id, reason: error.localizedDescription)
        }
    }

    private func replaceItem(urlString: String, room: HuyaRoom, id: Int) {
        guard wanted, id == token else { return }
        guard let httpsURL = URL(string: urlString) else {
            fail(id: id, reason: "音频地址无效")
            return
        }
        let playURL = StreamLoader.playbackURL(from: httpsURL)
        let asset = AVURLAsset(url: playURL)
        asset.resourceLoader.setDelegate(loader, queue: loaderQueue)

        let item = AVPlayerItem(asset: asset)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        item.preferredForwardBufferDuration = 8

        teardownItem()
        if player == nil {
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.automaticallyWaitsToMinimizeStalling = true
            player = newPlayer
        } else {
            player?.replaceCurrentItem(with: item)
        }
        player?.volume = volume
        observe(item: item, id: id)
        player?.play()
        let title = room.nick.isEmpty ? room.title : room.nick
        updateNowPlaying(title: title.isEmpty ? nil : title)
        armReadyWatchdog(id: id)
    }

    private func armReadyWatchdog(id: Int) {
        readyWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                let status = self.player?.currentItem?.status
                if status != .readyToPlay {
                    self.fail(id: id, reason: "音频在限定时间内未能开始播放")
                }
            }
        }
        readyWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: item)
    }

    private func fail(id: Int, reason: String) {
        guard wanted, id == token else { return }
        onDiagnostic?(reason)
        token += 1
        loadTask?.cancel()
        loadTask = nil
        readyWatchdog?.cancel()
        readyWatchdog = nil
        teardownItem()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        onStatus?("音频重连中", false)
        lineIndex += 1
        scheduleReconnect(after: reconnectDelay)
        reconnectDelay = min(reconnectDelay * 1.5, 20)
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        guard wanted, reconnectItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.wanted else { return }
                self.reconnectItem = nil
                self.open()
            }
        }
        reconnectItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func observe(item: AVPlayerItem, id: Int) {
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                switch item.status {
                case .readyToPlay:
                    self.readyWatchdog?.cancel()
                    self.readyWatchdog = nil
                    self.reconnectDelay = 2.5
                    self.onDiagnostic?("")
                    self.onStatus?("音频已连接", true)
                    self.player?.play()
                    self.updateNowPlaying()
                case .failed:
                    let reason = item.error?.localizedDescription ?? "播放失败"
                    self.fail(id: id, reason: reason)
                default:
                    break
                }
            }
        }
        controlObservation = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                self.updateNowPlaying()
                if player.timeControlStatus == .playing {
                    self.readyWatchdog?.cancel()
                    self.readyWatchdog = nil
                    self.onStatus?("音频已连接", true)
                }
            }
        }
        let center = NotificationCenter.default
        failureObserver = center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self.fail(id: id, reason: error?.localizedDescription ?? "播放中断")
            }
        }
        endedObserver = center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                self.fail(id: id, reason: "音频流结束")
            }
        }
        stallObserver = center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                self.player?.play()
            }
        }
        errorLogObserver = center.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                if let last = item.errorLog()?.events.last {
                    let comment = last.errorComment ?? last.errorDomain
                    if !comment.isEmpty {
                        self.onDiagnostic?(comment)
                    }
                }
            }
        }
    }

    private func teardownItem() {
        itemObservation = nil
        controlObservation = nil
        let center = NotificationCenter.default
        if let failureObserver { center.removeObserver(failureObserver); self.failureObserver = nil }
        if let endedObserver { center.removeObserver(endedObserver); self.endedObserver = nil }
        if let stallObserver { center.removeObserver(stallObserver); self.stallObserver = nil }
        if let errorLogObserver { center.removeObserver(errorLogObserver); self.errorLogObserver = nil }
    }

    // MARK: - Session

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
                }
            }
        }
    }

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
