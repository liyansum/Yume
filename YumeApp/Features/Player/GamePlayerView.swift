import SwiftUI
@preconcurrency import WebKit
import UniformTypeIdentifiers
import YumeApplication
import YumeDomain

struct GamePlayerView: View {
    let location: GameContentLocation
    let onClose: () -> Void

    @State private var loadFailed = false
    @State private var inputCommand: WebInputCommand?
    @AppStorage("controls.virtual.enabled") private var virtualControlsEnabled = true
    @AppStorage("controls.haptics.enabled") private var hapticsEnabled = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            RestrictedWebGameView(
                location: location,
                inputCommand: inputCommand,
                loadFailed: $loadFailed
            )
                .ignoresSafeArea()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(.primary)
            .padding()
            .accessibilityLabel("player.close")

            if loadFailed {
                ContentUnavailableView(
                    "player.loadFailure.title",
                    systemImage: "exclamationmark.triangle",
                    description: Text("player.loadFailure.message")
                )
                .foregroundStyle(.white)
                .padding()
            }

            if virtualControlsEnabled && !loadFailed {
                GameVirtualControls { keyCode in
                    inputCommand = WebInputCommand(keyCode: keyCode)
                    if hapticsEnabled {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }
        }
        .persistentSystemOverlays(.hidden)
    }
}

private struct RestrictedWebGameView: UIViewRepresentable {
    let location: GameContentLocation
    let inputCommand: WebInputCommand?
    @Binding var loadFailed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(loadFailed: $loadFailed)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isElementFullscreenEnabled = true
        let storageBridge = GameLocalStorageBridge(saveRootURL: location.saveRootURL)
        configuration.userContentController.add(storageBridge, name: GameLocalStorageBridge.messageName)
        configuration.userContentController.addUserScript(storageBridge.bootstrapScript())
        configuration.setURLSchemeHandler(
            LocalGameSchemeHandler(gameID: location.game.id.rawValue, rootURL: location.rootURL),
            forURLScheme: LocalGameSchemeHandler.scheme
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false

        context.coordinator.installNetworkBlockerAndLoad(webView, location: location)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let inputCommand, context.coordinator.lastInputCommandID != inputCommand.id else { return }
        context.coordinator.lastInputCommandID = inputCommand.id
        let script = """
        (() => {
          const options = {keyCode: \(inputCommand.keyCode), which: \(inputCommand.keyCode), bubbles: true};
          document.dispatchEvent(new KeyboardEvent("keydown", options));
          document.dispatchEvent(new KeyboardEvent("keyup", options));
        })();
        """
        webView.evaluateJavaScript(script)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding private var loadFailed: Bool
        var lastInputCommandID: UUID?

        init(loadFailed: Binding<Bool>) {
            _loadFailed = loadFailed
        }

        func installNetworkBlockerAndLoad(_ webView: WKWebView, location: GameContentLocation) {
            let rules = """
            [{"trigger":{"url-filter":"^(https?|wss?|file)://"},"action":{"type":"block"}}]
            """
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "yume-offline-network-policy-v1",
                encodedContentRuleList: rules
            ) { [weak self, weak webView] ruleList, error in
                Task { @MainActor in
                    guard let self, let webView, error == nil, let ruleList else {
                        self?.loadFailed = true
                        return
                    }
                    webView.configuration.userContentController.add(ruleList)
                    self.load(webView, location: location)
                }
            }
        }

        private func load(_ webView: WKWebView, location: GameContentLocation) {
            let entry = location.entryPoint.rawValue.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? location.entryPoint.rawValue
            let host = location.game.id.rawValue.uuidString.lowercased()
            guard let url = URL(string: "\(LocalGameSchemeHandler.scheme)://\(host)/\(entry)") else {
                loadFailed = true
                return
            }
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let allowed = url.scheme == LocalGameSchemeHandler.scheme || url.absoluteString == "about:blank"
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            loadFailed = true
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            loadFailed = true
        }
    }
}

private struct WebInputCommand: Equatable {
    let id = UUID()
    let keyCode: Int
}

private struct GameVirtualControls: View {
    let send: (Int) -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                directionalPad
                Spacer()
                HStack(spacing: 14) {
                    controlButton("xmark", keyCode: 88, accessibilityKey: "controls.cancel")
                    controlButton("checkmark", keyCode: 90, accessibilityKey: "controls.confirm")
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    private var directionalPad: some View {
        VStack(spacing: 2) {
            controlButton("chevron.up", keyCode: 38, accessibilityKey: "controls.up")
            HStack(spacing: 38) {
                controlButton("chevron.left", keyCode: 37, accessibilityKey: "controls.left")
                controlButton("chevron.right", keyCode: 39, accessibilityKey: "controls.right")
            }
            controlButton("chevron.down", keyCode: 40, accessibilityKey: "controls.down")
        }
    }

    private func controlButton(
        _ symbol: String,
        keyCode: Int,
        accessibilityKey: LocalizedStringKey
    ) -> some View {
        Button {
            send(keyCode)
        } label: {
            Image(systemName: symbol)
                .font(.title3.bold())
                .frame(width: 50, height: 50)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(accessibilityKey)
    }
}

private nonisolated final class LocalGameSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "yume-game"

    private let gameID: UUID
    private let rootURL: URL
    private let queue = DispatchQueue(label: "com.yume.local-game-resources", qos: .userInitiated)
    private let lock = NSLock()
    private var stoppedTasks: Set<ObjectIdentifier> = []

    init(gameID: UUID, rootURL: URL) {
        self.gameID = gameID
        self.rootURL = rootURL.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask)
        lock.withLock { stoppedTasks.remove(identifier) }
        let taskBox = SchemeTaskBox(value: urlSchemeTask)
        queue.async { [weak self, taskBox] in
            self?.serve(taskBox.value, identifier: identifier)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask)
        lock.withLock { stoppedTasks.insert(identifier) }
    }

    private func serve(_ task: any WKURLSchemeTask, identifier: ObjectIdentifier) {
        defer {
            lock.withLock { stoppedTasks.remove(identifier) }
        }
        do {
            guard let requestURL = task.request.url,
                  requestURL.scheme == Self.scheme,
                  requestURL.host?.caseInsensitiveCompare(gameID.uuidString) == .orderedSame
            else {
                throw ResourceError.invalidRequest
            }

            let decodedPath = requestURL.path.removingPercentEncoding ?? requestURL.path
            let relativeValue = decodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let relativePath = try StorageRelativePath(rawValue: relativeValue)
            let fileURL = rootURL.appendingPathComponent(relativePath.rawValue).standardizedFileURL
            guard fileURL.path.hasPrefix(rootURL.path + "/") else {
                throw ResourceError.invalidRequest
            }

            let values = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentTypeKey
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ResourceError.notFound
            }
            guard !isStopped(identifier) else { return }

            let mimeType = values.contentType?.preferredMIMEType ?? "application/octet-stream"
            let fileSize = Int64(values.fileSize ?? 0)
            let requestedRange = try Self.byteRange(
                from: task.request.value(forHTTPHeaderField: "Range"),
                fileSize: fileSize
            )
            let startOffset = requestedRange?.lowerBound ?? 0
            let endOffset = requestedRange?.upperBound ?? max(0, fileSize - 1)
            let responseLength = fileSize == 0 ? 0 : endOffset - startOffset + 1
            var headers = [
                "Content-Type": mimeType,
                "Content-Length": String(responseLength),
                "Accept-Ranges": "bytes"
            ]
            if requestedRange != nil {
                headers["Content-Range"] = "bytes \(startOffset)-\(endOffset)/\(fileSize)"
            }
            guard let response = HTTPURLResponse(
                url: requestURL,
                statusCode: requestedRange == nil ? 200 : 206,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                throw ResourceError.invalidRequest
            }
            task.didReceive(response)

            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(startOffset))
            var remaining = responseLength
            while !isStopped(identifier), remaining > 0 {
                let chunkSize = Int(min(Int64(64 * 1_024), remaining))
                let data = try handle.read(upToCount: chunkSize) ?? Data()
                guard !data.isEmpty else { break }
                task.didReceive(data)
                remaining -= Int64(data.count)
            }
            guard !isStopped(identifier) else { return }
            task.didFinish()
        } catch {
            guard !isStopped(identifier) else { return }
            task.didFailWithError(error)
        }
    }

    private func isStopped(_ identifier: ObjectIdentifier) -> Bool {
        lock.withLock { stoppedTasks.contains(identifier) }
    }

    private static func byteRange(from header: String?, fileSize: Int64) throws -> ClosedRange<Int64>? {
        guard let header else { return nil }
        guard fileSize > 0,
              header.hasPrefix("bytes="),
              !header.contains(",")
        else { throw ResourceError.invalidRange }

        let value = header.dropFirst("bytes=".count)
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw ResourceError.invalidRange }

        if parts[0].isEmpty {
            guard let suffixLength = Int64(parts[1]), suffixLength > 0 else {
                throw ResourceError.invalidRange
            }
            let start = max(0, fileSize - suffixLength)
            return start...(fileSize - 1)
        }

        guard let start = Int64(parts[0]), start >= 0, start < fileSize else {
            throw ResourceError.invalidRange
        }
        let end: Int64
        if parts[1].isEmpty {
            end = fileSize - 1
        } else if let requestedEnd = Int64(parts[1]), requestedEnd >= start {
            end = min(requestedEnd, fileSize - 1)
        } else {
            throw ResourceError.invalidRange
        }
        return start...end
    }

    private enum ResourceError: Error {
        case invalidRequest
        case notFound
        case invalidRange
    }

    private struct SchemeTaskBox: @unchecked Sendable {
        let value: any WKURLSchemeTask
    }
}

private nonisolated final class GameLocalStorageBridge: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    static let messageName = "yumeStorage"

    private static let maximumKeyByteCount = 4 * 1_024
    private static let maximumValueByteCount = 8 * 1_024 * 1_024
    private static let maximumStoreByteCount = 20 * 1_024 * 1_024

    private let saveFileURL: URL
    private let queue = DispatchQueue(label: "com.yume.game-save-storage", qos: .utility)
    private var values: [String: String]

    init(saveRootURL: URL) {
        self.saveFileURL = saveRootURL.appendingPathComponent("local-storage.json")
        self.values = Self.loadValues(from: saveFileURL)
    }

    func bootstrapScript() -> WKUserScript {
        let encodedValues = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data("{}".utf8)
        let json = String(decoding: encodedValues, as: UTF8.self)
        let source = """
        (() => {
          const values = \(json);
          const keys = () => Object.keys(values);
          const storage = {
            get length() { return keys().length; },
            key(index) { const key = keys()[Number(index)]; return key === undefined ? null : key; },
            getItem(key) { key = String(key); return Object.prototype.hasOwnProperty.call(values, key) ? values[key] : null; },
            setItem(key, value) {
              key = String(key); value = String(value); values[key] = value;
              window.webkit.messageHandlers.\(Self.messageName).postMessage({op: "set", key, value});
            },
            removeItem(key) {
              key = String(key); delete values[key];
              window.webkit.messageHandlers.\(Self.messageName).postMessage({op: "remove", key});
            },
            clear() {
              Object.keys(values).forEach(key => delete values[key]);
              window.webkit.messageHandlers.\(Self.messageName).postMessage({op: "clear"});
            }
          };
          Object.defineProperty(window, "localStorage", {value: storage, configurable: false});
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageName,
              let body = message.body as? [String: Any],
              let operation = body["op"] as? String
        else { return }

        let key = body["key"] as? String
        let value = body["value"] as? String
        queue.async { [weak self, operation, key, value] in
            self?.apply(operation: operation, key: key, value: value)
        }
    }

    private func apply(operation: String, key: String?, value: String?) {
        switch operation {
        case "set":
            guard let key, let value,
                  key.utf8.count <= Self.maximumKeyByteCount,
                  value.utf8.count <= Self.maximumValueByteCount
            else { return }
            var candidate = values
            candidate[key] = value
            guard let data = try? JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys]),
                  data.count <= Self.maximumStoreByteCount
            else { return }
            values = candidate
            write(data)
        case "remove":
            guard let key else { return }
            values.removeValue(forKey: key)
            persistValues()
        case "clear":
            values.removeAll(keepingCapacity: false)
            persistValues()
        default:
            break
        }
    }

    private func persistValues() {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
        write(data)
    }

    private func write(_ data: Data) {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try? data.write(to: saveFileURL, options: options)
    }

    private static func loadValues(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= maximumStoreByteCount,
              let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [String: String]
        else { return [:] }
        return values
    }
}
