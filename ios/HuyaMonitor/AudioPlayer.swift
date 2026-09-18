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
    private var controlObservation: NSKeyValueObservation?
    private var overlapItemObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var endedObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var errorLogObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var remoteCommandsConfigured = false

    private var roomId = ""
    private var lineIndex = 0
    private var token = 0
    private var wanted = false
    private var volume: Float = 1.0
    private var reconnectItem: DispatchWorkItem?
    private var readyWatchdog: DispatchWorkItem?
    private var refreshItem: DispatchWorkItem?
    private var overlapItem: DispatchWorkItem?
    private var reconnectDelay: TimeInterval = 2.5
    private var loadTask: Task<Void, Never>?
    private var lastTitle: String?

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
        refreshItem?.cancel()
        refreshItem = nil
        overlapItem?.cancel()
        overlapItem = nil
        teardownItem()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        dropOverlap()
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
        refreshItem?.cancel()
        refreshItem = nil
        loadTask?.cancel()
        onStatus?("音频连接中", false)
        loadTask = Task { await self.loadAndPlay(id: id, overlap: false) }
    }

    private func refresh() {
        guard wanted else { return }
        let id = token
        loadTask?.cancel()
        loadTask = Task { await self.loadAndPlay(id: id, overlap: true) }
    }

    private func loadAndPlay(id: Int, overlap: Bool) async {
        guard wanted, id == token else { return }
        do {
            try await StreamProxy.shared.start()
            let room = try await HuyaAPI.fetchRoom(roomId)
            let result = try await HuyaAPI.buildPlayURL(room, lineIndex: lineIndex)
            lineIndex = result.lineIndex
            guard wanted, id == token else { return }
            attach(urlString: result.url, room: room, id: id, overlap: overlap)
        } catch {
            guard wanted, id == token else { return }
            if overlap {
                onDiagnostic?(error.localizedDescription)
                armRefresh(id: id)
            } else {
                fail(id: id, reason: error.localizedDescription)
            }
        }
    }

    private func attach(urlString: String, room: HuyaRoom, id: Int, overlap: Bool) {
        guard wanted, id == token else { return }
        guard let httpsURL = URL(string: urlString) else {
            fail(id: id, reason: "音频地址无效")
            return
        }
        let playURL: URL
        do {
            playURL = try StreamProxy.shared.playbackURL(from: httpsURL)
        } catch {
            fail(id: id, reason: error.localizedDescription)
            return
        }

        let headers: [String: String] = HuyaAPI.playbackHeaders
        let asset = AVURLAsset(url: playURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        item.preferredForwardBufferDuration = 8

        let title = room.nick.isEmpty ? room.title : room.nick
        lastTitle = title.isEmpty ? nil : title

        if overlap, player?.currentItem != nil {
            beginOverlap(item: item, id: id)
        } else {
            replace(item: item, id: id)
            armReadyWatchdog(id: id)
        }
        updateNowPlaying(title: lastTitle)
    }

    private func replace(item: AVPlayerItem, id: Int) {
        dropOverlap()
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
    }

    private func beginOverlap(item: AVPlayerItem, id: Int) {
        overlapItem?.cancel()
        overlapItemObservation?.invalidate()
        overlapPlayer?.pause()
        overlapPlayer?.replaceCurrentItem(with: nil)

        let incoming = AVPlayer(playerItem: item)
        incoming.automaticallyWaitsToMinimizeStalling = true
        incoming.volume = volume
        overlapPlayer = incoming
        overlapItemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                if item.status == .readyToPlay {
                    incoming.play()
                    self.finishOverlap(id: id)
                } else if item.status == .failed {
                    self.overlapItemObservation?.invalidate()
                    self.overlapItemObservation = nil
                    incoming.pause()
                    self.overlapPlayer = nil
                    let reason = item.error?.localizedDescription ?? "换链失败"
                    self.onDiagnostic?(reason)
                    self.armRefresh(id: id)
                }
            }
        }
        incoming.play()
        overlapItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                guard self.overlapPlayer === incoming else { return }
                self.dropOverlap()
                self.onDiagnostic?("换链超时，继续当前音频")
                self.armRefresh(id: id)
            }
        }
        overlapItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    private func finishOverlap(id: Int) {
        overlapItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                guard let incoming = self.overlapPlayer else { return }
                self.teardownItem()
                self.player?.pause()
                self.player?.replaceCurrentItem(with: nil)
                self.player = incoming
                self.overlapPlayer = nil
                self.overlapItemObservation?.invalidate()
                self.overlapItemObservation = nil
                if let item = incoming.currentItem {
                    self.observe(item: item, id: id)
                }
                incoming.play()
                self.reconnectDelay = 2.5
                self.onDiagnostic?("")
                self.onStatus?("音频已连接", true)
                self.armRefresh(id: id)
                self.updateNowPlaying()
            }
        }
        overlapItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlapSec, execute: work)
    }

    private func dropOverlap() {
        overlapItem?.cancel()
        overlapItem = nil
        overlapItemObservation?.invalidate()
        overlapItemObservation = nil
        overlapPlayer?.pause()
        overlapPlayer?.replaceCurrentItem(with: nil)
        overlapPlayer = nil
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

    private func armRefresh(id: Int) {
        refreshItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                self.refresh()
            }
        }
        refreshItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshSec, execute: item)
    }

    private func fail(id: Int, reason: String) {
        guard wanted, id == token else { return }
        onDiagnostic?(reason)
        token += 1
        loadTask?.cancel()
        loadTask = nil
        readyWatchdog?.cancel()
        readyWatchdog = nil
        refreshItem?.cancel()
        refreshItem = nil
        dropOverlap()
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
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
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
                    self.armRefresh(id: id)
                    self.updateNowPlaying()
                case .failed:
                    let reason = Self.describe(item.error) ?? "播放失败"
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
                self.fail(id: id, reason: Self.describe(error) ?? "播放中断")
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

    private static func describe(_ error: Error?) -> String? {
        guard let error else { return nil }
        let ns = error as NSError
        if ns.domain == "CoreMediaErrorDomain" && ns.code == -12881 {
            return "播放器拒绝自定义地址的分片（已改为本地代理）"
        }
        return error.localizedDescription
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
