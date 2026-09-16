import Foundation

enum HuyaError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
    }
}

struct HuyaLine {
    let streamName: String
    let flvURL: String
    let flvSuffix: String
    let flvAntiCode: String
    let hlsURL: String
    let hlsSuffix: String
    let hlsAntiCode: String

    var hasHLS: Bool {
        return !hlsURL.isEmpty && !hlsAntiCode.isEmpty && !streamName.isEmpty
    }

    var hasFLV: Bool {
        return !flvURL.isEmpty && !flvAntiCode.isEmpty && !streamName.isEmpty
    }
}

struct HuyaRoom {
    let roomId: String
    let nick: String
    let title: String
    let liveOn: Bool
    let yyid: Int
    let uid: Int
    let topSid: Int
    let subSid: Int
    let lines: [HuyaLine]
}

struct SearchResult: Identifiable, Equatable {
    let roomId: String
    let nick: String
    let liveOn: Bool

    var id: String { roomId }

    var label: String {
        return nick.isEmpty ? roomId : "\(roomId)  \(nick)"
    }
}
