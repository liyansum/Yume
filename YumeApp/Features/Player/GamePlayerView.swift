import SwiftUI
@preconcurrency import WebKit
import QuartzCore
import YumeApplication
import YumeDomain
import YumeEngineHost

struct GamePlayerView: View {
    let session: GamePlaySession
    let suspended: Bool
    let onResume: () -> Void
    let onClose: () -> Void
    let onLog: (_ message: String, _ isError: Bool, _ metadata: [String: String]) -> Void

    @State private var loadFailed = false
    @State private var restartRequired = false
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
            .accessibilityLabel(Text("player.close"))

            if loadFailed {
                ContentUnavailableView(
                    "player.loadFailure.title",
                    systemImage: "exclamationmark.triangle",
                    description: Text(LocalizedStringKey(restartRequired ? "player.restartRequired.message" : "player.loadFailure.message"))
                )
                .foregroundStyle(.white)
                .padding()
            }

            if showsVirtualControls {
                GameVirtualControls { keyCode, pressed in
                    inputCommand = WebInputCommand(keyCode: keyCode, pressed: pressed)
                    if pressed && hapticsEnabled {
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
        .onAppear {
            onLog(
                "player.view.appeared",
                false,
                ["gameID": session.content.game.id.rawValue.uuidString]
            )
        }
        .onChange(of: loadFailed) { _, failed in
            if failed {
                onLog(
                    "player.view.load-failed",
                    true,
                    ["gameID": session.content.game.id.rawValue.uuidString]
                )
            }
        }
        .onDisappear {
            onLog(
                "player.view.disappeared",
                false,
                ["gameID": session.content.game.id.rawValue.uuidString]
            )
        }
    }

    private var showsVirtualControls: Bool {
        guard virtualControlsEnabled, !loadFailed, !suspended else { return false }
        switch session.launchPlan.kind {
        case .web, .embeddedWebRuntime, .hostedRuntime:
            return true
        default:
            return false
        }
    }

    private func recordRuntimeLog(_ message: String, _ isError: Bool, _ metadata: [String: String]) {
        if metadata["requiresRestart"] == "true" || metadata["code"] == "runtime.stop-timeout" {
            restartRequired = true
        }
        onLog(message, isError, metadata)
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
                    onLog: recordRuntimeLog,
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
                    onLog: recordRuntimeLog,
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
                onLog: recordRuntimeLog,
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
    let onLog: (_ message: String, _ isError: Bool, _ metadata: [String: String]) -> Void
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
        Coordinator(
            loadFailed: $loadFailed,
            onLog: onLog,
            game: location.game,
            runtime: mode.runtimeIdentifier
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let storageBridge = GameLocalStorageBridge(saveRootURL: location.saveRootURL)
        configuration.userContentController.add(storageBridge, name: GameLocalStorageBridge.messageName)
        configuration.userContentController.addUserScript(storageBridge.bootstrapScript())
        let diagnosticsBridge = WebDiagnosticsBridge(onMessage: context.coordinator.handleWebMessage)
        configuration.userContentController.add(
            diagnosticsBridge,
            name: WebDiagnosticsBridge.messageName
        )
        configuration.userContentController.addUserScript(diagnosticsBridge.bootstrapScript(engineID: location.game.engine.id.rawValue))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.scrollView.isScrollEnabled = false
        if #available(iOS 16.4, *) {
            webView.isInspectable = false
        }

        context.coordinator.startLocalServerAndLoad(
            webView,
            location: location,
            mode: mode
        )
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
        let script = "window.__yumeSetKey?.(\(inputCommand.keyCode), \(inputCommand.pressed ? "true" : "false"));"
        context.coordinator.sendInput(script, keyCode: inputCommand.keyCode, webView: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.evaluateJavaScript("window.dispatchEvent(new Event('pagehide'));")
        coordinator.stopLocalServer()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, @unchecked Sendable {
        @Binding private var loadFailed: Bool
        private let onLog: (_ message: String, _ isError: Bool, _ metadata: [String: String]) -> Void
        private let baseMetadata: [String: String]
        private var navigationStartedAt: CFTimeInterval?
        private var webMessageCount = 0
        private var localServer: LocalGameHTTPServer?
        private var allowedOrigin: String?
        private var runtimeRoutePrefix: String?
        private weak var hostedWebView: WKWebView?
        var lastInputCommandID: UUID?
        var isSuspended = false

        init(
            loadFailed: Binding<Bool>,
            onLog: @escaping (_ message: String, _ isError: Bool, _ metadata: [String: String]) -> Void,
            game: ImportedGame,
            runtime: String
        ) {
            _loadFailed = loadFailed
            self.onLog = onLog
            self.baseMetadata = [
                "gameID": game.id.rawValue.uuidString,
                "engine": game.engine.id.rawValue,
                "runtime": runtime
            ]
        }

        func handleWebMessage(_ kind: String, _ message: String, _ details: [String: String]) {
            webMessageCount += 1
            let isError = kind == "error"
                || kind == "unhandled-rejection"
                || kind == "console-error" || kind == "resource-error"
                || kind == "context-lost" || kind == "storage-error"
            var values = details
            values["sequence"] = String(webMessageCount)
            onLog("web.\(kind)", isError || kind == "runtime-failed", metadata(values, message: message))
            if kind == "runtime-failed" { loadFailed = true }
        }

        func handleResourceError(_ message: String, path: String) {
            onLog("web.resource-failed", true, metadata(["path": path], message: message))
        }

        func handleResourceAccess(
            path: String,
            mimeType: String,
            bytes: Int64,
            requestCount: UInt64,
            totalBytes: UInt64
        ) {
            onLog(
                "web.resource-served",
                false,
                metadata([
                    "path": path,
                    "mime": mimeType,
                    "bytes": String(bytes),
                    "requestCount": String(requestCount),
                    "totalBytes": String(totalBytes)
                ])
            )
        }

        func sendInput(_ script: String, keyCode: Int, webView: WKWebView) {
            let startedAt = CACurrentMediaTime()
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard let self else { return }
                self.onLog(
                    "web.input-dispatched",
                    error != nil,
                    self.metadata([
                        "keyCode": String(keyCode),
                        "elapsedMs": String(format: "%.2f", (CACurrentMediaTime() - startedAt) * 1_000),
                        "error": error.map { String(describing: $0) } ?? "none"
                    ])
                )
            }
        }

        func startLocalServerAndLoad(
            _ webView: WKWebView,
            location: GameContentLocation,
            mode: WebPlayerMode
        ) {
            hostedWebView = webView
            let additionalRoots: [String: URL]
            switch mode {
            case .game:
                runtimeRoutePrefix = nil
                additionalRoots = [:]
            case let .ruffle(runtimeRoot, _):
                // A fixed route such as /runtime can shadow a real directory
                // in the imported Flash game. Use a per-session namespace so
                // the movie URL always stays rooted in game content.
                let prefix = "__yume_runtime_\(UUID().uuidString.lowercased())"
                runtimeRoutePrefix = prefix
                additionalRoots = [prefix: runtimeRoot]
            }
            do {
                let server = try LocalGameHTTPServer(
                    rootURL: location.rootURL,
                    additionalRoots: additionalRoots,
                    onError: { [weak self] message, path in
                        DispatchQueue.main.async {
                            self?.handleResourceError(message, path: path)
                        }
                    },
                    onAccess: { [weak self] path, mimeType, bytes, requestCount, totalBytes in
                        DispatchQueue.main.async {
                            self?.handleResourceAccess(
                                path: path,
                                mimeType: mimeType,
                                bytes: bytes,
                                requestCount: requestCount,
                                totalBytes: totalBytes
                            )
                        }
                    }
                )
                localServer = server
                server.start { [weak self] result in
                    Task { @MainActor in
                        guard let self, let webView = self.hostedWebView else { return }
                        switch result {
                        case let .success(baseURL):
                            self.allowedOrigin = Self.origin(of: baseURL)
                            self.onLog(
                                "web.loopback-ready",
                                false,
                                self.metadata(["origin": self.allowedOrigin ?? "unknown"])
                            )
                            self.installNetworkBlockerAndLoad(
                                webView,
                                location: location,
                                mode: mode,
                                baseURL: baseURL
                            )
                        case let .failure(error):
                            self.onLog(
                                "web.loopback-failed",
                                true,
                                self.metadata(["error": String(describing: error)])
                            )
                            self.loadFailed = true
                        }
                    }
                }
            } catch {
                onLog(
                    "web.loopback-create-failed",
                    true,
                    metadata(["error": String(describing: error)])
                )
                loadFailed = true
            }
        }

        func stopLocalServer() {
            onLog("web.stopped", false, baseMetadata)
            localServer?.stop()
            localServer = nil
            allowedOrigin = nil
            runtimeRoutePrefix = nil
            hostedWebView = nil
        }

        private func installNetworkBlockerAndLoad(
            _ webView: WKWebView,
            location: GameContentLocation,
            mode: WebPlayerMode,
            baseURL: URL
        ) {
            guard let port = baseURL.port else {
                onLog("web.loopback-port-missing", true, baseMetadata)
                loadFailed = true
                return
            }
            let rules = """
            [
              {"trigger":{"url-filter":"^(https?|wss?|file)://"},"action":{"type":"block"}},
              {"trigger":{"url-filter":"^http://127[.]0[.]0[.]1:\(port)/"},"action":{"type":"ignore-previous-rules"}}
            ]
            """
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "yume-loopback-network-policy-v2-\(port)",
                encodedContentRuleList: rules
            ) { [weak self, weak webView] ruleList, error in
                Task { @MainActor in
                    guard let self, let webView, self.hostedWebView === webView,
                          self.localServer != nil, error == nil, let ruleList else {
                        if let self {
                            self.onLog(
                                "web.network-policy-failed",
                                true,
                                self.metadata(["error": String(describing: error)])
                            )
                        }
                        self?.loadFailed = true
                        return
                    }
                    webView.configuration.userContentController.add(ruleList)
                    self.onLog("web.network-policy-ready", false, self.baseMetadata)
                    self.load(
                        webView,
                        location: location,
                        mode: mode,
                        baseURL: baseURL
                    )
                }
            }
        }

        private func load(
            _ webView: WKWebView,
            location: GameContentLocation,
            mode: WebPlayerMode,
            baseURL: URL
        ) {
            let url: URL?
            switch mode {
            case .game:
                guard let entryPoint = location.webEntryPoint else {
                    onLog("web.entry-point-missing", true, baseMetadata)
                    loadFailed = true
                    return
                }
                url = Self.url(for: entryPoint, relativeTo: baseURL)
            case let .ruffle(_, movie):
                guard let runtimeRoutePrefix else {
                    onLog("web.runtime-route-missing", true, baseMetadata)
                    loadFailed = true
                    return
                }
                let movieURL = Self.url(
                    for: movie,
                    relativeTo: baseURL
                ).absoluteString
                var components = URLComponents(
                    url: URL(
                        string: "\(runtimeRoutePrefix)/index.html",
                        relativeTo: baseURL
                    )!.absoluteURL,
                    resolvingAgainstBaseURL: false
                )
                components?.queryItems = [URLQueryItem(name: "movie", value: movieURL)]
                url = components?.url
            }
            guard let url else {
                onLog("web.url-construction-failed", true, baseMetadata)
                loadFailed = true
                return
            }
            onLog("web.navigation-requested", false, metadata(["url": url.absoluteString]))
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let allowed = url.absoluteString == "about:blank"
                || Self.origin(of: url) == allowedOrigin
            if !allowed {
                onLog("web.navigation-blocked", false, metadata(["url": url.absoluteString]))
            }
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            navigationStartedAt = CACurrentMediaTime()
            onLog("web.navigation-started", false, metadata(["url": webView.url?.absoluteString ?? "unknown"]))
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            onLog(
                "web.navigation-committed",
                false,
                metadata([
                    "url": webView.url?.absoluteString ?? "unknown",
                    "progress": String(format: "%.3f", webView.estimatedProgress)
                ])
            )
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let elapsed = navigationStartedAt.map { CACurrentMediaTime() - $0 }
            onLog("web.navigation-finished", false, metadata([
                "url": webView.url?.absoluteString ?? "unknown",
                "title": webView.title ?? "",
                "elapsedMs": elapsed.map { String(format: "%.2f", $0 * 1_000) } ?? "unknown",
                "progress": String(format: "%.3f", webView.estimatedProgress)
            ]))
            webView.evaluateJavaScript("""
                ({readyState: document.readyState,
                  bodyChildren: document.body?.children.length ?? -1,
                  canvasCount: document.querySelectorAll('canvas').length,
                  canvasSizes: Array.from(document.querySelectorAll('canvas')).slice(0, 8).map(c => `${c.width}x${c.height}`),
                  imageCount: document.images.length,
                  completeImages: Array.from(document.images).filter(i => i.complete).length,
                  scripts: document.scripts.length,
                  href: location.href})
                """) { [weak self] value, error in
                guard let self else { return }
                self.onLog(
                    "web.document-snapshot",
                    error != nil,
                    self.metadata(["snapshot": String(describing: value ?? "none"),
                                   "error": error.map { String(describing: $0) } ?? "none"])
                )
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            onLog("web.navigation-failed", true, metadata(["error": String(describing: error)]))
            loadFailed = true
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            onLog("web.provisional-navigation-failed", true, metadata(["error": String(describing: error)]))
            loadFailed = true
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onLog("web.content-process-terminated", true, baseMetadata)
            loadFailed = true
        }

        private func metadata(
            _ additional: [String: String] = [:],
            message: String? = nil
        ) -> [String: String] {
            var result = baseMetadata
            additional.forEach { result[$0.key] = String($0.value.prefix(4_000)) }
            if let message { result["detail"] = String(message.prefix(4_000)) }
            return result
        }

        private static func origin(of url: URL) -> String? {
            guard let scheme = url.scheme?.lowercased(),
                  let host = url.host?.lowercased(),
                  let port = url.port
            else { return nil }
            return "\(scheme)://\(host):\(port)"
        }

        private static func url(
            for relativePath: StorageRelativePath,
            relativeTo baseURL: URL
        ) -> URL {
            relativePath.rawValue
                .split(separator: "/", omittingEmptySubsequences: false)
                .reduce(baseURL) { partial, component in
                    partial.appendingPathComponent(String(component), isDirectory: false)
                }
        }
    }
}

private enum WebPlayerMode: Equatable {
    case game
    case ruffle(runtimeRoot: URL, movie: StorageRelativePath)
}

private extension WebPlayerMode {
    var runtimeIdentifier: String {
        switch self {
        case .game: "restricted-web"
        case .ruffle: "ruffle-web"
        }
    }
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
    let onLog: (_ message: String, _ isError: Bool, _ metadata: [String: String]) -> Void
    @Binding var loadFailed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            loadFailed: $loadFailed,
            onLog: onLog,
            game: playSession.content.game,
            runtimeIdentifier: runtimeIdentifier
        )
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
            onLog("native.create-requested", false, ["runtime": runtimeIdentifier])
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
            onLog(
                "native.create-failed",
                true,
                [
                    "error": String(describing: error),
                    "requiresRestart": (error as? NativeRuntimeHostError) == .processRequiresRestart ? "true" : "false",
                    "runtime": runtimeIdentifier,
                    "gameID": playSession.content.game.id.rawValue.uuidString,
                    "engine": playSession.content.game.engine.id.rawValue
                ]
            )
            loadFailed = true
            onLog("native.released", false, ["reason": "creation-failed"])
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
        context.coordinator.sendButton(action, pressed: inputCommand.pressed)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.stop()
        view.subviews.forEach { $0.removeFromSuperview() }
    }

    @MainActor
    final class Coordinator {
        @Binding private var loadFailed: Bool
        private let onLog: (_ message: String, _ isError: Bool, _ metadata: [String: String]) -> Void
        private var runtime: NativeRuntimeSession?
        private var eventTask: Task<Void, Never>?
        private var logTask: Task<Void, Never>?
        private var startTask: Task<Void, Never>?
        private var firstFrameWatchdog: Task<Void, Never>?
        private var isSuspended = false
        private var receivedFirstFrame = false
        private let baseMetadata: [String: String]
        var lastInputCommandID: UUID?

        init(
            loadFailed: Binding<Bool>,
            onLog: @escaping (_ message: String, _ isError: Bool, _ metadata: [String: String]) -> Void,
            game: ImportedGame,
            runtimeIdentifier: String
        ) {
            _loadFailed = loadFailed
            self.onLog = onLog
            self.baseMetadata = [
                "gameID": game.id.rawValue.uuidString,
                "engine": game.engine.id.rawValue,
                "runtime": runtimeIdentifier
            ]
        }

        func install(runtime: NativeRuntimeSession, in container: UIView) {
            self.runtime = runtime
            guard let gameView = runtime.nativeView() else {
                onLog("native.view-unavailable", true, baseMetadata)
                loadFailed = true
                Task {
                    await runtime.stop()
                    onLog("native.released", false, baseMetadata)
                }
                self.runtime = nil
                return
            }
            gameView.removeFromSuperview()
            gameView.frame = container.bounds
            gameView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.insertSubview(gameView, at: 0)
            onLog("native.view-attached", false, baseMetadata)

            eventTask = Task { @MainActor [weak self] in
                for await event in runtime.events {
                    guard let self else { return }
                    switch event {
                    case .started:
                        onLog("native.started", false, baseMetadata)
                    case .firstFrame:
                        receivedFirstFrame = true
                        firstFrameWatchdog?.cancel()
                        onLog("native.first-frame", false, baseMetadata)
                    case .paused:
                        onLog("native.paused", false, baseMetadata)
                    case .resumed:
                        onLog("native.resumed", false, baseMetadata)
                    case .stopped:
                        onLog("native.stopped", false, baseMetadata)
                        if self.runtime != nil {
                            if !receivedFirstFrame {
                                onLog("native.exited-before-first-frame", true, baseMetadata)
                                loadFailed = true
                            }
                            stopRuntimeAfterFailure()
                        }
                    case let .warning(code):
                        onLog("native.warning", code == "runtime.stop-timeout", metadata(["code": code]))
                    case let .failed(code):
                        onLog("native.failed", true, metadata(["code": code]))
                        loadFailed = true
                        stopRuntimeAfterFailure()
                    }
                }
            }
            logTask = Task { @MainActor [weak self] in
                for await record in runtime.logs {
                    guard let self else { return }
                    onLog(
                        "native.engine-log",
                        record.level == .error,
                        metadata([
                            "level": record.level.rawValue,
                            "source": record.subsystem,
                            "detail": record.message
                        ])
                    )
                }
            }
            startTask = Task { @MainActor [weak self] in
                do {
                    guard !Task.isCancelled else { return }
                    self?.onLog("native.start-requested", false, self?.baseMetadata ?? [:])
                    try await runtime.start()
                    if self?.isSuspended == true { await runtime.pause() }
                } catch {
                    self?.onLog(
                        "native.start-threw",
                        true,
                        self?.metadata(["error": String(describing: error)]) ?? [:]
                    )
                    self?.loadFailed = true
                    self?.stopRuntimeAfterFailure()
                    return
                }
                guard let self, self.runtime != nil else { return }
                firstFrameWatchdog = Task { @MainActor [weak self] in
                    // Background time is not startup time: a locked phone
                    // must not fail a game that correctly suspended rendering.
                    var activeSeconds = 0
                    while activeSeconds < 60 {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        guard let self, !receivedFirstFrame else { return }
                        if !isSuspended { activeSeconds += 1 }
                    }
                    guard let self, !Task.isCancelled, !receivedFirstFrame else { return }
                    onLog("native.first-frame-timeout", true, baseMetadata)
                    loadFailed = true
                    stopRuntimeAfterFailure()
                }
            }
        }

        func setSuspended(_ suspended: Bool) {
            guard suspended != isSuspended, let runtime else { return }
            isSuspended = suspended
            if suspended { releaseButtons() }
            Task {
                if suspended { await runtime.pause() } else { await runtime.resume() }
            }
        }

        private var heldActions: Set<EngineInputAction> = []

        func sendButton(_ action: EngineInputAction, pressed: Bool) {
            guard let runtime, !isSuspended || !pressed else { return }
            if pressed { heldActions.insert(action) } else { heldActions.remove(action) }
            Task { await runtime.send(.button(action: action, pressed: pressed)) }
        }

        private func releaseButtons() {
            guard let runtime else { return }
            let actions = heldActions
            heldActions.removeAll()
            Task {
                for action in actions { await runtime.send(.button(action: action, pressed: false)) }
            }
        }

        func stop() {
            releaseButtons()
            stopRuntimeAfterFailure()
        }

        private func stopRuntimeAfterFailure() {
            firstFrameWatchdog?.cancel()
            firstFrameWatchdog = nil
            startTask?.cancel()
            startTask = nil
            guard let runtime else { return }
            self.runtime = nil
            let events = eventTask
            let logs = logTask
            // Drain the streams through provider stop/destroy. Cancelling
            // here used to discard stop-timeout and cleanup diagnostics.
            Task {
                onLog("native.stop-requested", false, baseMetadata)
                await runtime.stop()
                await events?.value
                await logs?.value
                onLog("native.released", false, baseMetadata)
                eventTask = nil
                logTask = nil
            }
        }

        private func metadata(_ additional: [String: String]) -> [String: String] {
            var result = baseMetadata
            additional.forEach { result[$0.key] = String($0.value.prefix(4_000)) }
            return result
        }
    }
}

private struct WebInputCommand: Equatable {
    let id = UUID()
    let keyCode: Int
    let pressed: Bool

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

private final class WebDiagnosticsBridge: NSObject, WKScriptMessageHandler {
    static let messageName = "yumeDiagnostics"

    private let onMessage: (_ kind: String, _ message: String, _ details: [String: String]) -> Void

    init(onMessage: @escaping (_ kind: String, _ message: String, _ details: [String: String]) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageName,
              let body = message.body as? [String: Any]
        else { return }
        let kind = String(describing: body["kind"] ?? "message")
        let detail = String(describing: body["message"] ?? "")
        var metadata: [String: String] = [:]
        for key in [
            "source", "line", "column", "stack", "readyState",
            "bodyChildren", "canvasCount", "imageCount", "userAgent",
            "viewport", "screen", "sequence", "scene", "sceneReady", "firstDraw"
        ] {
            if let value = body[key] {
                metadata[key] = String(String(describing: value).prefix(4_000))
            }
        }
        onMessage(kind, detail, metadata)
    }

    func bootstrapScript(engineID: String) -> WKUserScript {
        let engine = (try? JSONEncoder().encode(engineID)) ?? Data("\"unknown\"".utf8)
        let source = Bundle.main.url(forResource: "WebRuntimeSupport", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "console.error('Yume WebRuntimeSupport.js missing');"
        return WKUserScript(
            source: "window.__yumeEngineID = \(String(decoding: engine, as: UTF8.self));\n" + source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

}

private struct GameVirtualControls: View {
    let send: (Int, Bool) -> Void

    var body: some View {
        VStack {
            Spacer().allowsHitTesting(false)
            HStack(alignment: .bottom) {
                directionalPad
                Spacer().allowsHitTesting(false)
                HStack(spacing: 14) {
                    controlButton("xmark", keyCode: 88, accessibilityKey: "controls.cancel")
                    controlButton("checkmark", keyCode: 90, accessibilityKey: "controls.confirm")
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .allowsHitTesting(true)
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
        GameControlButton(symbol: symbol, accessibilityKey: accessibilityKey) { pressed in
            send(keyCode, pressed)
        }
    }
}

private struct GameControlButton: View {
    let symbol: String
    let accessibilityKey: LocalizedStringKey
    let send: (Bool) -> Void
    @State private var held = false

    var body: some View {
        Image(systemName: symbol)
            .font(.title3.bold())
            .frame(width: 50, height: 50)
            .background(.ultraThinMaterial, in: Circle())
            .foregroundStyle(.primary)
            .contentShape(Circle())
            .opacity(held ? 0.6 : 1)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in setHeld(true) }
                .onEnded { _ in setHeld(false) })
            .onDisappear { setHeld(false) }
            .accessibilityLabel(accessibilityKey)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                Task { @MainActor in
                    setHeld(true)
                    try? await Task.sleep(for: .milliseconds(80))
                    setHeld(false)
                }
            }
    }

    private func setHeld(_ value: Bool) {
        guard held != value else { return }
        held = value
        send(value)
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

    @MainActor
    func bootstrapScript() -> WKUserScript {
        let encodedValues = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data("{}".utf8)
        let json = String(decoding: encodedValues, as: UTF8.self)
        let source = """
        (() => {
          const values = Object.assign(Object.create(null), \(json));
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
          const proxy = new Proxy(storage, {
            get(target, key) {
              if (key in target || typeof key === "symbol") return Reflect.get(target, key);
              return target.getItem(key) ?? undefined;
            },
            set(target, key, value) { target.setItem(key, value); return true; },
            deleteProperty(target, key) { target.removeItem(key); return true; },
            ownKeys() { return keys(); },
            has(target, key) { return key in target || Object.prototype.hasOwnProperty.call(values, key); },
            getOwnPropertyDescriptor(target, key) {
              if (Object.prototype.hasOwnProperty.call(values, key))
                return {value: values[key], enumerable: true, configurable: true, writable: true};
            }
          });
          Object.defineProperty(window, "localStorage", {value: proxy, configurable: false});
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
