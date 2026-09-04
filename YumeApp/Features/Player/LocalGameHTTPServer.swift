import Foundation
import Network
import UniformTypeIdentifiers
import YumeDomain

/// A deliberately small HTTP/1.1 server for Web-based game runtimes.
///
/// RPG Maker and Ruffle assume a real HTTP origin for fetch/XHR, WASM and
/// media byte ranges. The listener is pinned to IPv4 loopback and routes only
/// pre-approved roots, so it does not expose imported games to the LAN.
nonisolated final class LocalGameHTTPServer: @unchecked Sendable {
    enum ServerError: Error, Sendable, Equatable {
        case invalidRequest
        case invalidRange
        case notFound
        case serverFailed(String)
    }

    typealias AccessHandler = @Sendable (
        _ path: String,
        _ mimeType: String,
        _ bytes: Int64,
        _ requestCount: UInt64,
        _ totalBytes: UInt64
    ) -> Void

    private let rootURL: URL
    private let additionalRoots: [String: URL]
    private let onError: @Sendable (_ message: String, _ path: String) -> Void
    private let onAccess: AccessHandler
    private let listener: NWListener
    private let queue = DispatchQueue(
        label: "com.yume.local-game-http",
        qos: .userInitiated
    )

    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var resolvedPathCache: [String: URL] = [:]
    private var readyHandler: (@Sendable (Result<URL, ServerError>) -> Void)?
    private var didStart = false
    private var didResolveStart = false
    private var requestCount: UInt64 = 0
    private var totalBytes: UInt64 = 0

    init(
        rootURL: URL,
        additionalRoots: [String: URL] = [:],
        onError: @escaping @Sendable (_ message: String, _ path: String) -> Void,
        onAccess: @escaping AccessHandler
    ) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.additionalRoots = Dictionary(uniqueKeysWithValues: additionalRoots.map {
            ($0.key.lowercased(), $0.value.standardizedFileURL)
        })
        self.onError = onError
        self.onAccess = onAccess

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )
        listener = try NWListener(using: parameters)
    }

    func start(completion: @escaping @Sendable (Result<URL, ServerError>) -> Void) {
        queue.async { [self] in
            guard !didStart else {
                completion(.failure(ServerError.serverFailed("already started")))
                return
            }
            didStart = true
            readyHandler = completion
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            connections.values.forEach { $0.cancel() }
            connections.removeAll(keepingCapacity: false)
            didResolveStart = true
            readyHandler = nil
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/")
            else {
                resolveStart(.failure(ServerError.serverFailed("missing listener port")))
                return
            }
            resolveStart(.success(url))
        case let .failed(error):
            resolveStart(.failure(ServerError.serverFailed(String(describing: error))))
            listener.cancel()
        case .cancelled:
            resolveStart(.failure(ServerError.serverFailed("listener cancelled")))
        default:
            break
        }
    }

    private func resolveStart(_ result: Result<URL, ServerError>) {
        guard !didResolveStart else { return }
        didResolveStart = true
        let completion = readyHandler
        readyHandler = nil
        completion?(result)
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state { self.finish(connection) }
            if case .cancelled = state { self.finish(connection) }
        }
        connection.start(queue: queue)
        receiveRequest(connection, accumulated: Data())
    }

    private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16 * 1_024
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let error {
                onError(String(describing: error), "<request>")
                finish(connection)
                return
            }
            var request = accumulated
            if let data { request.append(data) }
            guard request.count <= 64 * 1_024 else {
                sendError(431, reason: "Request Header Fields Too Large", connection: connection)
                return
            }
            if request.range(of: Data([13, 10, 13, 10])) == nil {
                if isComplete {
                    sendError(400, reason: "Bad Request", connection: connection)
                } else {
                    receiveRequest(connection, accumulated: request)
                }
                return
            }
            serve(request, connection: connection)
        }
    }

    private func serve(_ requestData: Data, connection: NWConnection) {
        var requestedPath = "<unknown>"
        do {
            let request = try parseRequest(requestData)
            requestedPath = request.target
            guard request.method == "GET" || request.method == "HEAD" else {
                sendError(
                    405,
                    reason: "Method Not Allowed",
                    extraHeaders: ["Allow": "GET, HEAD"],
                    connection: connection
                )
                return
            }

            let resolution = try resolveRequestTarget(request.target)
            let fileURL = resolution.fileURL
            let values = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentTypeKey
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ServerError.notFound
            }

            let fileSize = Int64(values.fileSize ?? 0)
            let requestedRange: ClosedRange<Int64>?
            do {
                requestedRange = try Self.byteRange(
                    from: request.headers["range"],
                    fileSize: fileSize
                )
            } catch ServerError.invalidRange {
                sendError(
                    416,
                    reason: "Range Not Satisfiable",
                    extraHeaders: ["Content-Range": "bytes */\(fileSize)"],
                    connection: connection
                )
                return
            }

            let startOffset = requestedRange?.lowerBound ?? 0
            let endOffset = requestedRange?.upperBound ?? max(0, fileSize - 1)
            let responseLength = fileSize == 0 ? 0 : endOffset - startOffset + 1
            let mimeType = Self.mimeType(for: fileURL, type: values.contentType)
            var headers = [
                "Accept-Ranges": "bytes",
                "Cache-Control": "no-store",
                "Connection": "close",
                "Content-Length": String(responseLength),
                "Content-Type": mimeType,
                "Cross-Origin-Resource-Policy": "same-origin",
                "X-Content-Type-Options": "nosniff"
            ]
            if requestedRange != nil {
                headers["Content-Range"] = "bytes \(startOffset)-\(endOffset)/\(fileSize)"
            }
            let status = requestedRange == nil ? 200 : 206
            let reason = requestedRange == nil ? "OK" : "Partial Content"
            let header = Self.responseHeader(status: status, reason: reason, headers: headers)

            requestCount += 1
            totalBytes += UInt64(max(0, responseLength))
            if requestCount <= 100 || requestCount % 100 == 0 {
                onAccess(
                    resolution.relativePath.rawValue,
                    mimeType,
                    responseLength,
                    requestCount,
                    totalBytes
                )
            }

            if request.method == "HEAD" || responseLength == 0 {
                connection.send(
                    content: header,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { [weak self, weak connection] _ in
                        guard let self, let connection else { return }
                        finish(connection)
                    }
                )
                return
            }

            let handle = try FileHandle(forReadingFrom: fileURL)
            try handle.seek(toOffset: UInt64(startOffset))
            connection.send(
                content: header,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { [weak self, weak connection] error in
                    guard let self, let connection else {
                        try? handle.close()
                        return
                    }
                    guard error == nil else {
                        try? handle.close()
                        finish(connection)
                        return
                    }
                    sendFile(
                        handle,
                        remaining: responseLength,
                        connection: connection
                    )
                }
            )
        } catch {
            onError(String(describing: error), requestedPath)
            let status = (error as? ServerError) == .notFound ? 404 : 400
            sendError(
                status,
                reason: status == 404 ? "Not Found" : "Bad Request",
                connection: connection
            )
        }
    }

    private func sendFile(
        _ handle: FileHandle,
        remaining: Int64,
        connection: NWConnection
    ) {
        do {
            let data = try handle.read(upToCount: Int(min(64 * 1_024, remaining))) ?? Data()
            guard !data.isEmpty else {
                try? handle.close()
                finish(connection)
                return
            }
            let nextRemaining = remaining - Int64(data.count)
            let isFinal = nextRemaining == 0
            connection.send(
                content: data,
                contentContext: isFinal ? .finalMessage : .defaultMessage,
                isComplete: isFinal,
                completion: .contentProcessed { [weak self, weak connection] error in
                    guard let self, let connection else {
                        try? handle.close()
                        return
                    }
                    guard error == nil, !isFinal else {
                        try? handle.close()
                        finish(connection)
                        return
                    }
                    sendFile(handle, remaining: nextRemaining, connection: connection)
                }
            )
        } catch {
            try? handle.close()
            onError(String(describing: error), "<file-read>")
            finish(connection)
        }
    }

    private func sendError(
        _ status: Int,
        reason: String,
        extraHeaders: [String: String] = [:],
        connection: NWConnection
    ) {
        let body = Data("\(status) \(reason)\n".utf8)
        var headers = [
            "Cache-Control": "no-store",
            "Connection": "close",
            "Content-Length": String(body.count),
            "Content-Type": "text/plain; charset=utf-8",
            "X-Content-Type-Options": "nosniff"
        ]
        extraHeaders.forEach { headers[$0.key] = $0.value }
        var response = Self.responseHeader(status: status, reason: reason, headers: headers)
        response.append(body)
        connection.send(
            content: response,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self, weak connection] _ in
                guard let self, let connection else { return }
                finish(connection)
            }
        )
    }

    private func finish(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func parseRequest(_ data: Data) throws -> HTTPRequest {
        guard let text = String(data: data, encoding: .isoLatin1),
              let headerEnd = text.range(of: "\r\n\r\n")
        else { throw ServerError.invalidRequest }
        let lines = text[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
        guard let first = lines.first else { throw ServerError.invalidRequest }
        let requestLine = first.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count == 3,
              requestLine[2].hasPrefix("HTTP/1.")
        else { throw ServerError.invalidRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                throw ServerError.invalidRequest
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw ServerError.invalidRequest }
            headers[key] = value
        }
        return HTTPRequest(
            method: requestLine[0].uppercased(),
            target: requestLine[1],
            headers: headers
        )
    }

    private func resolveRequestTarget(_ target: String) throws -> Resolution {
        guard target.hasPrefix("/"),
              let components = URLComponents(string: "http://127.0.0.1\(target)")
        else { throw ServerError.invalidRequest }
        let decodedPath = components.percentEncodedPath.removingPercentEncoding
            ?? components.percentEncodedPath
        var pathComponents = decodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let selectedRoot: URL
        if let prefix = pathComponents.first?.lowercased(),
           let routedRoot = additionalRoots[prefix] {
            selectedRoot = routedRoot
            pathComponents.removeFirst()
        } else {
            selectedRoot = rootURL
        }
        if pathComponents.isEmpty || decodedPath.hasSuffix("/") {
            pathComponents.append("index.html")
        }
        let relativePath = try StorageRelativePath(
            rawValue: pathComponents.joined(separator: "/")
        )
        let fileURL = try resolveFile(
            components: pathComponents,
            relativePath: relativePath,
            under: selectedRoot
        )
        return Resolution(relativePath: relativePath, fileURL: fileURL)
    }

    private func resolveFile(
        components: [String],
        relativePath: StorageRelativePath,
        under root: URL
    ) throws -> URL {
        let cacheKey = root.path + "\n" + relativePath.rawValue.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        if let cached = resolvedPathCache[cacheKey] { return cached }

        let fileManager = FileManager.default
        var candidate = root
        for component in components {
            let exact = candidate.appendingPathComponent(component)
            if fileManager.fileExists(atPath: exact.path) {
                candidate = exact
                continue
            }
            let children = try fileManager.contentsOfDirectory(
                at: candidate,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            )
            guard let matched = children.first(where: { child in
                child.lastPathComponent.compare(
                    component,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                ) == .orderedSame
            }) else { throw ServerError.notFound }
            candidate = matched
        }

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
            throw ServerError.invalidRequest
        }
        resolvedPathCache[cacheKey] = resolvedCandidate
        return resolvedCandidate
    }

    private static func byteRange(
        from header: String?,
        fileSize: Int64
    ) throws -> ClosedRange<Int64>? {
        guard let header else { return nil }
        guard fileSize > 0,
              header.lowercased().hasPrefix("bytes="),
              !header.contains(",")
        else { throw ServerError.invalidRange }

        let value = header.dropFirst("bytes=".count)
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw ServerError.invalidRange }
        if parts[0].isEmpty {
            guard let suffixLength = Int64(parts[1]), suffixLength > 0 else {
                throw ServerError.invalidRange
            }
            return max(0, fileSize - suffixLength)...(fileSize - 1)
        }
        guard let start = Int64(parts[0]), start >= 0, start < fileSize else {
            throw ServerError.invalidRange
        }
        if parts[1].isEmpty { return start...(fileSize - 1) }
        guard let requestedEnd = Int64(parts[1]), requestedEnd >= start else {
            throw ServerError.invalidRange
        }
        return start...min(requestedEnd, fileSize - 1)
    }

    private static func mimeType(for url: URL, type: UTType?) -> String {
        switch url.pathExtension.lowercased() {
        case "css": "text/css"
        case "html", "htm": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript"
        case "json": "application/json"
        case "wasm": "application/wasm"
        case "swf": "application/x-shockwave-flash"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        default: type?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    private static func responseHeader(
        status: Int,
        reason: String,
        headers: [String: String]
    ) -> Data {
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for key in headers.keys.sorted() {
            text += "\(key): \(headers[key]!)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    private struct HTTPRequest {
        let method: String
        let target: String
        let headers: [String: String]
    }

    private struct Resolution {
        let relativePath: StorageRelativePath
        let fileURL: URL
    }
}
