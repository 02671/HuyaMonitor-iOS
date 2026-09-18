import Foundation
import Network

/// Local loopback reverse proxy so AVPlayer talks HTTP while every Huya playlist
/// and media segment is fetched with browser `User-Agent` / `Referer` / `Origin`.
///
/// A custom URL scheme plus `AVAssetResourceLoaderDelegate` cannot feed HLS
/// segments: CoreMedia rejects them with error -12881 ("custom url not redirect").
/// Only playlists may use a custom scheme; `.ts` / fMP4 must be HTTP(S). This
/// proxy keeps the player on `http://127.0.0.1` and attaches the required headers
/// on the upstream request.
final class StreamProxy {

    static let shared = StreamProxy()

    var onUpstreamForbidden: (() -> Void)?

    private let queue = DispatchQueue(label: "huya.stream.proxy")
    private let session: URLSession
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var startWaiters: [CheckedContinuation<Void, Error>] = []
    private var lastForbiddenAt: TimeInterval = 0
    private var generation = 0

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = HuyaAPI.playbackHeaders
        session = URLSession(configuration: config)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.port != 0 {
                    cont.resume()
                    return
                }
                self.startWaiters.append(cont)
                if self.listener == nil {
                    self.bind()
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.generation += 1
            self.listener?.cancel()
            self.listener = nil
            self.port = 0
            let waiters = self.startWaiters
            self.startWaiters.removeAll()
            waiters.forEach { $0.resume(throwing: HuyaError.message("音频代理已停止")) }
        }
    }

    func bumpGeneration() {
        queue.sync {
            self.generation += 1
            self.lastForbiddenAt = 0
        }
    }

    func playbackURL(from httpsURL: URL) throws -> URL {
        let bound = queue.sync { port }
        return try makePlaybackURL(from: httpsURL, port: bound)
    }

    private func makePlaybackURL(from httpsURL: URL, port: UInt16) throws -> URL {
        guard port > 0 else {
            throw HuyaError.message("音频代理未启动")
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = httpsURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? httpsURL.absoluteString
        guard let url = URL(string: "http://127.0.0.1:\(port)/p?u=\(encoded)") else {
            throw HuyaError.message("音频代理地址无效")
        }
        return url
    }

    // MARK: - Listen

    private func bind() {
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.queue.async { self?.handleListener(state) }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            failStart(error)
        }
    }

    private func handleListener(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let value = listener?.port?.rawValue, value > 0 {
                port = value
                let waiters = startWaiters
                startWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        case .failed(let error):
            failStart(error)
        case .cancelled:
            port = 0
        default:
            break
        }
    }

    private func failStart(_ error: Error) {
        listener?.cancel()
        listener = nil
        port = 0
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
    }

    // MARK: - HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeaders(connection, buffer: Data())
    }

    private func receiveHeaders(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let range = next.range(of: Data("\r\n\r\n".utf8)) {
                let header = next.subdata(in: 0..<range.upperBound)
                self.handleRequest(connection, headerData: header)
                return
            }
            if next.count > 64 * 1024 || isComplete {
                connection.cancel()
                return
            }
            self.receiveHeaders(connection, buffer: next)
        }
    }

    private func handleRequest(_ connection: NWConnection, headerData: Data) {
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            reply(connection, status: 400, reason: "Bad Request", body: Data(), contentType: "text/plain")
            return
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            reply(connection, status: 400, reason: "Bad Request", body: Data(), contentType: "text/plain")
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            reply(connection, status: 400, reason: "Bad Request", body: Data(), contentType: "text/plain")
            return
        }
        let path = String(parts[1])
        let headers = parseHeaders(lines.dropFirst())
        guard let upstream = upstreamURL(from: path) else {
            reply(connection, status: 404, reason: "Not Found", body: Data(), contentType: "text/plain")
            return
        }

        var request = URLRequest(url: upstream)
        request.timeoutInterval = 20
        for (header, value) in HuyaAPI.playbackHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        if let range = headers["range"] {
            request.setValue(range, forHTTPHeaderField: "Range")
        }

        let requestGeneration = generation
        session.dataTask(with: request) { [weak self] data, response, error in
            self?.queue.async {
                self?.complete(
                    connection,
                    upstream: upstream,
                    data: data,
                    response: response,
                    error: error,
                    requestGeneration: requestGeneration
                )
            }
        }.resume()
    }

    private func complete(
        _ connection: NWConnection,
        upstream: URL,
        data: Data?,
        response: URLResponse?,
        error: Error?,
        requestGeneration: Int
    ) {
        if let error {
            let body = Data(error.localizedDescription.utf8)
            reply(connection, status: 502, reason: "Bad Gateway", body: body, contentType: "text/plain")
            return
        }
        guard var data else {
            reply(connection, status: 502, reason: "Bad Gateway", body: Data("empty".utf8), contentType: "text/plain")
            return
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        if status == 403 {
            notifyForbidden(requestGeneration: requestGeneration)
            reply(connection, status: 403, reason: "Forbidden", body: data, contentType: "text/plain")
            return
        }
        if status >= 400 {
            reply(connection, status: status, reason: "Upstream", body: data, contentType: "text/plain")
            return
        }

        let mime = http?.value(forHTTPHeaderField: "Content-Type") ?? response?.mimeType ?? ""
        var contentType = mime.isEmpty ? "application/octet-stream" : mime
        if isPlaylist(data: data, mime: mime) {
            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
                reply(connection, status: 502, reason: "Bad Gateway", body: Data("playlist".utf8), contentType: "text/plain")
                return
            }
            data = Data(rewritePlaylist(text, playlistURL: upstream).utf8)
            contentType = "application/vnd.apple.mpegurl"
        } else if mime.isEmpty {
            contentType = inferredType(for: upstream)
        }
        var extra: [String: String] = [:]
        if let range = http?.value(forHTTPHeaderField: "Content-Range") {
            extra["Content-Range"] = range
        }
        if let accept = http?.value(forHTTPHeaderField: "Accept-Ranges") {
            extra["Accept-Ranges"] = accept
        }
        reply(connection, status: status, reason: status == 206 ? "Partial Content" : "OK", body: data, contentType: contentType, extra: extra)
    }

    private func notifyForbidden(requestGeneration: Int) {
        guard requestGeneration == generation else { return }
        let now = Date().timeIntervalSince1970
        if now - lastForbiddenAt < 1.5 { return }
        lastForbiddenAt = now
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let current = self.queue.sync { self.generation }
            guard current == requestGeneration else { return }
            self.onUpstreamForbidden?()
        }
    }

    private func reply(
        _ connection: NWConnection,
        status: Int,
        reason: String,
        body: Data,
        contentType: String,
        extra: [String: String] = [:]
    ) {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "Cache-Control: no-store\r\n"
        for (name, value) in extra {
            header += "\(name): \(value)\r\n"
        }
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func parseHeaders(_ lines: ArraySlice<Substring>) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let name = line[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { headers[name] = value }
        }
        return headers
    }

    private func upstreamURL(from pathAndQuery: String) -> URL? {
        let full = pathAndQuery.hasPrefix("http") ? pathAndQuery : "http://127.0.0.1\(pathAndQuery)"
        guard let components = URLComponents(string: full) else { return nil }
        let value = components.queryItems?.first(where: { $0.name == "u" })?.value
        guard let value, let url = URL(string: value) else { return nil }
        return httpsify(url)
    }

    // MARK: - Playlist rewrite

    private func isPlaylist(data: Data, mime: String) -> Bool {
        let lower = mime.lowercased()
        if lower.contains("mpegurl") || lower.contains("m3u") { return true }
        if data.starts(with: Data("#EXTM3U".utf8)) { return true }
        return false
    }

    private func inferredType(for url: URL) -> String {
        let name = url.path.lowercased()
        if name.hasSuffix(".m3u8") || name.hasSuffix(".m3u") { return "application/vnd.apple.mpegurl" }
        if name.hasSuffix(".ts") { return "video/MP2T" }
        if name.hasSuffix(".mp4") || name.hasSuffix(".m4s") { return "video/mp4" }
        if name.hasSuffix(".aac") { return "audio/aac" }
        return "application/octet-stream"
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
        return result + remaining
    }

    private func rewriteURLString(_ value: String, playlistURL: URL) -> String {
        guard let resolved = resolve(value, against: playlistURL) else { return value }
        return (try? makePlaybackURL(from: httpsify(resolved), port: port))?.absoluteString ?? value
    }

    private func resolve(_ value: String, against playlistURL: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let absolute = URL(string: trimmed), let scheme = absolute.scheme, scheme == "http" || scheme == "https" {
            return absolute
        }
        var pathPart = trimmed
        var extraQuery: String?
        if let q = trimmed.firstIndex(of: "?") {
            pathPart = String(trimmed[..<q])
            extraQuery = String(trimmed[trimmed.index(after: q)...])
        }
        guard var parts = URLComponents(url: playlistURL, resolvingAgainstBaseURL: false) else {
            return URL(string: trimmed, relativeTo: playlistURL)?.absoluteURL
        }
        if pathPart.hasPrefix("/") {
            parts.path = pathPart
        } else {
            var directory = parts.path
            if let slash = directory.lastIndex(of: "/") {
                directory = String(directory[...slash])
            } else {
                directory = "/"
            }
            parts.path = directory + pathPart
        }
        if let extraQuery, !extraQuery.isEmpty {
            parts.percentEncodedQuery = extraQuery
        }
        return parts.url
    }

    private func httpsify(_ url: URL) -> URL {
        guard url.scheme == "http" else { return url }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.scheme = "https"
        return parts?.url ?? url
    }
}
