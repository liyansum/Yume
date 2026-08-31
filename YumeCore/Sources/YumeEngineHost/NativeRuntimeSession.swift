import CYumeRuntimeBridge
import Foundation
#if canImport(UIKit)
import UIKit
#endif

public enum NativeRuntimeHostError: Error, Sendable, Equatable {
    case unavailable(String)
    case creationFailed(runtimeIdentifier: String, code: Int32)
    case operationFailed(operation: String, code: Int32)
}

public struct NativeRuntimeLogRecord: Sendable, Equatable {
    public let level: AppRuntimeLogLevel
    public let subsystem: String
    public let message: String

    public init(level: AppRuntimeLogLevel, subsystem: String, message: String) {
        self.level = level
        self.subsystem = subsystem
        self.message = message
    }
}

public enum AppRuntimeLogLevel: String, Sendable, Equatable {
    case information
    case warning
    case error
}

/// Swift owner for the narrow C ABI shared by all statically linked native
/// runtimes. Providers keep their engine headers and global state behind the
/// ABI, while the App receives only lifecycle events and an opaque UIView.
public final class NativeRuntimeSession: EnginePlayer, @unchecked Sendable {
    public let events: AsyncStream<EngineEvent>
    public let logs: AsyncStream<NativeRuntimeLogRecord>

    private let runtimeIdentifier: String
    private let sink: NativeRuntimeEventSink
    private let callbackContext: UnsafeMutableRawPointer
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var destroyed = false

    public static func isAvailable(runtimeIdentifier: String) -> Bool {
        runtimeIdentifier.withCString { yume_runtime_is_available($0) != 0 }
    }

    public init(
        runtimeIdentifier: String,
        game: PreparedGame,
        context: EngineContext
    ) throws {
        self.runtimeIdentifier = runtimeIdentifier
        let pair = AsyncStream<EngineEvent>.makeStream()
        let logPair = AsyncStream<NativeRuntimeLogRecord>.makeStream()
        events = pair.stream
        logs = logPair.stream
        sink = NativeRuntimeEventSink(
            continuation: pair.continuation,
            logContinuation: logPair.continuation
        )
        callbackContext = Unmanaged.passRetained(sink).toOpaque()

        guard Self.isAvailable(runtimeIdentifier: runtimeIdentifier) else {
            Unmanaged<NativeRuntimeEventSink>.fromOpaque(callbackContext).release()
            throw NativeRuntimeHostError.unavailable(runtimeIdentifier)
        }

        var creationError: Int32 = 0
        handle = Self.withConfiguration(
            game: game,
            context: context,
            logCallbackContext: callbackContext
        ) { configuration in
            runtimeIdentifier.withCString { identifier in
                yume_runtime_session_create(
                    identifier,
                    &configuration,
                    Self.receiveEvent,
                    callbackContext,
                    &creationError
                )
            }
        }
        guard handle != nil else {
            Unmanaged<NativeRuntimeEventSink>.fromOpaque(callbackContext).release()
            throw NativeRuntimeHostError.creationFailed(
                runtimeIdentifier: runtimeIdentifier,
                code: creationError
            )
        }
    }

    deinit {
        destroy()
    }

    public func start() async throws {
        try checked("start") { yume_runtime_session_start($0) }
    }

    public func pause() async {
        _ = withHandle { yume_runtime_session_pause($0) }
    }

    public func resume() async {
        _ = withHandle { yume_runtime_session_resume($0) }
    }

    public func send(_ input: EngineInputEvent) async {
        switch input {
        case let .button(action, pressed):
            guard let nativeAction = action.nativeValue else { return }
            _ = withHandle {
                yume_runtime_session_send_button($0, nativeAction, pressed ? 1 : 0)
            }
        case let .pointer(x, y, pressed):
            _ = withHandle {
                yume_runtime_session_send_pointer($0, x, y, pressed ? 1 : 0)
            }
        case let .text(text):
            _ = withHandle { handle in
                text.withCString { yume_runtime_session_send_text(handle, $0) }
            }
        }
    }

    public func stop() async {
        _ = withHandle { yume_runtime_session_stop($0) }
    }

#if canImport(UIKit)
    @MainActor
    public func nativeView() -> UIView? {
        guard let pointer = withHandle({ yume_runtime_session_native_view($0) }).flatMap({ $0 }) else {
            return nil
        }
        return Unmanaged<UIView>.fromOpaque(pointer).takeUnretainedValue()
    }
#endif

    private func checked(
        _ operation: String,
        _ body: (OpaquePointer) -> Int32
    ) throws {
        let result = withHandle(body) ?? -1
        guard result == 0 else {
            throw NativeRuntimeHostError.operationFailed(operation: operation, code: result)
        }
    }

    private func withHandle<Result>(_ body: (OpaquePointer) -> Result) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard !destroyed, let handle else { return nil }
        return body(handle)
    }

    private func destroy() {
        lock.lock()
        guard !destroyed else {
            lock.unlock()
            return
        }
        destroyed = true
        var ownedHandle = handle
        handle = nil
        lock.unlock()

        yume_runtime_session_destroy(&ownedHandle)
        sink.finish()
        Unmanaged<NativeRuntimeEventSink>.fromOpaque(callbackContext).release()
    }

    private static let receiveEvent: @convention(c) (
        YumeRuntimeEventKind,
        UnsafePointer<CChar>?,
        UnsafeMutableRawPointer?
    ) -> Void = { kind, code, context in
        guard let context else { return }
        let sink = Unmanaged<NativeRuntimeEventSink>.fromOpaque(context).takeUnretainedValue()
        let value = code.map { String(cString: $0) } ?? "runtime.unknown"
        switch kind {
        case YUME_RUNTIME_EVENT_STARTED: sink.yield(.started)
        case YUME_RUNTIME_EVENT_FIRST_FRAME: sink.yield(.firstFrame)
        case YUME_RUNTIME_EVENT_PAUSED: sink.yield(.paused)
        case YUME_RUNTIME_EVENT_RESUMED: sink.yield(.resumed)
        case YUME_RUNTIME_EVENT_STOPPED: sink.yield(.stopped)
        case YUME_RUNTIME_EVENT_WARNING: sink.yield(.warning(code: value))
        case YUME_RUNTIME_EVENT_FAILED: sink.yield(.failed(code: value))
        default: sink.yield(.warning(code: "runtime.invalid-event"))
        }
    }

    private static let receiveLog: @convention(c) (
        YumeRuntimeLogLevel,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafeMutableRawPointer?
    ) -> Void = { level, subsystem, message, context in
        guard let context else { return }
        let sink = Unmanaged<NativeRuntimeEventSink>.fromOpaque(context).takeUnretainedValue()
        let mappedLevel: AppRuntimeLogLevel = switch level {
        case YUME_RUNTIME_LOG_WARNING: .warning
        case YUME_RUNTIME_LOG_ERROR: .error
        default: .information
        }
        sink.yieldLog(NativeRuntimeLogRecord(
            level: mappedLevel,
            subsystem: subsystem.map(String.init(cString:)) ?? "native",
            message: message.map(String.init(cString:)) ?? "<empty>"
        ))
    }

    private static func withConfiguration<Result>(
        game: PreparedGame,
        context: EngineContext,
        logCallbackContext: UnsafeMutableRawPointer,
        _ body: (inout YumeRuntimeConfiguration) -> Result
    ) -> Result {
        game.contentRootURL.path.withCString { contentRoot in
            game.saveRootURL.path.withCString { saveRoot in
                game.derivedRootURL.path.withCString { derivedRoot in
                    game.logRootURL.path.withCString { logRoot in
                        context.localeIdentifier.withCString { locale in
                            withCStringArray(game.rtpMountRoots.map(\.path)) { rtpRoots in
                                rtpRoots.withUnsafeBufferPointer { buffer in
                                    var configuration = YumeRuntimeConfiguration(
                                        abi_version: YUME_RUNTIME_ABI_VERSION,
                                        content_root: contentRoot,
                                        save_root: saveRoot,
                                        derived_root: derivedRoot,
                                        log_root: logRoot,
                                        locale_identifier: locale,
                                        rtp_roots: buffer.baseAddress,
                                        rtp_root_count: buffer.count,
                                        networking_allowed: context.networkingAllowed ? 1 : 0,
                                        log_callback: Self.receiveLog,
                                        log_callback_context: logCallbackContext
                                    )
                                    return body(&configuration)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        _ body: ([UnsafePointer<CChar>?]) -> Result
    ) -> Result {
        func descend(
            _ index: Int,
            _ pointers: [UnsafePointer<CChar>?]
        ) -> Result {
            guard index < strings.count else { return body(pointers) }
            return strings[index].withCString { pointer in
                descend(index + 1, pointers + [pointer])
            }
        }
        return descend(0, [])
    }
}

private final class NativeRuntimeEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<EngineEvent>.Continuation?
    private var logContinuation: AsyncStream<NativeRuntimeLogRecord>.Continuation?

    init(
        continuation: AsyncStream<EngineEvent>.Continuation,
        logContinuation: AsyncStream<NativeRuntimeLogRecord>.Continuation
    ) {
        self.continuation = continuation
        self.logContinuation = logContinuation
    }

    func yield(_ event: EngineEvent) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(event)
    }

    func finish() {
        lock.lock()
        let continuation = continuation
        let logContinuation = logContinuation
        self.continuation = nil
        self.logContinuation = nil
        lock.unlock()
        continuation?.finish()
        logContinuation?.finish()
    }

    func yieldLog(_ record: NativeRuntimeLogRecord) {
        lock.lock()
        let continuation = logContinuation
        lock.unlock()
        continuation?.yield(record)
    }
}

private extension EngineInputAction {
    var nativeValue: YumeRuntimeInputAction? {
        switch self {
        case .up: YUME_RUNTIME_INPUT_UP
        case .down: YUME_RUNTIME_INPUT_DOWN
        case .left: YUME_RUNTIME_INPUT_LEFT
        case .right: YUME_RUNTIME_INPUT_RIGHT
        case .confirm: YUME_RUNTIME_INPUT_CONFIRM
        case .cancel: YUME_RUNTIME_INPUT_CANCEL
        case .menu: YUME_RUNTIME_INPUT_MENU
        case .pageUp: YUME_RUNTIME_INPUT_PAGE_UP
        case .pageDown: YUME_RUNTIME_INPUT_PAGE_DOWN
        case .pointerPrimary: YUME_RUNTIME_INPUT_POINTER_PRIMARY
        case .fastForward: YUME_RUNTIME_INPUT_FAST_FORWARD
        case .autoMode: YUME_RUNTIME_INPUT_AUTO_MODE
        case .history: YUME_RUNTIME_INPUT_HISTORY
        }
    }
}
