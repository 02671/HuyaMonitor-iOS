import SwiftUI
import UIKit

enum ConnectionPhase: Equatable {
    case off
    case busy
    case on

    var color: Color {
        switch self {
        case .off: return Color(red: 0.79, green: 0.30, blue: 0.30)
        case .busy: return Color(red: 0.88, green: 0.72, blue: 0.24)
        case .on: return Color(red: 0.14, green: 0.62, blue: 0.39)
        }
    }
}

struct DanmakuLine: Identifiable, Equatable {
    let id = UUID()
    let user: String
    let text: String
    let color: UIColor
    let isSystem: Bool
}

@MainActor
final class MonitorViewModel: ObservableObject {

    @Published var roomText = ""
    @Published var lines: [DanmakuLine] = []
    @Published var danmuPhase: ConnectionPhase = .off
    @Published var audioPhase: ConnectionPhase = .off
    @Published var volume: Double = 1.0
    @Published var history: [HistoryItem] = []
    @Published var searchKeyword = ""
    @Published var searchResults: [SearchResult] = []
    @Published var searchStatus = "输入主播名后搜索"
    @Published var searching = false
    @Published var alertMessage: String?
    @Published var audioTitle = ""
    @Published var audioQuality = ""
    @Published var danmakuDiagnostic = ""
    @Published var audioDiagnostic = ""

    private let danmaku = DanmakuClient()
    private let audio = AudioPlayer()
    private let store = RoomHistoryStore()

    private var danmuWanted = false
    private var audioWanted = false

    init() {
        history = store.items
        if let first = history.first?.roomId, roomText.isEmpty {
            roomText = first
        }
        wireClients()
    }

    private func wireClients() {
        danmaku.onMessage = { [weak self] user, text, color in
            Task { @MainActor in
                self?.appendDanmaku(user: user, text: text, colorHex: color)
            }
        }
        danmaku.onStatus = { [weak self] text, ok in
            Task { @MainActor in
                guard let self else { return }
                self.danmuPhase = self.phase(of: text, ok: ok)
                if ok { self.danmakuDiagnostic = "" }
            }
        }
        danmaku.onDiagnostic = { [weak self] reason in
            Task { @MainActor in
                self?.danmakuDiagnostic = reason
            }
        }
        audio.onStatus = { [weak self] text, ok in
            Task { @MainActor in
                guard let self else { return }
                self.audioPhase = self.phase(of: text, ok: ok)
            }
        }
        audio.onDiagnostic = { [weak self] reason in
            Task { @MainActor in
                self?.audioDiagnostic = reason
            }
        }
    }

    private func phase(of text: String, ok: Bool) -> ConnectionPhase {
        if ok { return .on }
        if text.contains("中") { return .busy }
        return .off
    }

    // MARK: - Room helpers

    private func resolvedRoomId() throws -> String {
        let raw = HuyaAPI.roomIdFromLabel(roomText)
        return try HuyaAPI.normalizeRoomId(raw)
    }

    private func rememberRoom(_ room: HuyaRoom) {
        store.remember(roomId: room.roomId, nick: room.nick)
        history = store.items
        roomText = room.roomId
    }

    // MARK: - Actions

    func connectAll() {
        let roomId: String
        do {
            roomId = try resolvedRoomId()
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        danmuPhase = .busy
        audioPhase = .busy
        Task {
            do {
                let room = try await HuyaAPI.fetchRoom(roomId)
                rememberRoom(room)
                startDanmaku(room: room)
                startAudio(room: room)
            } catch {
                danmuPhase = .off
                audioPhase = .off
                alertMessage = error.localizedDescription
            }
        }
    }

    func toggleDanmaku() {
        if danmuWanted {
            danmaku.stop()
            danmuWanted = false
            danmuPhase = .off
            return
        }
        let roomId: String
        do {
            roomId = try resolvedRoomId()
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        danmuPhase = .busy
        Task {
            do {
                let room = try await HuyaAPI.fetchRoom(roomId)
                rememberRoom(room)
                startDanmaku(room: room)
            } catch {
                danmuPhase = .off
                alertMessage = error.localizedDescription
            }
        }
    }

    func toggleAudio() {
        if audioWanted {
            audio.stop()
            audioWanted = false
            audioPhase = .off
            audioTitle = ""
            audioQuality = ""
            audioDiagnostic = ""
            return
        }
        let roomId: String
        do {
            roomId = try resolvedRoomId()
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        audioPhase = .busy
        Task {
            do {
                let room = try await HuyaAPI.fetchRoom(roomId)
                rememberRoom(room)
                startAudio(room: room)
            } catch {
                audioPhase = .off
                alertMessage = error.localizedDescription
            }
        }
    }

    private func startDanmaku(room: HuyaRoom) {
        let ayyuid = room.uid != 0 ? room.uid : room.yyid
        danmuWanted = true
        danmaku.start(ayyuid: ayyuid, topSid: room.topSid, subSid: room.subSid)
    }

    private func startAudio(room: HuyaRoom) {
        audioWanted = true
        audioTitle = room.nick.isEmpty ? room.title : room.nick
        audioQuality = room.lowestQuality?.name ?? ""
        audio.start(roomId: room.roomId)
        audio.setVolume(volume)
    }

    func setVolume(_ value: Double) {
        volume = value
        audio.setVolume(value)
    }

    func clearDanmaku() {
        lines.removeAll()
    }

    func handleForeground() {
        if danmuWanted {
            danmaku.ensureConnected()
        }
        if audioWanted {
            audio.ensurePlaying()
        }
    }

    func handleBackground() {
        // Audio intentionally keeps running: AVAudioSession uses the .playback category
        // and UIBackgroundModes contains "audio".
    }

    // MARK: - History

    func deleteHistory(_ roomId: String) {
        store.remove(roomId: roomId)
        history = store.items
        if HuyaAPI.roomIdFromLabel(roomText) == roomId {
            roomText = history.first?.roomId ?? ""
        }
    }

    func selectHistory(_ item: HistoryItem) {
        roomText = item.label
    }

    // MARK: - Search

    func runSearch() {
        let keyword = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            searchResults = []
            searchStatus = "输入主播名后搜索"
            return
        }
        searching = true
        searchStatus = "搜索中..."
        Task {
            do {
                let results = try await HuyaAPI.searchAnchors(keyword)
                searchResults = results
                let liveCount = results.filter { $0.liveOn }.count
                searchStatus = results.isEmpty
                    ? "没有匹配的主播"
                    : "找到 \(results.count) 个主播，其中 \(liveCount) 个开播"
            } catch {
                searchResults = []
                searchStatus = error.localizedDescription
            }
            searching = false
        }
    }

    func pickSearch(_ result: SearchResult) {
        roomText = result.label
        store.remember(roomId: result.roomId, nick: result.nick)
        history = store.items
    }

    func resetSearch() {
        searchKeyword = ""
        searchResults = []
        searchStatus = "输入主播名后搜索"
    }

    // MARK: - Danmaku list

    private func appendDanmaku(user: String, text: String, colorHex: String) {
        let isSystem = user == "系统"
        let color = isSystem ? UIColor(red: 1.0, green: 0.42, blue: 0.36, alpha: 1) : UIColor(hex: colorHex)
        lines.append(DanmakuLine(user: user, text: text, color: color, isSystem: isSystem))
        if lines.count >= 500 {
            lines.removeFirst(400)
        }
    }
}

extension Color {
    init(hex: String) {
        self = Color(UIColor(hex: hex))
    }
}

extension UIColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        var value: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self.init(red: 0.91, green: 0.93, blue: 0.95, alpha: 1)
            return
        }
        self.init(
            red: CGFloat((value & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((value & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(value & 0x0000FF) / 255.0,
            alpha: 1
        )
    }
}
