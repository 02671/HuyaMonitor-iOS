import Foundation

private let danmakuDefaultColor = "#E8ECF2"
private let danmakuURI = 1400
private let danmakuWSURL = "wss://cdnws.api.huya.com"
private let danmakuHeartbeat = Data([0x00, 0x14, 0x1D, 0x00, 0x0C, 0x2C, 0x36, 0x00, 0x4C])

@MainActor
final class DanmakuClient {

    var onMessage: ((_ user: String, _ text: String, _ color: String) -> Void)?
    var onStatus: ((_ text: String, _ ok: Bool) -> Void)?
    /// Reason for the most recent disconnect, so the UI can show what actually failed.
    var onDiagnostic: ((String) -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private var task: URLSessionWebSocketTask?
    private var heartbeatTimer: Timer?
    private var reconnectItem: DispatchWorkItem?

    /// Identifies the in-flight connection. Every asynchronous callback captures the token
    /// it was created with and returns early once the token has moved on. Tearing a socket
    /// down bumps the token *first*, so the cancellation callbacks that URLSession fires
    /// can no longer start a competing reconnect chain.
    private var token = 0
    private var wanted = false
    private var ayyuid = 0
    private var topSid = 0
    private var subSid = 0
    private var reconnectDelay: TimeInterval = 2.5

    var isConnected: Bool { task != nil }
    var isWanted: Bool { wanted }

    // MARK: - Control

    func start(ayyuid: Int, topSid: Int, subSid: Int) {
        stop(notify: false)
        self.ayyuid = ayyuid
        self.topSid = topSid
        self.subSid = subSid
        wanted = true
        reconnectDelay = 2.5
        openNewConnection()
    }

    func stop(notify: Bool = true) {
        wanted = false
        token += 1
        reconnectItem?.cancel()
        reconnectItem = nil
        teardown()
        if notify {
            onStatus?("弹幕未连接", false)
        }
    }

    /// Called when the app returns to the foreground: reconnects if the socket died while
    /// the app was suspended. Does nothing while a reconnect is already pending.
    func ensureConnected() {
        guard wanted, task == nil, reconnectItem == nil else { return }
        openNewConnection()
    }

    // MARK: - Connection lifecycle

    private func openNewConnection() {
        guard wanted else { return }
        token += 1
        let id = token
        teardown()
        onStatus?("弹幕连接中", false)
        open(id)
    }

    private func open(_ id: Int) {
        guard wanted, id == token, let url = URL(string: danmakuWSURL) else { return }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()

        let join = DanmakuClient.buildJoin(ayyuid: ayyuid, tid: topSid, sid: subSid)
        task.send(.data(join)) { [weak self] error in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                if let error {
                    self.fail(id: id, reason: error.localizedDescription)
                    return
                }
                self.onStatus?("弹幕已连接", true)
                self.receive(id)
                self.startHeartbeat(id)
            }
        }
    }

    private func receive(_ id: Int) {
        guard wanted, id == token, let task else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                switch result {
                case .success(let message):
                    self.reconnectDelay = 2.5
                    if case .data(let data) = message,
                       let chat = DanmakuClient.parseChat(data) {
                        self.onMessage?(chat.user, chat.text, chat.color)
                    }
                    self.receive(id)
                case .failure(let error):
                    self.fail(id: id, reason: error.localizedDescription)
                }
            }
        }
    }

    private func startHeartbeat(_ id: Int) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token, let task = self.task else { return }
                task.send(.data(danmakuHeartbeat)) { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor in
                        guard let self, self.wanted, id == self.token else { return }
                        self.fail(id: id, reason: error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Tears the current socket down and schedules exactly one reconnect attempt.
    private func fail(id: Int, reason: String) {
        guard wanted, id == token else { return }
        onDiagnostic?(reason)
        // Bump the token before teardown so the receive cancellation callback cannot
        // schedule a second, competing reconnect.
        token += 1
        teardown()
        onStatus?("弹幕未连接", false)
        scheduleReconnect(after: reconnectDelay)
        reconnectDelay = min(reconnectDelay * 1.5, 30)
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        guard wanted, reconnectItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.wanted else { return }
                self.reconnectItem = nil
                self.openNewConnection()
            }
        }
        reconnectItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func teardown() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
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
