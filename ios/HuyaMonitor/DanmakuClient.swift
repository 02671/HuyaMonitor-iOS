import Foundation
import Network
import CryptoKit

private let danmakuDefaultColor = "#E8ECF2"
private let danmakuURI = 1400
private let danmakuHost = "cdnws.api.huya.com"
private let danmakuPort: UInt16 = 443
private let danmakuHeartbeat = Data([0x00, 0x14, 0x1D, 0x00, 0x0C, 0x2C, 0x36, 0x00, 0x4C])
private let webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
private let maxFrameSize = 4 * 1024 * 1024

/// Minimal WebSocket client built directly on Network.framework.
///
/// `URLSessionWebSocketTask` cannot be used for this server. It offers
/// `Sec-WebSocket-Extensions: permessage-deflate` during the upgrade, Huya's CDN accepts
/// it and then sends RSV1-compressed data frames, and URLSession's WebSocket layer fails
/// on them with EPROTO ("Protocol error"). Verified against the live endpoint: when the
/// extension is not offered the server returns no `Sec-WebSocket-Extensions` header and
/// every frame arrives uncompressed (16/16 frames, rsv1=0, connection stable for 70s+).
///
/// Network.framework lets us write the upgrade request by hand, so we simply never offer
/// the extension. The framing we need is small: masked client frames out, plain server
/// frames in, plus ping/pong/close handling.
@MainActor
final class DanmakuClient {

    var onMessage: ((_ user: String, _ text: String, _ color: String) -> Void)?
    var onStatus: ((_ text: String, _ ok: Bool) -> Void)?
    /// Reason for the most recent disconnect, so the UI can show what actually failed.
    var onDiagnostic: ((String) -> Void)?

    private var connection: NWConnection?
    private var heartbeatTimer: Timer?
    private var reconnectItem: DispatchWorkItem?

    private var buffer = Data()
    private var handshakeKey = ""
    private var handshakeDone = false
    private var fragmentedMessage = Data()

    /// Identifies the in-flight connection. Every asynchronous callback captures the token
    /// it was created with and returns early once the token has moved on. Tearing down a
    /// connection bumps the token first, so late callbacks cannot start a competing
    /// reconnect chain.
    private var token = 0
    private var wanted = false
    private var ayyuid = 0
    private var topSid = 0
    private var subSid = 0
    private var reconnectDelay: TimeInterval = 2.5

    var isConnected: Bool { connection != nil }
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
        guard wanted, connection == nil, reconnectItem == nil else { return }
        openNewConnection()
    }

    // MARK: - Connection lifecycle

    private func openNewConnection() {
        guard wanted else { return }
        token += 1
        let id = token
        teardown()
        buffer.removeAll(keepingCapacity: true)
        fragmentedMessage = Data()
        handshakeDone = false
        handshakeKey = DanmakuClient.randomKey()
        onStatus?("弹幕连接中", false)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        guard let port = NWEndpoint.Port(rawValue: danmakuPort) else {
            fail(id: id, reason: "端口无效")
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(danmakuHost), port: port, using: parameters)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                switch state {
                case .ready:
                    self.sendHandshake(id: id)
                    self.receiveLoop(id: id)
                case .failed(let error), .waiting(let error):
                    self.fail(id: id, reason: error.localizedDescription)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func sendHandshake(id: Int) {
        // No Sec-WebSocket-Extensions: this is what keeps the server from compressing,
        // and it is the whole reason we are not using URLSessionWebSocketTask.
        let request = [
            "GET / HTTP/1.1",
            "Host: \(danmakuHost)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(handshakeKey)",
            "Sec-WebSocket-Version: 13",
            "User-Agent: Mozilla/5.0",
            "Origin: https://www.huya.com",
            "",
            "",
        ].joined(separator: "\r\n")
        sendRaw(Data(request.utf8), id: id)
    }

    private func receiveLoop(id: Int) {
        guard wanted, id == token, let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    if !self.handshakeDone {
                        self.processHandshake(id: id)
                    }
                    if self.handshakeDone, self.wanted, id == self.token {
                        self.processFrames(id: id)
                    }
                }
                if let error {
                    self.fail(id: id, reason: error.localizedDescription)
                    return
                }
                if isComplete {
                    self.fail(id: id, reason: "连接被服务器关闭")
                    return
                }
                self.receiveLoop(id: id)
            }
        }
    }

    private func processHandshake(id: Int) {
        guard let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let head = String(decoding: buffer[buffer.startIndex..<terminator.lowerBound], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex..<terminator.upperBound)

        let lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, statusLine.contains(" 101 ") else {
            fail(id: id, reason: "握手被拒绝: \(lines.first ?? "无响应")")
            return
        }
        var accept = ""
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "sec-websocket-accept" {
                accept = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        guard accept == DanmakuClient.acceptKey(for: handshakeKey) else {
            fail(id: id, reason: "握手校验失败")
            return
        }

        handshakeDone = true
        reconnectDelay = 2.5
        onStatus?("弹幕已连接", true)
        sendRaw(encodeFrame(DanmakuClient.buildJoin(ayyuid: ayyuid, tid: topSid, sid: subSid), opcode: 0x2), id: id)
        startHeartbeat(id: id)
    }

    private func startHeartbeat(id: Int) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                self.sendRaw(self.encodeFrame(danmakuHeartbeat, opcode: 0x2), id: id)
            }
        }
    }

    /// Tears the connection down and schedules exactly one reconnect attempt.
    private func fail(id: Int, reason: String) {
        guard wanted, id == token else { return }
        onDiagnostic?(reason)
        // Bump the token before teardown so cancellation callbacks cannot schedule a
        // second, competing reconnect.
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
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func sendRaw(_ data: Data, id: Int) {
        guard wanted, id == token, let connection else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, self.wanted, id == self.token else { return }
                self.fail(id: id, reason: error.localizedDescription)
            }
        })
    }

    // MARK: - Frame parsing

    private func processFrames(id: Int) {
        while true {
            guard buffer.count >= 2 else { return }
            let b0 = buffer[buffer.startIndex]
            let b1 = buffer[buffer.startIndex + 1]
            let fin = (b0 & 0x80) != 0
            let reserved = b0 & 0x70
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            let shortLength = Int(b1 & 0x7F)

            var offset = 2
            var length = shortLength
            if shortLength == 126 {
                guard buffer.count >= offset + 2 else { return }
                length = Int(buffer[buffer.startIndex + offset]) << 8
                    | Int(buffer[buffer.startIndex + offset + 1])
                offset += 2
            } else if shortLength == 127 {
                guard buffer.count >= offset + 8 else { return }
                var value: UInt64 = 0
                for index in 0..<8 {
                    value = (value << 8) | UInt64(buffer[buffer.startIndex + offset + index])
                }
                guard value <= UInt64(maxFrameSize) else {
                    fail(id: id, reason: "帧过大")
                    return
                }
                length = Int(value)
                offset += 8
            }

            // We never negotiate an extension, so a set reserved bit is a protocol violation.
            guard reserved == 0 else {
                fail(id: id, reason: "收到压缩帧（不应出现）")
                return
            }

            var maskKey = [UInt8]()
            if masked {
                guard buffer.count >= offset + 4 else { return }
                for index in 0..<4 {
                    maskKey.append(buffer[buffer.startIndex + offset + index])
                }
                offset += 4
            }
            guard buffer.count >= offset + length else { return }

            var payload = Data(buffer[(buffer.startIndex + offset)..<(buffer.startIndex + offset + length)])
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset + length))

            if masked {
                var bytes = [UInt8](payload)
                for index in 0..<bytes.count {
                    bytes[index] ^= maskKey[index % 4]
                }
                payload = Data(bytes)
            }
            handleFrame(id: id, fin: fin, opcode: opcode, payload: payload)
            guard wanted, id == token else { return }
        }
    }

    private func handleFrame(id: Int, fin: Bool, opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x0:
            fragmentedMessage.append(payload)
            if fin {
                let message = fragmentedMessage
                fragmentedMessage = Data()
                deliver(message)
            }
        case 0x1, 0x2:
            if fin {
                deliver(payload)
            } else {
                fragmentedMessage = payload
            }
        case 0x8:
            let code = payload.count >= 2 ? Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1]) : 0
            fail(id: id, reason: "服务器关闭连接（代码 \(code)）")
        case 0x9:
            sendRaw(encodeFrame(payload, opcode: 0xA), id: id)
        case 0xA:
            break
        default:
            break
        }
    }

    private func deliver(_ payload: Data) {
        guard let chat = DanmakuClient.parseChat(payload) else { return }
        onMessage?(chat.user, chat.text, chat.color)
    }

    // MARK: - Client frame encoding

    private func encodeFrame(_ payload: Data, opcode: UInt8) -> Data {
        var out = Data()
        out.append(0x80 | opcode)
        let count = payload.count
        var mask = [UInt8]()
        for _ in 0..<4 {
            mask.append(UInt8.random(in: 0...255))
        }
        if count < 126 {
            out.append(0x80 | UInt8(count))
        } else if count <= 0xFFFF {
            out.append(0x80 | 126)
            out.append(UInt8((count >> 8) & 0xFF))
            out.append(UInt8(count & 0xFF))
        } else {
            out.append(0x80 | 127)
            let value = UInt64(count)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        }
        out.append(contentsOf: mask)
        let bytes = [UInt8](payload)
        var masked = [UInt8]()
        masked.reserveCapacity(bytes.count)
        for (index, byte) in bytes.enumerated() {
            masked.append(byte ^ mask[index % 4])
        }
        out.append(contentsOf: masked)
        return out
    }

    // MARK: - Handshake helpers

    nonisolated static func randomKey() -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for _ in 0..<16 {
            bytes.append(UInt8.random(in: 0...255))
        }
        return Data(bytes).base64EncodedString()
    }

    nonisolated static func acceptKey(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + webSocketGUID).utf8))
        return Data(digest).base64EncodedString()
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
