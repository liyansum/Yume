#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <new>
#include <signal.h>
#include <string>
#include <unistd.h>
#include <vector>

#include "../../YumeCore/Sources/CYumeRuntimeBridge/include/CYumeRuntimeBridge.h"
#include "../../ThirdParty/AetherKiri/Source/bridge/engine_api/include/engine_api.h"
#include "../../ThirdParty/AetherKiri/Source/bridge/engine_api/include/engine_options.h"
#include "../../ThirdParty/AetherKiri/Source/bridge/onscripter_runtime/include/onscripter_runtime.h"

extern "C" void SDL_SetMainReady(void);

@interface YumeAetherEngineWork : NSObject
@property (nonatomic, copy) void (^block)(void);
- (void)invoke;
@end
@implementation YumeAetherEngineWork
- (void)invoke {
    if (self.block != nil) self.block();
}
@end

enum class AetherRuntimeKind { Kirikiri, ONScripter };

struct AetherSession;

static volatile sig_atomic_t gAetherCrashLogFD = -1;
static std::mutex gAetherCrashHandlerMutex;

static void AetherCrashSignalHandler(int signalNumber) {
    const int fd = static_cast<int>(gAetherCrashLogFD);
    if (fd < 0) return;
    static const char prefix[] = "native.crash signal=";
    (void)write(fd, prefix, sizeof(prefix) - 1);
    char number[16] = {};
    unsigned int value = signalNumber < 0
        ? static_cast<unsigned int>(-signalNumber)
        : static_cast<unsigned int>(signalNumber);
    int index = static_cast<int>(sizeof(number)) - 2;
    do {
        number[index--] = static_cast<char>('0' + value % 10u);
        value /= 10u;
    } while (value > 0 && index >= 0);
    if (signalNumber < 0 && index >= 0) number[index--] = '-';
    (void)write(fd, number + index + 1, sizeof(number) - index - 2);
    (void)write(fd, "\n", 1);
    (void)fsync(fd);
    // SA_RESETHAND restores the default disposition before entry. Returning
    // preserves Apple's normal crash report while retaining this breadcrumb.
}

static void ReleaseFramePixels(void *, const void *data, size_t) {
    free(const_cast<void *>(data));
}

static void Emit(AetherSession *session, YumeRuntimeEventKind kind,
                 const char *code);

@interface YumeAetherRuntimeView : UIView
- (instancetype)initWithSession:(AetherSession *)session;
- (int32_t)startEngine;
- (int32_t)pauseEngine;
- (int32_t)resumeEngine;
- (int32_t)sendKey:(int32_t)key pressed:(BOOL)pressed;
- (int32_t)sendText:(const char *)text;
- (int32_t)sendPointerX:(double)x y:(double)y pressed:(BOOL)pressed;
- (int32_t)stopEngine;
- (void)drainEngineLogs;
- (void)detachSession;
@end

struct AetherSession {
    AetherRuntimeKind kind = AetherRuntimeKind::Kirikiri;
    std::string content_root;
    std::string save_root;
    std::string derived_root;
    std::string log_root;
    std::string locale_identifier;
    YumeRuntimeEventCallback callback = nullptr;
    void *callback_context = nullptr;
    __strong YumeAetherRuntimeView *view = nil;
    std::atomic<bool> stopped{false};
    std::mutex log_mutex;
};

static void AppendHostLog(AetherSession *session, const std::string &message) {
    if (session == nullptr || session->log_root.empty()) return;
    std::lock_guard<std::mutex> guard(session->log_mutex);
    @autoreleasepool {
        NSString *root = [NSString stringWithUTF8String:session->log_root.c_str()];
        if (root.length == 0) return;
        NSError *directoryError = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:root
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&directoryError];
        if (directoryError != nil) return;
        NSString *path = [root stringByAppendingPathComponent:@"aetherkiri-host.log"];
        FILE *stream = fopen(path.fileSystemRepresentation, "ab");
        if (stream == nullptr) return;
        const double timestamp = NSDate.date.timeIntervalSince1970;
        fprintf(stream, "%.3f [thread=%s] %s\n", timestamp,
                NSThread.isMainThread ? "main" : "worker", message.c_str());
        fflush(stream);
        fsync(fileno(stream));
        fclose(stream);
    }
}

static void AppendEngineError(AetherSession *session, engine_handle_t engine,
                              const char *stage) {
    const char *error = engine_get_last_error(engine);
    std::string line(stage != nullptr ? stage : "engine.error");
    line += " result=";
    line += error != nullptr && error[0] != '\0' ? error : "<none>";
    AppendHostLog(session, line);
}

static void InstallAetherCrashBreadcrumb(AetherSession *session) {
    if (session == nullptr || session->log_root.empty()) return;
    AppendHostLog(session, "crash-handler.install.begin");
    @autoreleasepool {
        NSString *root = [NSString stringWithUTF8String:session->log_root.c_str()];
        if (root.length == 0) return;
        [[NSFileManager defaultManager] createDirectoryAtPath:root
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *path = [root stringByAppendingPathComponent:@"aetherkiri-crash.log"];
        const int fd = open(path.fileSystemRepresentation,
                            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
        if (fd < 0) {
            AppendHostLog(session, "crash-handler.open.failed");
            return;
        }
        std::lock_guard<std::mutex> guard(gAetherCrashHandlerMutex);
        const int previous = static_cast<int>(gAetherCrashLogFD);
        gAetherCrashLogFD = fd;
        if (previous >= 0) close(previous);
        const int signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP};
        for (const int signalNumber : signals) {
            struct sigaction action {};
            action.sa_handler = AetherCrashSignalHandler;
            sigemptyset(&action.sa_mask);
            action.sa_flags = SA_RESETHAND;
            (void)sigaction(signalNumber, &action, nullptr);
        }
    }
    AppendHostLog(session, "crash-handler.install.end");
}

static void Emit(AetherSession *session, YumeRuntimeEventKind kind,
                 const char *code) {
    if (session == nullptr || session->callback == nullptr) return;
    session->callback(kind, code != nullptr ? code : "", session->callback_context);
}

static int32_t OnMainSync(NSInteger (^operation)(void)) {
    if ([NSThread isMainThread]) return static_cast<int32_t>(operation());
    __block NSInteger result = -1;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = operation(); });
    return static_cast<int32_t>(result);
}

static NSString *BundledDefaultFontPath(void) {
    NSURL *root = [[NSBundle mainBundle] URLForResource:@"default"
                                         withExtension:@"otf"
                                          subdirectory:@"Runtimes/AetherKiri"];
    return root.path;
}

static int32_t KeyForAction(YumeRuntimeInputAction action) {
    switch (action) {
        case YUME_RUNTIME_INPUT_UP: return 0x26;
        case YUME_RUNTIME_INPUT_DOWN: return 0x28;
        case YUME_RUNTIME_INPUT_LEFT: return 0x25;
        case YUME_RUNTIME_INPUT_RIGHT: return 0x27;
        case YUME_RUNTIME_INPUT_CONFIRM: return 0x0d;
        case YUME_RUNTIME_INPUT_CANCEL: return 0x1b;
        case YUME_RUNTIME_INPUT_MENU: return 0x20;
        case YUME_RUNTIME_INPUT_PAGE_UP: return 0x21;
        case YUME_RUNTIME_INPUT_PAGE_DOWN: return 0x22;
        case YUME_RUNTIME_INPUT_FAST_FORWARD: return 0x11;
        case YUME_RUNTIME_INPUT_AUTO_MODE: return 0x41;
        case YUME_RUNTIME_INPUT_HISTORY: return 0x48;
        case YUME_RUNTIME_INPUT_POINTER_PRIMARY: return 0x01;
    }
    return 0;
}

static engine_result_t SetOption(engine_handle_t handle, const char *key,
                                 const char *value) {
    engine_option_t option{};
    option.key_utf8 = key;
    option.value_utf8 = value;
    return engine_set_option(handle, &option);
}

@implementation YumeAetherRuntimeView {
    AetherSession *_session;
    engine_handle_t _engine;
    CADisplayLink *_displayLink;
    NSThread *_engineThread;
    NSPort *_enginePort;
    dispatch_semaphore_t _engineReady;
    std::atomic<bool> _frameWorkPending;
    std::atomic<bool> _workerStopped;
    std::atomic<bool> _workerPaused;
    uint64_t _lastFrameSerial;
    CFTimeInterval _lastTimestamp;
    uint32_t _frameWidth;
    uint32_t _frameHeight;
    BOOL _startupResolved;
    BOOL _firstFrameSent;
    BOOL _paused;
    BOOL _stopped;
}

- (instancetype)initWithSession:(AetherSession *)session {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _session = session;
        _frameWorkPending.store(false);
        _workerStopped.store(false);
        _workerPaused.store(false);
        self.backgroundColor = UIColor.blackColor;
        self.multipleTouchEnabled = YES;
        self.userInteractionEnabled = YES;
        self.layer.contentsGravity = kCAGravityResizeAspect;
        self.layer.magnificationFilter = kCAFilterNearest;
        self.layer.minificationFilter = kCAFilterLinear;
    }
    return self;
}

- (void)engineThreadMain {
    @autoreleasepool {
        _enginePort = [NSMachPort port];
        NSRunLoop *loop = [NSRunLoop currentRunLoop];
        [loop addPort:_enginePort forMode:NSDefaultRunLoopMode];
        if (_engineReady != nullptr) dispatch_semaphore_signal(_engineReady);
        while (!_workerStopped.load()) {
            [loop runMode:NSDefaultRunLoopMode
               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        }
        [_displayLink invalidate];
        _displayLink = nil;
        if (_enginePort != nil) {
            [loop removePort:_enginePort forMode:NSDefaultRunLoopMode];
            _enginePort = nil;
        }
    }
}

- (void)startEngineThreadIfNeeded {
    if (_engineThread != nil) return;
    _engineReady = dispatch_semaphore_create(0);
    _engineThread = [[NSThread alloc] initWithTarget:self
                                            selector:@selector(engineThreadMain)
                                              object:nil];
    _engineThread.name = @"yume.aetherkiri.engine";
    _engineThread.qualityOfService = NSQualityOfServiceUserInteractive;
    [_engineThread start];
    dispatch_semaphore_wait(_engineReady, DISPATCH_TIME_FOREVER);
}

- (void)runOnEngineThread:(void (^)(void))work waitUntilDone:(BOOL)wait {
    (void)wait;
    // Kirikiri/TVP aborts (signal 6) if StartApplication runs off the main
    // thread. Create, open and tick stay on UIKit's thread.
    if (work != nil) work();
}

- (void)emitOnMain:(YumeRuntimeEventKind)kind code:(const char *)code {
    AetherSession *session = _session;
    const std::string copied = code != nullptr ? code : "";
    dispatch_async(dispatch_get_main_queue(), ^{
        Emit(session, kind, copied.c_str());
    });
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (CGRectIsEmpty(self.bounds) || _workerStopped.load()) return;
    const CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;
    const uint32_t width = static_cast<uint32_t>(
        std::max<CGFloat>(1, std::round(CGRectGetWidth(self.bounds) * scale)));
    const uint32_t height = static_cast<uint32_t>(
        std::max<CGFloat>(1, std::round(CGRectGetHeight(self.bounds) * scale)));
    [self runOnEngineThread:^{
        if (_engine != nullptr && !_workerStopped.load()) {
            (void)engine_set_surface_size(_engine, width, height);
        }
    } waitUntilDone:NO];
}

- (int32_t)startEngine {
    if (_stopped || _session == nullptr) return -1;
    [self layoutIfNeeded];
    AppendHostLog(_session, "start.on-main");
    const int32_t openResult = [self startEngineOnEngineThread];
    if (openResult != 0) return openResult;
    _displayLink = [CADisplayLink displayLinkWithTarget:self
                                               selector:@selector(displayLinkDidFire:)];
    if (@available(iOS 15.0, *)) {
        _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    } else {
        _displayLink.preferredFramesPerSecond = 60;
    }
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    return 0;
}

- (int32_t)startEngineOnEngineThread {
    if (_workerStopped.load() || _session == nullptr) return -1;
    if (_engine != nullptr) return 0;

    AppendHostLog(_session, "start.enter");
    [self emitOnMain:YUME_RUNTIME_EVENT_WARNING code:"aether.stage.start.enter"];
    SDL_SetMainReady();
    AppendHostLog(_session, "start.sdl-ready");
    if (_session->kind == AetherRuntimeKind::ONScripter) {
        aetherkiri::onscripter::RegisterRuntimeProvider();
    }

    engine_create_desc_t description{};
    description.struct_size = sizeof(description);
    description.api_version = ENGINE_API_VERSION;
    description.writable_path_utf8 = _session->save_root.c_str();
    description.cache_path_utf8 = _session->derived_root.c_str();
    engine_result_t result = engine_create(&description, &_engine);
    AppendHostLog(_session, result == ENGINE_RESULT_OK && _engine != nullptr
        ? "start.engine-created" : "start.engine-create-failed");
    if (result == ENGINE_RESULT_OK && _engine != nullptr) {
        [self emitOnMain:YUME_RUNTIME_EVENT_WARNING code:"aether.stage.engine-created"];
    }
    if (result != ENGINE_RESULT_OK || _engine == nullptr) {
        [self emitOnMain:YUME_RUNTIME_EVENT_FAILED code:"aether.create"];
        return static_cast<int32_t>(result != ENGINE_RESULT_OK ? result : -1);
    }

    const char *runtime = _session->kind == AetherRuntimeKind::ONScripter
                              ? "onscripter"
                              : "kirikiri";
    if ((!_session->log_root.empty() &&
         SetOption(_engine, ENGINE_OPTION_LOG_ROOT,
                   _session->log_root.c_str()) != ENGINE_RESULT_OK) ||
        SetOption(_engine, "runtime", runtime) != ENGINE_RESULT_OK ||
        SetOption(_engine, ENGINE_OPTION_RENDER_BACKEND,
                  ENGINE_RENDERER_DEBUG_CPU) != ENGINE_RESULT_OK ||
        SetOption(_engine, ENGINE_OPTION_FPS_LIMIT, "60") != ENGINE_RESULT_OK) {
        AppendEngineError(_session, _engine, "start.configure-failed");
        [self emitOnMain:YUME_RUNTIME_EVENT_FAILED code:"aether.configure"];
        engine_destroy(_engine);
        _engine = nullptr;
        return -2;
    }
    AppendHostLog(_session, "start.configured");
    [self emitOnMain:YUME_RUNTIME_EVENT_WARNING code:"aether.stage.configured"];
    NSString *fontPath = BundledDefaultFontPath();
    if (fontPath.length > 0) {
        (void)SetOption(_engine, "default_font", fontPath.fileSystemRepresentation);
    }
    if (!_session->save_root.empty()) {
        setenv("YUME_KIRIKIRI_SAVEDATA", _session->save_root.c_str(), 1);
        AppendHostLog(_session, "start.savedata=" + _session->save_root);
    }

    // Open synchronously on the engine-create thread. engine_open_game_async
    // spawns an internal worker, which races DisplayLink ticks and UIKit/TVP
    // thread-local state (LiveContainer crash after the datapath log).
    AppendHostLog(_session, "start.open-game.begin");
    [self emitOnMain:YUME_RUNTIME_EVENT_WARNING code:"aether.stage.open-game-begin"];
    result = engine_open_game(_engine, _session->content_root.c_str(), nullptr);
    if (result != ENGINE_RESULT_OK) {
        AppendEngineError(_session, _engine, "start.open-game.failed");
        [self drainEngineLogs];
        [self emitOnMain:YUME_RUNTIME_EVENT_FAILED code:"aether.open"];
        engine_destroy(_engine);
        _engine = nullptr;
        return static_cast<int32_t>(result);
    }
    AppendHostLog(_session, "start.open-game.ok");
    [self emitOnMain:YUME_RUNTIME_EVENT_WARNING code:"aether.stage.open-game-ok"];
    [self drainEngineLogs];
    [self emitOnMain:YUME_RUNTIME_EVENT_STARTED code:"aether.started"];
    return 0;
}

- (void)displayLinkDidFire:(CADisplayLink *)link {
    if (_stopped || _paused || _workerStopped.load() || _workerPaused.load()) return;
    [self processEngineFrameAtTimestamp:link.timestamp];
}

- (void)processEngineFrameAtTimestamp:(CFTimeInterval)timestamp {
    if (_engine == nullptr || _workerStopped.load() || _workerPaused.load()) return;

    if (!_startupResolved) {
        AppendHostLog(_session, "frame.startup-poll.begin");
        [self drainEngineLogs];
    }

    uint32_t startupState = ENGINE_STARTUP_STATE_IDLE;
    const engine_result_t startupResult =
        engine_get_startup_state(_engine, &startupState);
    if (startupResult != ENGINE_RESULT_OK) {
        AppendEngineError(_session, _engine, "frame.startup-state.failed");
        [self failWithCode:"aether.startup-state"];
        return;
    }
    if (startupState == ENGINE_STARTUP_STATE_FAILED) {
        [self drainEngineLogs];
        AppendEngineError(_session, _engine, "frame.startup.failed");
        [self failWithCode:"aether.startup"];
        return;
    }
    if (startupState != ENGINE_STARTUP_STATE_SUCCEEDED) return;
    if (!_startupResolved) AppendHostLog(_session, "frame.startup.succeeded");
    _startupResolved = YES;

    const CFTimeInterval delta = _lastTimestamp > 0
        ? std::clamp(timestamp - _lastTimestamp, 0.001, 0.100)
        : (1.0 / 60.0);
    _lastTimestamp = timestamp;
    const uint32_t deltaMilliseconds = static_cast<uint32_t>(
        std::max(1.0, std::round(delta * 1000.0)));
    if (_lastFrameSerial == 0) AppendHostLog(_session, "frame.first-tick.begin");
    const engine_result_t tickResult = engine_tick(_engine, deltaMilliseconds);
    if (_lastFrameSerial == 0) AppendHostLog(_session, "frame.first-tick.end");
    if (tickResult != ENGINE_RESULT_OK) {
        AppendEngineError(_session, _engine, "frame.tick.failed");
        [self failWithCode:"aether.tick"];
        return;
    }

    engine_frame_desc_t frame{};
    frame.struct_size = sizeof(frame);
    if (engine_get_frame_desc(_engine, &frame) != ENGINE_RESULT_OK ||
        frame.width == 0 || frame.height == 0 || frame.stride_bytes < frame.width * 4u ||
        frame.pixel_format != ENGINE_PIXEL_FORMAT_RGBA8888 ||
        frame.frame_serial == _lastFrameSerial) {
        return;
    }
    const size_t byteCount = static_cast<size_t>(frame.stride_bytes) * frame.height;
    void *pixels = malloc(byteCount);
    if (pixels == nullptr) {
        [self failWithCode:"aether.frame-memory"];
        return;
    }
    if (engine_read_frame_rgba(_engine, pixels, byteCount) != ENGINE_RESULT_OK) {
        free(pixels);
        return;
    }
    // DebugCpu stores scanlines with origin at the bottom. Flip so
    // UIKit shows the scene right-side up and tap mapping matches.
    {
        auto *bytes = static_cast<uint8_t *>(pixels);
        const size_t stride = frame.stride_bytes;
        std::vector<uint8_t> row(stride);
        for (uint32_t y = 0; y < frame.height / 2; ++y) {
            uint8_t *top = bytes + static_cast<size_t>(y) * stride;
            uint8_t *bottom = bytes + static_cast<size_t>(frame.height - 1 - y) * stride;
            memcpy(row.data(), top, stride);
            memcpy(top, bottom, stride);
            memcpy(bottom, row.data(), stride);
        }
    }

    CGDataProviderRef provider = CGDataProviderCreateWithData(
        nullptr, pixels, byteCount, ReleaseFramePixels);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = static_cast<CGBitmapInfo>(
        kCGBitmapByteOrder32Big | kCGImageAlphaLast);
    CGImageRef image = CGImageCreate(
        frame.width, frame.height, 8, 32, frame.stride_bytes, colorSpace,
        bitmapInfo, provider, nullptr, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    if (image == nullptr) return;

    _lastFrameSerial = frame.frame_serial;
    _frameWidth = frame.width;
    _frameHeight = frame.height;
    const BOOL isFirstFrame = !_firstFrameSent;
    _firstFrameSent = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_stopped) self.layer.contents = (__bridge id)image;
        CGImageRelease(image);
        if (isFirstFrame && !_stopped) {
            AppendHostLog(_session, "frame.first-frame");
            Emit(_session, YUME_RUNTIME_EVENT_FIRST_FRAME, "aether.first-frame");
        }
    });
}

- (void)drainEngineLogs {
    if (_engine == nullptr || _session == nullptr) return;
    char buffer[64 * 1024] = {};
    for (int attempt = 0; attempt < 4; ++attempt) {
        uint32_t bytesWritten = 0;
        const engine_result_t result = engine_drain_startup_logs(
            _engine, buffer, sizeof(buffer), &bytesWritten);
        if (result != ENGINE_RESULT_OK || bytesWritten == 0) return;
        AppendHostLog(_session, std::string(buffer, bytesWritten));
        if (bytesWritten + 1u < sizeof(buffer)) return;
    }
}

- (void)failWithCode:(const char *)code {
    const std::string copiedCode = code != nullptr ? code : "<none>";
    _displayLink.paused = YES;
    AppendHostLog(_session, std::string("runtime.failed code=") + copiedCode);
    [self emitOnMain:YUME_RUNTIME_EVENT_FAILED code:copiedCode.c_str()];
}

- (int32_t)pauseEngine {
    if (_stopped || _workerStopped.load()) return -1;
    if (_paused) return 0;
    __block engine_result_t result = ENGINE_RESULT_INVALID_STATE;
    [self runOnEngineThread:^{
        if (_engine != nullptr && !_workerStopped.load()) {
            result = engine_pause(_engine);
            if (result == ENGINE_RESULT_OK) _workerPaused.store(true);
        }
    } waitUntilDone:YES];
    if (result == ENGINE_RESULT_OK) {
        _paused = YES;
        _displayLink.paused = YES;
        [self emitOnMain:YUME_RUNTIME_EVENT_PAUSED code:"aether.paused"];
    }
    return static_cast<int32_t>(result);
}

- (int32_t)resumeEngine {
    if (_stopped || _workerStopped.load()) return -1;
    if (!_paused) return 0;
    __block engine_result_t result = ENGINE_RESULT_INVALID_STATE;
    [self runOnEngineThread:^{
        if (_engine != nullptr && !_workerStopped.load()) {
            result = engine_resume(_engine);
            if (result == ENGINE_RESULT_OK) {
                _workerPaused.store(false);
                _lastTimestamp = 0;
            }
        }
    } waitUntilDone:YES];
    if (result == ENGINE_RESULT_OK) {
        _paused = NO;
        _displayLink.paused = NO;
        [self emitOnMain:YUME_RUNTIME_EVENT_RESUMED code:"aether.resumed"];
    }
    return static_cast<int32_t>(result);
}

- (int32_t)sendKey:(int32_t)key pressed:(BOOL)pressed {
    if (_stopped || _workerStopped.load() || key == 0) return -1;
    [self runOnEngineThread:^{
        if (_engine == nullptr || !_startupResolved || _workerStopped.load()) return;
        engine_input_event_t event{};
        event.struct_size = sizeof(event);
        event.type = pressed ? ENGINE_INPUT_EVENT_KEY_DOWN : ENGINE_INPUT_EVENT_KEY_UP;
        event.timestamp_micros = static_cast<uint64_t>(CACurrentMediaTime() * 1000000.0);
        event.key_code = key;
        (void)engine_send_input(_engine, &event);
    } waitUntilDone:NO];
    return 0;
}

- (int32_t)sendText:(const char *)text {
    if (_stopped || _workerStopped.load() || text == nullptr) return -1;
    NSString *string = [NSString stringWithUTF8String:text];
    if (string == nil) return -1;
    [self runOnEngineThread:^{
        if (_engine == nullptr || !_startupResolved || _workerStopped.load()) return;
        [string enumerateSubstringsInRange:NSMakeRange(0, string.length)
                                   options:NSStringEnumerationByComposedCharacterSequences
                                usingBlock:^(NSString *substring, NSRange, NSRange, BOOL *stop) {
            NSData *utf32 = [substring dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
            if (utf32.length < sizeof(uint32_t)) return;
            uint32_t scalar = 0;
            [utf32 getBytes:&scalar length:sizeof(scalar)];
            engine_input_event_t event{};
            event.struct_size = sizeof(event);
            event.type = ENGINE_INPUT_EVENT_TEXT_INPUT;
            event.timestamp_micros = static_cast<uint64_t>(CACurrentMediaTime() * 1000000.0);
            event.unicode_codepoint = scalar;
            if (engine_send_input(_engine, &event) != ENGINE_RESULT_OK) *stop = YES;
        }];
    } waitUntilDone:NO];
    return 0;
}

- (CGPoint)enginePointForViewPoint:(CGPoint)point viewSize:(CGSize)viewSize {
    if (_frameWidth == 0 || _frameHeight == 0 ||
        viewSize.width <= 0 || viewSize.height <= 0) return point;
    const CGFloat scale = std::min(viewSize.width / _frameWidth,
                                   viewSize.height / _frameHeight);
    const CGFloat contentWidth = _frameWidth * scale;
    const CGFloat contentHeight = _frameHeight * scale;
    const CGFloat originX = (viewSize.width - contentWidth) * 0.5;
    const CGFloat originY = (viewSize.height - contentHeight) * 0.5;
    const CGFloat mappedX = std::clamp((point.x - originX) / scale, 0.0, (double)_frameWidth - 1.0);
    const CGFloat mappedY = std::clamp((point.y - originY) / scale, 0.0, (double)_frameHeight - 1.0);
    return CGPointMake(mappedX, (_frameHeight - 1.0) - mappedY);
}

- (int32_t)sendPointerX:(double)x y:(double)y pressed:(BOOL)pressed {
    if (_stopped || _workerStopped.load()) return -1;
    const CGPoint viewPoint = CGPointMake(x, y);
    const CGSize viewSize = self.bounds.size;
    CGPoint point = [self enginePointForViewPoint:viewPoint viewSize:viewSize];
    [self runOnEngineThread:^{
        if (_engine == nullptr || !_startupResolved || _workerStopped.load()) return;
        engine_input_event_t event{};
        event.struct_size = sizeof(event);
        event.type = pressed ? ENGINE_INPUT_EVENT_POINTER_DOWN : ENGINE_INPUT_EVENT_POINTER_UP;
        event.timestamp_micros = static_cast<uint64_t>(CACurrentMediaTime() * 1000000.0);
        event.x = point.x;
        event.y = point.y;
        event.pointer_id = 0;
        event.button = 1;
        (void)engine_send_input(_engine, &event);
    } waitUntilDone:NO];
    return 0;
}

- (void)sendTouch:(UITouch *)touch type:(uint32_t)type {
    if (_stopped || _workerStopped.load()) return;
    const CGPoint viewPoint = [touch locationInView:self];
    const CGSize viewSize = self.bounds.size;
    const uint64_t timestamp = static_cast<uint64_t>(touch.timestamp * 1000000.0);
    const int32_t pointerID = static_cast<int32_t>(
        reinterpret_cast<uintptr_t>((__bridge void *)touch) & 0x7fffffff
    );
    const BOOL cancelled = touch.phase == UITouchPhaseCancelled;
    CGPoint point = [self enginePointForViewPoint:viewPoint viewSize:viewSize];
    [self runOnEngineThread:^{
        if (_engine == nullptr || !_startupResolved || _workerStopped.load()) return;
        engine_input_event_t event{};
        event.struct_size = sizeof(event);
        event.type = type;
        event.timestamp_micros = timestamp;
        event.x = point.x;
        event.y = point.y;
        event.pointer_id = pointerID;
        event.button = 1;
        if (cancelled) event.modifiers = ENGINE_INPUT_MODIFIER_POINTER_CANCEL;
        (void)engine_send_input(_engine, &event);
    } waitUntilDone:NO];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) [self sendTouch:touch type:ENGINE_INPUT_EVENT_POINTER_DOWN];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) [self sendTouch:touch type:ENGINE_INPUT_EVENT_POINTER_MOVE];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) [self sendTouch:touch type:ENGINE_INPUT_EVENT_POINTER_UP];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) [self sendTouch:touch type:ENGINE_INPUT_EVENT_POINTER_UP];
}

- (int32_t)stopEngine {
    if (_stopped) return 0;
    _stopped = YES;
    [_displayLink invalidate];
    _displayLink = nil;
    self.layer.contents = nil;
    [self runOnEngineThread:^{
        if (_engine != nullptr) {
            [self drainEngineLogs];
            AppendHostLog(_session, "stop.engine-destroy.begin");
            (void)engine_destroy(_engine);
            _engine = nullptr;
            AppendHostLog(_session, "stop.engine-destroy.end");
        }
    } waitUntilDone:YES];
    _workerStopped.store(true);
    if (_session != nullptr) {
        _session->stopped.store(true);
        [self emitOnMain:YUME_RUNTIME_EVENT_STOPPED code:"aether.stopped"];
    }
    return 0;
}

- (void)detachSession { _session = nullptr; }

@end

static int32_t CreateSession(AetherRuntimeKind kind,
                             const YumeRuntimeConfiguration *configuration,
                             YumeRuntimeEventCallback callback,
                             void *callbackContext,
                             void **providerSession) {
    if (configuration == nullptr || providerSession == nullptr ||
        configuration->abi_version != YUME_RUNTIME_ABI_VERSION ||
        configuration->content_root == nullptr ||
        configuration->save_root == nullptr ||
        configuration->derived_root == nullptr) {
        return -1;
    }
    if (configuration->networking_allowed != 0) return -2;
    auto *session = new (std::nothrow) AetherSession();
    if (session == nullptr) return -3;
    session->kind = kind;
    session->content_root = configuration->content_root;
    session->save_root = configuration->save_root;
    session->derived_root = configuration->derived_root;
    session->log_root = configuration->log_root != nullptr ? configuration->log_root : "";
    session->locale_identifier = configuration->locale_identifier != nullptr
        ? configuration->locale_identifier : "";
    session->callback = callback;
    session->callback_context = callbackContext;
    AppendHostLog(session, "session.created");
    InstallAetherCrashBreadcrumb(session);
    OnMainSync(^NSInteger {
        session->view = [[YumeAetherRuntimeView alloc] initWithSession:session];
        return session->view != nil ? 0 : -1;
    });
    if (session->view == nil) {
        delete session;
        return -4;
    }
    *providerSession = session;
    return 0;
}

static int32_t Start(void *opaque) {
    auto *session = static_cast<AetherSession *>(opaque);
    if (session == nullptr || session->view == nil) return -1;
    return OnMainSync(^NSInteger { return [session->view startEngine]; });
}
static int32_t Pause(void *opaque) {
    auto *session = static_cast<AetherSession *>(opaque);
    if (session == nullptr || session->view == nil) return -1;
    return OnMainSync(^NSInteger { return [session->view pauseEngine]; });
}
static int32_t Resume(void *opaque) {
    auto *session = static_cast<AetherSession *>(opaque);
    if (session == nullptr || session->view == nil) return -1;
    return OnMainSync(^NSInteger { return [session->view resumeEngine]; });
}
static int32_t SendButton(void *opaque, YumeRuntimeInputAction action,
                          int32_t pressed) {
    auto *session = static_cast<AetherSession *>(opaque);
    const int32_t key = KeyForAction(action);
    if (session == nullptr || session->view == nil || key == 0) return -1;
    return OnMainSync(^NSInteger {
        return [session->view sendKey:key pressed:pressed != 0];
    });
}
static int32_t SendPointer(void *opaque, double x, double y, int32_t pressed) {
    auto *session = static_cast<AetherSession *>(opaque);
    if (session == nullptr || session->view == nil) return -1;
    return OnMainSync(^NSInteger {
        return [session->view sendPointerX:x y:y pressed:pressed != 0];
    });
}
static int32_t SendText(void *opaque, const char *text) {
    auto *session = static_cast<AetherSession *>(opaque);
    if (session == nullptr || session->view == nil || text == nullptr) return -1;
    const std::string copied(text);
    return OnMainSync(^NSInteger {
        return [session->view sendText:copied.c_str()];
    });
}
static int32_t Stop(void *opaque) {
    auto *session = static_cast<AetherSession *>(opaque);
    if (session == nullptr || session->view == nil) return 0;
    return OnMainSync(^NSInteger { return [session->view stopEngine]; });
}
static void *NativeView(void *opaque) {
    auto *session = static_cast<AetherSession *>(opaque);
    if (session == nullptr || session->view == nil) return nullptr;
    __block void *view = nullptr;
    OnMainSync(^NSInteger {
        view = (__bridge void *)session->view;
        return 0;
    });
    return view;
}
static void Destroy(void *opaque) {
    auto *session = static_cast<AetherSession *>(opaque);
    if (session == nullptr) return;
    (void)Stop(session);
    OnMainSync(^NSInteger {
        [session->view detachSession];
        session->view = nil;
        return 0;
    });
    delete session;
}

static int32_t CreateKirikiri(const YumeRuntimeConfiguration *configuration,
                              YumeRuntimeEventCallback callback,
                              void *context, void **session) {
    return CreateSession(AetherRuntimeKind::Kirikiri, configuration, callback,
                         context, session);
}
static int32_t CreateONScripter(const YumeRuntimeConfiguration *configuration,
                                YumeRuntimeEventCallback callback,
                                void *context, void **session) {
    return CreateSession(AetherRuntimeKind::ONScripter, configuration, callback,
                         context, session);
}

static const YumeRuntimeProviderAPI kKirikiriProvider = {
    YUME_RUNTIME_ABI_VERSION, "aetherkiri-kirikiri", CreateKirikiri, Start,
    Pause, Resume, SendButton, SendPointer, SendText, Stop, NativeView, Destroy
};
static const YumeRuntimeProviderAPI kONScripterProvider = {
    YUME_RUNTIME_ABI_VERSION, "aetherkiri-onscripter", CreateONScripter, Start,
    Pause, Resume, SendButton, SendPointer, SendText, Stop, NativeView, Destroy
};

extern "C" const YumeRuntimeProviderAPI *
yume_aetherkiri_kirikiri_runtime_provider(void) {
    return &kKirikiriProvider;
}

extern "C" const YumeRuntimeProviderAPI *
yume_aetherkiri_onscripter_runtime_provider(void) {
    return &kONScripterProvider;
}
