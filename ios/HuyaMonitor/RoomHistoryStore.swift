import Foundation

struct HistoryItem: Codable, Identifiable, Equatable {
    let roomId: String
    var nick: String
    var ts: Int

    var id: String { roomId }

    var label: String {
        let name = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? roomId : "\(roomId)  \(name)"
    }
}

final class RoomHistoryStore {

    private(set) var items: [HistoryItem] = []
    private let fileURL: URL

    init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = directory.appendingPathComponent("history.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            items = []
            return
        }
        if let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = decoded
            return
        }
        // Backwards compatible with the desktop tool's {"rooms": [...]} shape.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rooms = object["rooms"] as? [[String: Any]] {
            items = rooms.compactMap { room in
                let roomId = (room["room_id"] as? String) ?? ""
                guard !roomId.isEmpty else { return nil }
                return HistoryItem(roomId: roomId, nick: (room["nick"] as? String) ?? "", ts: (room["ts"] as? Int) ?? 0)
            }
        } else {
            items = []
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func remember(roomId: String, nick: String = "") {
        let id = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if let index = items.firstIndex(where: { $0.roomId == id }) {
            if !nick.isEmpty { items[index].nick = nick }
            items[index].ts = Int(Date().timeIntervalSince1970)
        } else {
            items.append(HistoryItem(roomId: id, nick: nick, ts: Int(Date().timeIntervalSince1970)))
        }
        items.sort { $0.ts > $1.ts }
        save()
    }

    func remove(roomId: String) {
        let id = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = items.count
        items.removeAll { $0.roomId == id }
        if items.count != before {
            save()
        }
    }
}
