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

struct HuyaQuality {
    let name: String
    let bitRate: Int
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
    let qualities: [HuyaQuality]

    /// The lowest advertised bitrate, in kbps. Huya reports "流畅" as the smallest
    /// positive `iBitRate`, so this is what the player pins the stream to.
    var lowestQuality: HuyaQuality? {
        return qualities.filter { $0.bitRate > 0 }.min { $0.bitRate < $1.bitRate }
    }

    var lowestBitRate: Int? {
        return lowestQuality?.bitRate
    }
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
