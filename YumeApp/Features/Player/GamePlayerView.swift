import SwiftUI
@preconcurrency import WebKit
import UniformTypeIdentifiers
import YumeApplication
import YumeDomain
import YumeEngineHost

struct GamePlayerView: View {
    let session: GamePlaySession
    let suspended: Bool
    let onResume: () -> Void
    let onClose: () -> Void

    @State private var loadFailed = false
    @State private var inputCommand: WebInputCommand?
    @AppStorage("controls.virtual.enabled") private var virtualControlsEnabled = true
    @AppStorage("controls.haptics.enabled") private var hapticsEnabled = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            playerContent
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
        .overlay(alignment: .bottom) {
            if suspended {
                suspensionOverlay
            }
        }
        .persistentSystemOverlays(.hidden)
    }

    @ViewBuilder
    private var playerContent: some View {
        switch session.launchPlan.kind {
        case .web:
            RestrictedWebGameView(
                location: session.content,
                mode: .game,
                suspended: suspended,
                inputCommand: inputCommand,
                loadFailed: $loadFailed
            )
        case let .embeddedWebRuntime(runtimeIdentifier):
            if runtimeIdentifier == "ruffle-web",
               let movie = session.content.runtimeEntryPoint,
               let runtimeRoot = RuffleRuntimeResources.rootURL {
                RestrictedWebGameView(
                    location: session.content,
                    mode: .ruffle(runtimeRoot: runtimeRoot, movie: movie),
                    suspended: suspended,
                    inputCommand: inputCommand,
                    loadFailed: $loadFailed
                )
            } else {
                RuntimeUnavailablePlayerView(loadFailed: $loadFailed)
            }
        case let .hostedRuntime(runtimeIdentifier):
            NativeRuntimePlayerView(
                playSession: session,
                runtimeIdentifier: runtimeIdentifier,
                suspended: suspended,
                inputCommand: inputCommand,
                loadFailed: $loadFailed
            )
        case .notPlanned:
            RuntimeUnavailablePlayerView(loadFailed: $loadFailed)
        }
    }

    private var suspensionOverlay: some View {
        VStack(spacing: 14) {
            Label("player.suspended.title", systemImage: "pause.circle.fill")
                .font(.headline)
            Button(action: onResume) {
                Label("player.resume", systemImage: "play.fill")
                    .frame(minWidth: 140, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(24)
    }
}

private struct RestrictedWebGameView: UIViewRepresentable {
    let location: GameContentLocation
    let mode: WebPlayerMode
    let suspended: Bool
    let inputCommand: WebInputCommand?
    @Binding var loadFailed: Bool

    static let mediaPauseFallbackScript = """
    document.querySelectorAll('video,audio').forEach(m => m.pause());
    """

    static func lifecycleScript(suspended: Bool) -> String {
        suspended
            ? "window.dispatchEvent(new Event('blur')); document.dispatchEvent(new CustomEvent('yumepause'));"
            : "window.dispatchEvent(new Event('focus')); document.dispatchEvent(new CustomEvent('yumeresume'));"
    }

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
        let additionalRoots: [String: URL]
        switch mode {
        case .game:
            additionalRoots = [:]
        case let .ruffle(runtimeRoot, _):
            additionalRoots = ["runtime": runtimeRoot]
        }
        configuration.setURLSchemeHandler(
            LocalGameSchemeHandler(
                gameID: location.game.id.rawValue,
                rootURL: location.rootURL,
                additionalRoots: additionalRoots
            ),
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

        context.coordinator.installNetworkBlockerAndLoad(webView, location: location, mode: mode)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if suspended != context.coordinator.isSuspended {
            context.coordinator.isSuspended = suspended
            webView.setAllMediaPlaybackSuspended(suspended) {}
            if suspended {
                webView.evaluateJavaScript(Self.mediaPauseFallbackScript)
            }
            webView.evaluateJavaScript(Self.lifecycleScript(suspended: suspended))
        }

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
        var isSuspended = false

        init(loadFailed: Binding<Bool>) {
            _loadFailed = loadFailed
        }

        func installNetworkBlockerAndLoad(
            _ webView: WKWebView,
            location: GameContentLocation,
            mode: WebPlayerMode
        ) {
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
                    self.load(webView, location: location, mode: mode)
                }
            }
        }

        private func load(
            _ webView: WKWebView,
            location: GameContentLocation,
            mode: WebPlayerMode
        ) {
            let host = location.game.id.rawValue.uuidString.lowercased()
            let url: URL?
            switch mode {
            case .game:
                guard let entryPoint = location.webEntryPoint else {
                    loadFailed = true
                    return
                }
                let entry = entryPoint.rawValue.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) ?? entryPoint.rawValue
                url = URL(string: "\(LocalGameSchemeHandler.scheme)://\(host)/\(entry)")
            case let .ruffle(_, movie):
                let moviePath = movie.rawValue.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) ?? movie.rawValue
                let movieURL = "\(LocalGameSchemeHandler.scheme)://\(host)/\(moviePath)"
                var components = URLComponents(
                    string: "\(LocalGameSchemeHandler.scheme)://\(host)/runtime/index.html"
                )
                components?.queryItems = [URLQueryItem(name: "movie", value: movieURL)]
                url = components?.url
            }
            guard let url else {
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

private enum WebPlayerMode: Equatable {
    case game
    case ruffle(runtimeRoot: URL, movie: StorageRelativePath)
}

private enum RuffleRuntimeResources {
    static var rootURL: URL? {
        let candidates = [
            Bundle.main.resourceURL?
                .appendingPathComponent("Runtimes", isDirectory: true)
                .appendingPathComponent("Ruffle", isDirectory: true),
            Bundle.main.url(forResource: "index", withExtension: "html")?.deletingLastPathComponent()
        ].compactMap { $0 }
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("ruffle.js").path)
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path)
        }
    }
}

private struct RuntimeUnavailablePlayerView: View {
    @Binding var loadFailed: Bool

    var body: some View {
        Color.black
            .task { loadFailed = true }
    }
}

private struct NativeRuntimePlayerView: UIViewRepresentable {
    let playSession: GamePlaySession
    let runtimeIdentifier: String
    let suspended: Bool
    let inputCommand: WebInputCommand?
    @Binding var loadFailed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(loadFailed: $loadFailed)
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        do {
            let content = playSession.content
            let prepared = PreparedGame(
                gameID: content.game.id,
                engineID: content.game.engine.id,
                contentRootURL: content.rootURL,
                saveRootURL: content.saveRootURL,
                derivedRootURL: content.derivedRootURL,
                logRootURL: content.logRootURL,
                rtpMountRoots: playSession.rtpMountRoots
            )
            let runtime = try NativeRuntimeSession(
                runtimeIdentifier: runtimeIdentifier,
                game: prepared,
                context: EngineContext(
                    sessionID: playSession.id,
                    localeIdentifier: Locale.current.identifier,
                    networkingAllowed: false
                )
            )
            context.coordinator.install(runtime: runtime, in: container)
        } catch {
            loadFailed = true
        }
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.setSuspended(suspended)
        guard let inputCommand,
              context.coordinator.lastInputCommandID != inputCommand.id,
              let action = inputCommand.nativeAction
        else { return }
        context.coordinator.lastInputCommandID = inputCommand.id
        context.coordinator.sendTap(action)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.stop()
        view.subviews.forEach { $0.removeFromSuperview() }
    }

    @MainActor
    final class Coordinator {
        @Binding private var loadFailed: Bool
        private var runtime: NativeRuntimeSession?
        private var eventTask: Task<Void, Never>?
        private var attachTask: Task<Void, Never>?
        private var isSuspended = false
        var lastInputCommandID: UUID?

        init(loadFailed: Binding<Bool>) {
            _loadFailed = loadFailed
        }

        func install(runtime: NativeRuntimeSession, in container: UIView) {
            self.runtime = runtime
            eventTask = Task { @MainActor [weak self] in
                for await event in runtime.events {
                    guard let self else { return }
                    if case .failed = event { loadFailed = true }
                }
            }
            attachTask = Task { @MainActor [weak self, weak container] in
                do {
                    try await runtime.start()
                } catch {
                    self?.loadFailed = true
                    return
                }
                for _ in 0..<200 {
                    guard let self, let container, self.runtime != nil else { return }
                    if let gameView = runtime.nativeView() {
                        gameView.removeFromSuperview()
                        gameView.frame = container.bounds
                        gameView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                        container.insertSubview(gameView, at: 0)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(25))
                }
                self?.loadFailed = true
            }
        }

        func setSuspended(_ suspended: Bool) {
            guard suspended != isSuspended, let runtime else { return }
            isSuspended = suspended
            Task {
                if suspended { await runtime.pause() } else { await runtime.resume() }
            }
        }

        func sendTap(_ action: EngineInputAction) {
            guard let runtime else { return }
            Task {
                await runtime.send(.button(action: action, pressed: true))
                try? await Task.sleep(for: .milliseconds(50))
                await runtime.send(.button(action: action, pressed: false))
            }
        }

        func stop() {
            eventTask?.cancel()
            eventTask = nil
            attachTask?.cancel()
            attachTask = nil
            guard let runtime else { return }
            self.runtime = nil
            Task { await runtime.stop() }
        }
    }
}

private struct WebInputCommand: Equatable {
    let id = UUID()
    let keyCode: Int

    var nativeAction: EngineInputAction? {
        switch keyCode {
        case 38: .up
        case 40: .down
        case 37: .left
        case 39: .right
        case 90: .confirm
        case 88: .cancel
        default: nil
        }
    }
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
    private let additionalRoots: [String: URL]
    private let queue = DispatchQueue(label: "com.yume.local-game-resources", qos: .userInitiated)
    private let lock = NSLock()
    private var stoppedTasks: Set<ObjectIdentifier> = []

    init(gameID: UUID, rootURL: URL, additionalRoots: [String: URL] = [:]) {
        self.gameID = gameID
        self.rootURL = rootURL.standardizedFileURL
        self.additionalRoots = additionalRoots.mapValues(\.standardizedFileURL)
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
            var components = decodedPath
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            let selectedRoot: URL
            if let prefix = components.first, let routedRoot = additionalRoots[prefix] {
                selectedRoot = routedRoot
                components.removeFirst()
            } else {
                selectedRoot = rootURL
            }
            let relativeValue = components.joined(separator: "/")
            let relativePath = try StorageRelativePath(rawValue: relativeValue)
            let fileURL = selectedRoot.appendingPathComponent(relativePath.rawValue).standardizedFileURL
            guard fileURL.path.hasPrefix(selectedRoot.path + "/") else {
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

            let mimeType: String
            switch fileURL.pathExtension.lowercased() {
            case "wasm": mimeType = "application/wasm"
            case "swf": mimeType = "application/x-shockwave-flash"
            case "js": mimeType = "text/javascript"
            case "html", "htm": mimeType = "text/html"
            default: mimeType = values.contentType?.preferredMIMEType ?? "application/octet-stream"
            }
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
          const utf8Length = value => new TextEncoder().encode(value).length;
          const persist = message => {
            if (utf8Length(JSON.stringify(values)) > \(Self.maximumStoreByteCount)) {
              throw new DOMException("Storage quota exceeded", "QuotaExceededError");
            }
            window.webkit.messageHandlers.\(Self.messageName).postMessage(message);
          };
          const storage = {
            get length() { return keys().length; },
            key(index) { const key = keys()[Number(index)]; return key === undefined ? null : key; },
            getItem(key) { key = String(key); return Object.prototype.hasOwnProperty.call(values, key) ? values[key] : null; },
            setItem(key, value) {
              key = String(key); value = String(value);
              if (utf8Length(key) > \(Self.maximumKeyByteCount) ||
                  utf8Length(value) > \(Self.maximumValueByteCount)) {
                throw new DOMException("Storage quota exceeded", "QuotaExceededError");
              }
              const previous = Object.prototype.hasOwnProperty.call(values, key) ? values[key] : undefined;
              values[key] = value;
              try { persist({op: "set", key, value}); }
              catch (error) {
                if (previous === undefined) delete values[key]; else values[key] = previous;
                throw error;
              }
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
        queue.async { [self, operation, key, value] in
            apply(operation: operation, key: key, value: value)
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
