import Foundation
import CryptoKit

enum HuyaAPI {

    static let mobileUA = "Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36"
    static let playUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    /// Used when the room does not advertise its quality list. 2000 kbps ("超清") is
    /// Huya's long-standing default and is known to work for every room.
    static let defaultBitRate = 2000

    static var playbackHeaders: [String: String] {
        return [
            "User-Agent": playUA,
            "Referer": "https://www.huya.com/",
        ]
    }

    // MARK: - Room id

    static func normalizeRoomId(_ text: String) throws -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            throw HuyaError.message("请输入房号")
        }
        if value.contains("huya.com") {
            let normalized = value.hasPrefix("http") ? value : "https://\(value)"
            if let url = URL(string: normalized) {
                let last = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }.last ?? ""
                if !last.isEmpty { value = last }
            }
        }
        guard !value.isEmpty, value.allSatisfy({ $0.isNumber }) else {
            throw HuyaError.message("房号必须是数字")
        }
        return value
    }

    /// Extracts the leading room number from a history label such as "12345  主播名".
    static func roomIdFromLabel(_ label: String) -> String {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            return text
        }
        return String(first)
    }

    // MARK: - HTTP helpers

    private static func httpGet(_ urlString: String, headers: [String: String], timeout: TimeInterval = 12) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw HuyaError.message("地址无效")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private static func httpPostJSON(_ urlString: String, body: [String: Any], headers: [String: String], timeout: TimeInterval = 12) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else {
            throw HuyaError.message("地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HuyaError.message("响应解析失败")
        }
        return object
    }

    // MARK: - Room

    static func fetchRoom(_ roomId: String) async throws -> HuyaRoom {
        let id = try normalizeRoomId(roomId)
        let url = "https://mp.huya.com/cache.php?m=Live&do=profileRoom&roomid=\(id)"
        let headers = [
            "User-Agent": mobileUA,
            "Referer": "https://m.huya.com/\(id)",
            "Accept": "application/json,text/plain,*/*",
        ]
        let data = try await httpGet(url, headers: headers)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HuyaError.message("房间信息解析失败")
        }
        guard asInt(root["status"]) == 200, let payload = root["data"] as? [String: Any] else {
            throw HuyaError.message(asString(root["message"], fallback: "房间不存在"))
        }

        let profile = payload["profileInfo"] as? [String: Any] ?? [:]
        let live = payload["liveData"] as? [String: Any] ?? [:]
        let stream = payload["stream"] as? [String: Any] ?? [:]
        let rawLines = stream["baseSteamInfoList"] as? [[String: Any]] ?? []
        let qualities = parseQualities(stream)

        let lines: [HuyaLine] = rawLines.map { item in
            let flvAntiCode = asString(item["sFlvAntiCode"])
            return HuyaLine(
                streamName: asString(item["sStreamName"]),
                flvURL: asString(item["sFlvUrl"]),
                flvSuffix: asString(item["sFlvUrlSuffix"], fallback: "flv"),
                flvAntiCode: flvAntiCode,
                hlsURL: asString(item["sHlsUrl"]),
                hlsSuffix: asString(item["sHlsUrlSuffix"], fallback: "m3u8"),
                // Some responses omit the HLS signature; the FLV one uses the same
                // generic fm/wsTime scheme, so it can be reused.
                hlsAntiCode: asString(item["sHlsAntiCode"], fallback: flvAntiCode)
            )
        }

        let roomIdOut = asString(profile["profileRoom"], fallback: asString(live["profileRoom"], fallback: id))
        let nick = asString(profile["nick"], fallback: asString(live["nick"]))
        let title = asString(live["roomName"], fallback: asString(live["introduction"]))
        let liveOn = asString(payload["liveStatus"]).uppercased() == "ON"
        let yyid = asInt(profile["yyid"], fallback: asInt(live["yyid"]))
        let uid = asInt(profile["uid"], fallback: asInt(live["uid"]))
        let topSid = asInt(payload["chTopId"], fallback: asInt(live["channel"]))
        let subSid = asInt(payload["subChId"], fallback: asInt(live["liveChannel"]))

        return HuyaRoom(
            roomId: roomIdOut,
            nick: nick,
            title: title,
            liveOn: liveOn,
            yyid: yyid,
            uid: uid,
            topSid: topSid,
            subSid: subSid,
            lines: lines,
            qualities: qualities
        )
    }

    /// Huya exposes the selectable qualities as `rateArray` on the `hls` / `flv` objects,
    /// e.g. [{"sDisplayName": "蓝光4M", "iBitRate": 4000}, ... {"sDisplayName": "流畅", "iBitRate": 500}].
    /// Older responses used `vMultiStreamInfo` instead.
    private static func parseQualities(_ stream: [String: Any]) -> [HuyaQuality] {
        let sources: [[String: Any]] = [
            stream["hls"] as? [String: Any] ?? [:],
            stream["flv"] as? [String: Any] ?? [:],
            stream,
        ]
        for source in sources {
            let raw = (source["rateArray"] as? [[String: Any]])
                ?? (source["vMultiStreamInfo"] as? [[String: Any]])
                ?? []
            let parsed = raw.compactMap { item -> HuyaQuality? in
                let rate = asInt(item["iBitRate"])
                guard rate > 0 else { return nil }
                return HuyaQuality(name: asString(item["sDisplayName"]), bitRate: rate)
            }
            if !parsed.isEmpty { return parsed }
        }
        return []
    }

    // MARK: - Search

    static func searchAnchors(_ keyword: String) async throws -> [SearchResult] {
        let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw HuyaError.message("请输入搜索内容")
        }
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        let url = "https://search.cdn.huya.com/?m=Search&do=getSearchContent&q=\(encoded)&typ=-5&rows=30"
        let headers = [
            "User-Agent": playUA,
            "Referer": "https://www.huya.com/",
            "Accept": "application/json,text/plain,*/*",
        ]
        let data = try await httpGet(url, headers: headers)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HuyaError.message("搜索结果解析失败")
        }
        let response = (root["response"] as? [String: Any]) ?? root
        let block = response["1"] as? [String: Any] ?? [:]
        let docs = block["docs"] as? [[String: Any]] ?? []

        var seen = Set<String>()
        var results: [SearchResult] = []
        for doc in docs {
            let roomId = asString(doc["room_id"], fallback: asString(doc["game_privateHost"]))
            let nick = asString(doc["game_nick"])
            let liveOn = asBool(doc["gameLiveOn"])
            guard !roomId.isEmpty, !seen.contains(roomId) else { continue }
            seen.insert(roomId)
            results.append(SearchResult(roomId: roomId, nick: nick, liveOn: liveOn))
        }
        results.sort { lhs, rhs in
            if lhs.liveOn != rhs.liveOn { return lhs.liveOn && !rhs.liveOn }
            return lhs.nick < rhs.nick
        }
        return results
    }

    // MARK: - Anonymous identity

    static func anonymousUID() async -> String {
        let fallback = String(Int(Date().timeIntervalSince1970 * 1000) % 10_000_000_000)
        let body: [String: Any] = [
            "appId": 5002,
            "byPass": 3,
            "context": "",
            "version": "2.4",
            "data": [String: Any](),
        ]
        do {
            let response = try await httpPostJSON("https://udblgn.huya.com/web/anonymousLogin", body: body, headers: ["User-Agent": mobileUA])
            let payload = response["data"] as? [String: Any] ?? [:]
            let uid = asString(payload["uid"])
            return uid.isEmpty ? fallback : uid
        } catch {
            return fallback
        }
    }

    // MARK: - Stream URL

    static func buildPlayURL(_ room: HuyaRoom, lineIndex: Int = 0) async throws -> (url: String, lineIndex: Int) {
        guard room.liveOn else {
            throw HuyaError.message("该房间未开播")
        }
        let lines = room.lines.filter { $0.hasHLS || $0.hasFLV }
        guard !lines.isEmpty else {
            throw HuyaError.message("未拿到直播流地址")
        }
        let uid = await anonymousUID()
        var lastError: Error = HuyaError.message("直播流签名失败")
        let count = lines.count
        let ratio = room.lowestBitRate ?? defaultBitRate

        for offset in 0..<count {
            let index = (lineIndex + offset) % count
            do {
                let url = try buildURL(line: lines[index], uid: uid, ratio: ratio)
                return (url, index)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func buildURL(line: HuyaLine, uid: String, ratio: Int) throws -> String {
        if line.hasHLS {
            let params = processAnticode(line.hlsAntiCode, uid: uid, streamName: line.streamName, ratio: ratio)
            let base = line.hlsURL.hasSuffix("/") ? String(line.hlsURL.dropLast()) : line.hlsURL
            let suffix = line.hlsSuffix.isEmpty ? "m3u8" : line.hlsSuffix
            return httpsify("\(base)/\(line.streamName).\(suffix)?\(params)")
        }
        guard line.hasFLV else {
            throw HuyaError.message("未拿到直播流地址")
        }
        let params = processAnticode(line.flvAntiCode, uid: uid, streamName: line.streamName, ratio: ratio)
        let base = line.flvURL.hasSuffix("/") ? String(line.flvURL.dropLast()) : line.flvURL
        let suffix = line.flvSuffix.isEmpty ? "flv" : line.flvSuffix
        return httpsify("\(base)/\(line.streamName).\(suffix)?\(params)")
    }

    private static func httpsify(_ url: String) -> String {
        if url.hasPrefix("http://") {
            return "https://" + String(url.dropFirst("http://".count))
        }
        return url
    }

    // MARK: - Anticode signature

    static func processAnticode(_ anticode: String, uid: String, streamName: String, ratio: Int) -> String {
        var items = parseQuery(anticode)

        func value(_ name: String) -> String {
            return items.first(where: { $0.0 == name })?.1 ?? ""
        }
        func set(_ name: String, _ value: String) {
            setParam(&items, name, value)
        }

        set("ver", "1")
        set("sv", "2110211124")
        // Pin the rendition to the requested bitrate. `ratio` is not part of the signed
        // `fm` template, so setting it does not invalidate `wsSecret`.
        set("ratio", String(ratio))

        let uidValue = Int(uid) ?? 0
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let seqid = String(uidValue + now)
        set("seqid", seqid)
        set("uid", uid)
        set("uuid", String(uuidValue()))

        let ctype = value("ctype")
        let t = value("t")
        let ss = md5("\(seqid)|\(ctype)|\(t)")

        let fmEncoded = value("fm")
        let fmData = Data(base64Encoded: fmEncoded) ?? Data()
        var template = String(data: fmData, encoding: .utf8) ?? ""
        template = template
            .replacingOccurrences(of: "$0", with: uid)
            .replacingOccurrences(of: "$1", with: streamName)
            .replacingOccurrences(of: "$2", with: ss)
            .replacingOccurrences(of: "$3", with: value("wsTime"))
        set("wsSecret", md5(template))

        items.removeAll { $0.0 == "fm" || $0.0 == "txyp" }
        return encodeQuery(items)
    }

    private static func uuidValue() -> Int {
        let now = Date().timeIntervalSince1970 * 1000
        let random = Int.random(in: 0...1000)
        let wrapped = (now.truncatingRemainder(dividingBy: 10_000_000_000) * 1000).rounded()
        let total = Int(wrapped) + random
        return total % 4_294_967_295
    }

    private static func md5(_ text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Query string helpers (mirror urllib parse_qs / urlencode)

    private static let unreserved: Set<UInt8> = {
        var set = Set<UInt8>()
        for byte in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~".utf8 {
            set.insert(byte)
        }
        return set
    }()

    private static func percentDecode(_ text: String) -> String {
        let plus = text.replacingOccurrences(of: "+", with: " ")
        return plus.removingPercentEncoding ?? plus
    }

    private static func quotePlus(_ text: String) -> String {
        var out = ""
        for byte in Array(text.utf8) {
            if byte == 0x20 {
                out += "+"
            } else if unreserved.contains(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func parseQuery(_ raw: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for pair in raw.split(separator: "&", omittingEmptySubsequences: false) {
            if pair.isEmpty { continue }
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = percentDecode(String(parts[0]))
            let value = parts.count > 1 ? percentDecode(String(parts[1])) : ""
            if value.isEmpty { continue }
            if out.contains(where: { $0.0 == name }) { continue }
            out.append((name, value))
        }
        return out
    }

    private static func setParam(_ items: inout [(String, String)], _ name: String, _ value: String) {
        if let index = items.firstIndex(where: { $0.0 == name }) {
            items[index].1 = value
        } else {
            items.append((name, value))
        }
    }

    private static func encodeQuery(_ items: [(String, String)]) -> String {
        return items.map { "\(quotePlus($0.0))=\(quotePlus($0.1))" }.joined(separator: "&")
    }

    // MARK: - JSON value coercion

    private static func asInt(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
    }

    private static func asInt(_ value: Any?, fallback: Int) -> Int {
        let parsed = asInt(value)
        return parsed == 0 ? fallback : parsed
    }

    private static func asString(_ value: Any?, fallback: String = "") -> String {
        if let text = value as? String { return text.isEmpty ? fallback : text }
        if let number = value as? NSNumber { return number.stringValue }
        return fallback
    }

    private static func asBool(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text == "true" || text == "1" }
        return false
    }
}
