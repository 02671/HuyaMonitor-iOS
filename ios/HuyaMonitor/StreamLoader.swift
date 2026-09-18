import AVFoundation
import UniformTypeIdentifiers

/// Fetches every HLS playlist and media segment with the same browser headers the
/// Windows ffplay client sends. AVPlayer will not call a resource-loader delegate
/// for `https://` URLs, so playback uses the custom `hyhls://` scheme and this
/// object translates it back to HTTPS.
///
/// Without this, only the first playlist request (via the undocumented
/// `AVURLAssetHTTPHeaderFieldsKey`) would carry `Referer` / `User-Agent`. Segment
/// requests go out as `AppleCoreMedia/...`, Huya's CDN answers 403, the item
/// fails, and the player reconnects in a loop.
final class StreamLoader: NSObject, AVAssetResourceLoaderDelegate {

    static let scheme = "hyhls"

    private let session: URLSession
    private let queue = DispatchQueue(label: "huya.stream.loader")
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    override init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = HuyaAPI.playbackHeaders
        session = URLSession(configuration: config)
        super.init()
    }

    static func playbackURL(from httpsURL: URL) -> URL {
        var parts = URLComponents(url: httpsURL, resolvingAgainstBaseURL: false)
        parts?.scheme = scheme
        return parts?.url ?? httpsURL
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        queue.async { self.start(loadingRequest) }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        queue.async {
            let key = ObjectIdentifier(loadingRequest)
            self.tasks[key]?.cancel()
            self.tasks[key] = nil
        }
    }

    private func start(_ request: AVAssetResourceLoadingRequest) {
        guard let original = request.request.url, let real = httpsURL(from: original) else {
            request.finishLoading(with: HuyaError.message("音频地址无效"))
            return
        }

        var urlRequest = URLRequest(url: real)
        urlRequest.timeoutInterval = 20
        for (header, value) in HuyaAPI.playbackHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: header)
        }

        let task = session.dataTask(with: urlRequest) { [weak self] data, response, error in
            self?.queue.async {
                self?.tasks[ObjectIdentifier(request)] = nil
                self?.complete(request, realURL: real, data: data, response: response, error: error)
            }
        }
        tasks[ObjectIdentifier(request)] = task
        task.resume()
    }

    private func complete(
        _ request: AVAssetResourceLoadingRequest,
        realURL: URL,
        data: Data?,
        response: URLResponse?,
        error: Error?
    ) {
        if request.isCancelled { return }
        if let error {
            request.finishLoading(with: error)
            return
        }
        guard var data else {
            request.finishLoading(with: HuyaError.message("音频数据为空"))
            return
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        if status >= 400 {
            request.finishLoading(with: HuyaError.message("音频服务器返回 \(status)"))
            return
        }

        let mime = http?.value(forHTTPHeaderField: "Content-Type") ?? response?.mimeType ?? ""
        if isPlaylist(data: data, mime: mime) {
            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
                request.finishLoading(with: HuyaError.message("播放列表无法解码"))
                return
            }
            data = Data(rewritePlaylist(text, playlistURL: realURL).utf8)
        }

        if let info = request.contentInformationRequest {
            info.contentType = uti(for: mime, data: data)
            info.isByteRangeAccessSupported = !isPlaylist(data: data, mime: mime)
            info.contentLength = Int64(data.count)
        }
        if let dataRequest = request.dataRequest {
            let start = Int(dataRequest.currentOffset)
            if start < data.count {
                let remaining = data.count - start
                let wanted: Int
                if dataRequest.requestsAllDataToEndOfResource || dataRequest.requestedLength == Int.max {
                    wanted = remaining
                } else {
                    let end = Int(dataRequest.requestedOffset) + dataRequest.requestedLength
                    wanted = min(remaining, max(0, end - start))
                }
                if wanted > 0 {
                    dataRequest.respond(with: data.subdata(in: start..<(start + wanted)))
                }
            }
        }
        request.finishLoading()
    }

    private func isPlaylist(data: Data, mime: String) -> Bool {
        let lower = mime.lowercased()
        if lower.contains("mpegurl") || lower.contains("m3u") { return true }
        if data.starts(with: Data("#EXTM3U".utf8)) { return true }
        return false
    }

    private func uti(for mime: String, data: Data) -> String {
        let lower = mime.lowercased()
        if lower.contains("mpegurl") || lower.contains("m3u") || data.starts(with: Data("#EXTM3U".utf8)) {
            return UTType.m3uPlaylist.identifier
        }
        if lower.contains("mp2t") || lower.contains("mpegts") {
            return "public.mpeg-2-transport-stream"
        }
        if lower.contains("mp4") || lower.contains("aac") {
            return UTType.mpeg4Movie.identifier
        }
        return UTType.data.identifier
    }

    private func rewritePlaylist(_ text: String, playlistURL: URL) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                out.append(rewriteTag(raw, playlistURL: playlistURL))
            } else {
                out.append(rewriteURLString(trimmed, playlistURL: playlistURL))
            }
        }
        return out.joined(separator: "\n")
    }

    private func rewriteTag(_ line: String, playlistURL: URL) -> String {
        guard line.contains("URI=") else { return line }
        var result = ""
        var remaining = line[...]
        while let range = remaining.range(of: "URI=\"") {
            result += remaining[..<range.upperBound]
            remaining = remaining[range.upperBound...]
            if let end = remaining.firstIndex(of: "\"") {
                let uri = String(remaining[..<end])
                result += rewriteURLString(uri, playlistURL: playlistURL)
                remaining = remaining[end...]
            }
        }
        result += remaining
        return result
    }

    private func rewriteURLString(_ value: String, playlistURL: URL) -> String {
        let resolved: URL?
        if let absolute = URL(string: value), absolute.scheme != nil {
            resolved = absolute
        } else {
            resolved = URL(string: value, relativeTo: playlistURL)?.absoluteURL
        }
        guard let resolved else { return value }
        return Self.playbackURL(from: httpsify(resolved)).absoluteString
    }

    private func httpsURL(from custom: URL) -> URL? {
        var parts = URLComponents(url: custom, resolvingAgainstBaseURL: false)
        parts?.scheme = "https"
        return parts?.url
    }

    private func httpsify(_ url: URL) -> URL {
        guard url.scheme == "http" else { return url }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.scheme = "https"
        return parts?.url ?? url
    }
}
