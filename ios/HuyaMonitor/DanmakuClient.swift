import Foundation

private let danmakuDefaultColor = "#E8ECF2"
private let danmakuURI = 1400
private let danmakuWSURL = "wss://cdnws.api.huya.com"
private let danmakuHeartbeat = Data([0x00, 0x14, 0x1D, 0x00, 0x0C, 0x2C, 0x36, 0x00, 0x4C])

@MainActor
final class DanmakuClient {

    var onMessage: ((_ user: String, _ text: String, _ color: String) -> Void)?
    var onStatus: ((_ text: String, _ ok: Bool) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var heartbeatTimer: Timer?
    private var generation = 0
    private var wanted = false

    private var ayyuid = 0
    private var topSid = 0
    private var subSid = 0

    var isConnected: Bool { task != nil }
    var isWanted: Bool { wanted }

    // MARK: - Control

    func start(ayyuid: Int, topSid: Int, subSid: Int) {
        stop(notify: false)
        self.ayyuid = ayyuid
        self.topSid = topSid
        self.subSid = subSid
        wanted = true
        generation += 1
        onStatus?("弹幕连接中", false)
        connect(generation: generation)
    }

    func stop(notify: Bool = true) {
        wanted = false
        generation += 1
        teardownSocket()
        if notify {
            onStatus?("弹幕未连接", false)
        }
    }

    /// Called when the app returns to the foreground: reconnects if the socket died while suspended.
    func ensureConnected() {
        guard wanted, task == nil else { return }
        generation += 1
        onStatus?("弹幕连接中", false)
        connect(generation: generation)
    }

    // MARK: - Connection

    private func connect(generation gen: Int) {
        guard wanted, gen == generation, let url = URL(string: danmakuWSURL) else { return }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()

        let join = DanmakuClient.buildJoin(ayyuid: ayyuid, tid: topSid, sid: subSid)
        task.send(.data(join)) { [weak self] error in
            Task { @MainActor in
                guard let self, gen == self.generation, self.wanted else { return }
                if let error {
                    self.handleDisconnect(generation: gen, error: error)
                    return
                }
                self.onStatus?("弹幕已连接", true)
                self.receive(generation: gen)
                self.startHeartbeat(generation: gen)
            }
        }
    }

    private func receive(generation gen: Int) {
        guard let task, gen == generation, wanted else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation, self.wanted else { return }
                switch result {
                case .success(let message):
                    if case .data(let data) = message, let chat = DanmakuClient.parseChat(data) {
                        self.onMessage?(chat.user, chat.text, chat.color)
                    }
                    self.receive(generation: gen)
                case .failure(let error):
                    self.handleDisconnect(generation: gen, error: error)
                }
            }
        }
    }

    private func startHeartbeat(generation gen: Int) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.generation, self.wanted else { return }
                self.task?.send(.data(danmakuHeartbeat)) { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor in
                        self?.handleDisconnect(generation: gen, error: error)
                    }
                }
            }
        }
    }

    private func handleDisconnect(generation gen: Int, error: Error?) {
        guard gen == generation, wanted else { return }
        teardownSocket()
        onStatus?("弹幕未连接", false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            Task { @MainActor in
                guard let self, gen == self.generation, self.wanted else { return }
                self.onStatus?("弹幕连接中", false)
                self.connect(generation: gen)
            }
        }
    }

    private func teardownSocket() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Wire format

    nonisolated static func buildJoin(ayyuid: Int, tid: Int, sid: Int) -> Data {
        let inner = TarsOutput()
        inner.writeInt(ayyuid, tag: 0)
        inner.writeBool(true, tag: 1)
        inner.writeString("", tag: 2)
        inner.writeString("", tag: 3)
        inner.writeInt(tid, tag: 4)
        inner.writeInt(sid, tag: 5)
        inner.writeInt(0, tag: 6)
        inner.writeInt(0, tag: 7)

        let outer = TarsOutput()
        outer.writeInt(1, tag: 0)
        outer.writeBytes(inner.toData(), tag: 1)
        return outer.toData()
    }

    nonisolated static func parseChat(_ data: Data) -> (user: String, text: String, color: String)? {
        let stream = TarsInput(data)
        guard stream.readInt(tag: 0) == 7 else { return nil }
        let body = stream.readBytes(tag: 1)
        guard !body.isEmpty else { return nil }

        let push = TarsInput(body)
        guard push.readInt(tag: 1) == danmakuURI else { return nil }
        let message = push.readBytes(tag: 2)
        guard !message.isEmpty else { return nil }

        let notice = TarsInput(message)
        var nick = ""
        if let userBlob = notice.readStructBytes(tag: 0), !userBlob.isEmpty {
            nick = TarsInput(userBlob).readString(tag: 2)
        }
        let content = notice.readString(tag: 3)
        guard !content.isEmpty else { return nil }

        var color = danmakuDefaultColor
        if let colorBlob = TarsInput(message).readStructBytes(tag: 6), !colorBlob.isEmpty {
            color = rgbHex(TarsInput(colorBlob).readInt(tag: 0, fallback: -1))
        }
        return (nick.isEmpty ? "匿名" : nick, content, color)
    }

    nonisolated static func rgbHex(_ value: Int) -> String {
        if value < 0 || value == 0 || value == 0xFFFFFF {
            return danmakuDefaultColor
        }
        return String(format: "#%06X", value & 0xFFFFFF)
    }
}
