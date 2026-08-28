#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <new>
#include <string>

#include "../../YumeCore/Sources/CYumeRuntimeBridge/include/CYumeRuntimeBridge.h"
#include "../../ThirdParty/AetherKiri/Source/bridge/engine_api/include/engine_api.h"
#include "../../ThirdParty/AetherKiri/Source/bridge/engine_api/include/engine_options.h"
#include "../../ThirdParty/AetherKiri/Source/bridge/onscripter_runtime/include/onscripter_runtime.h"

extern "C" void SDL_SetMainReady(void);

enum class AetherRuntimeKind { Kirikiri, ONScripter };

struct AetherSession;

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
};

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
        self.backgroundColor = UIColor.blackColor;
        self.multipleTouchEnabled = YES;
        self.userInteractionEnabled = YES;
        self.layer.contentsGravity = kCAGravityResizeAspect;
        self.layer.magnificationFilter = kCAFilterNearest;
        self.layer.minificationFilter = kCAFilterLinear;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_engine == nullptr || CGRectIsEmpty(self.bounds)) return;
    const CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;
    const uint32_t width = static_cast<uint32_t>(
        std::max<CGFloat>(1, std::round(CGRectGetWidth(self.bounds) * scale)));
    const uint32_t height = static_cast<uint32_t>(
        std::max<CGFloat>(1, std::round(CGRectGetHeight(self.bounds) * scale)));
    (void)engine_set_surface_size(_engine, width, height);
}

- (int32_t)startEngine {
    if (_stopped || _session == nullptr) return -1;
    if (_engine != nullptr) return 0;

    SDL_SetMainReady();
    if (_session->kind == AetherRuntimeKind::ONScripter) {
        aetherkiri::onscripter::RegisterRuntimeProvider();
    }

    engine_create_desc_t description{};
    description.struct_size = sizeof(description);
    description.api_version = ENGINE_API_VERSION;
    description.writable_path_utf8 = _session->save_root.c_str();
    description.cache_path_utf8 = _session->derived_root.c_str();
    engine_result_t result = engine_create(&description, &_engine);
    if (result != ENGINE_RESULT_OK || _engine == nullptr) {
        Emit(_session, YUME_RUNTIME_EVENT_FAILED, "aether.create");
        return static_cast<int32_t>(result != ENGINE_RESULT_OK ? result : -1);
    }

    const char *runtime = _session->kind == AetherRuntimeKind::ONScripter
                              ? "onscripter"
                              : "kirikiri";
    if (SetOption(_engine, "runtime", runtime) != ENGINE_RESULT_OK ||
        SetOption(_engine, ENGINE_OPTION_RENDER_BACKEND,
                  ENGINE_RENDERER_DEBUG_CPU) != ENGINE_RESULT_OK ||
        SetOption(_engine, ENGINE_OPTION_FPS_LIMIT, "60") != ENGINE_RESULT_OK) {
        Emit(_session, YUME_RUNTIME_EVENT_FAILED, "aether.configure");
        engine_destroy(_engine);
        _engine = nullptr;
        return -2;
    }
    NSString *fontPath = BundledDefaultFontPath();
    if (fontPath.length > 0) {
        (void)SetOption(_engine, "default_font", fontPath.fileSystemRepresentation);
    }

    [self layoutIfNeeded];
    result = engine_open_game_async(_engine, _session->content_root.c_str(), nullptr);
    if (result != ENGINE_RESULT_OK) {
        Emit(_session, YUME_RUNTIME_EVENT_FAILED, "aether.open");
        engine_destroy(_engine);
        _engine = nullptr;
        return static_cast<int32_t>(result);
    }

    _displayLink = [CADisplayLink displayLinkWithTarget:self
                                               selector:@selector(displayLinkDidFire:)];
    if (@available(iOS 15.0, *)) {
        _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    } else {
        _displayLink.preferredFramesPerSecond = 60;
    }
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    Emit(_session, YUME_RUNTIME_EVENT_STARTED, "aether.started");
    return 0;
}

- (void)displayLinkDidFire:(CADisplayLink *)link {
    if (_engine == nullptr || _stopped || _paused) return;

    uint32_t startupState = ENGINE_STARTUP_STATE_IDLE;
    const engine_result_t startupResult =
        engine_get_startup_state(_engine, &startupState);
    if (startupResult != ENGINE_RESULT_OK) {
        [self failWithCode:"aether.startup-state"];
        return;
    }
    if (startupState == ENGINE_STARTUP_STATE_FAILED) {
        [self failWithCode:"aether.startup"];
        return;
    }
    if (startupState != ENGINE_STARTUP_STATE_SUCCEEDED) return;
    _startupResolved = YES;

    const CFTimeInterval delta = _lastTimestamp > 0
        ? std::clamp(link.timestamp - _lastTimestamp, 0.001, 0.100)
        : (1.0 / 60.0);
    _lastTimestamp = link.timestamp;
    const uint32_t deltaMilliseconds = static_cast<uint32_t>(
        std::max(1.0, std::round(delta * 1000.0)));
    const engine_result_t tickResult = engine_tick(_engine, deltaMilliseconds);
    if (tickResult != ENGINE_RESULT_OK) {
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

    self.layer.contents = (__bridge id)image;
    CGImageRelease(image);
    _lastFrameSerial = frame.frame_serial;
    _frameWidth = frame.width;
    _frameHeight = frame.height;
    if (!_firstFrameSent) {
        _firstFrameSent = YES;
        Emit(_session, YUME_RUNTIME_EVENT_FIRST_FRAME, "aether.first-frame");
    }
}

- (void)failWithCode:(const char *)code {
    if (_stopped) return;
    _displayLink.paused = YES;
    Emit(_session, YUME_RUNTIME_EVENT_FAILED, code);
}

- (int32_t)pauseEngine {
    if (_engine == nullptr || _stopped) return -1;
    if (_paused) return 0;
    const engine_result_t result = engine_pause(_engine);
    if (result == ENGINE_RESULT_OK) {
        _paused = YES;
        _displayLink.paused = YES;
        Emit(_session, YUME_RUNTIME_EVENT_PAUSED, "aether.paused");
    }
    return static_cast<int32_t>(result);
}

- (int32_t)resumeEngine {
    if (_engine == nullptr || _stopped) return -1;
    if (!_paused) return 0;
    const engine_result_t result = engine_resume(_engine);
    if (result == ENGINE_RESULT_OK) {
        _paused = NO;
        _lastTimestamp = 0;
        _displayLink.paused = NO;
        Emit(_session, YUME_RUNTIME_EVENT_RESUMED, "aether.resumed");
    }
    return static_cast<int32_t>(result);
}

- (int32_t)sendKey:(int32_t)key pressed:(BOOL)pressed {
    if (_engine == nullptr || !_startupResolved || _stopped || key == 0) return -1;
    engine_input_event_t event{};
    event.struct_size = sizeof(event);
    event.type = pressed ? ENGINE_INPUT_EVENT_KEY_DOWN : ENGINE_INPUT_EVENT_KEY_UP;
    event.timestamp_micros = static_cast<uint64_t>(CACurrentMediaTime() * 1000000.0);
    event.key_code = key;
    return static_cast<int32_t>(engine_send_input(_engine, &event));
}

- (int32_t)sendText:(const char *)text {
    if (_engine == nullptr || !_startupResolved || _stopped || text == nullptr) return -1;
    NSString *string = [NSString stringWithUTF8String:text];
    if (string == nil) return -1;
    __block engine_result_t result = ENGINE_RESULT_OK;
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
        result = engine_send_input(_engine, &event);
        if (result != ENGINE_RESULT_OK) *stop = YES;
    }];
    return static_cast<int32_t>(result);
}

- (CGPoint)enginePointForViewPoint:(CGPoint)point {
    if (_frameWidth == 0 || _frameHeight == 0 || CGRectIsEmpty(self.bounds)) return point;
    const CGFloat scale = std::min(CGRectGetWidth(self.bounds) / _frameWidth,
                                   CGRectGetHeight(self.bounds) / _frameHeight);
    const CGFloat contentWidth = _frameWidth * scale;
    const CGFloat contentHeight = _frameHeight * scale;
    const CGFloat originX = (CGRectGetWidth(self.bounds) - contentWidth) * 0.5;
    const CGFloat originY = (CGRectGetHeight(self.bounds) - contentHeight) * 0.5;
    return CGPointMake(std::clamp((point.x - originX) / scale, 0.0, (double)_frameWidth - 1.0),
                       std::clamp((point.y - originY) / scale, 0.0, (double)_frameHeight - 1.0));
}

- (int32_t)sendPointerX:(double)x y:(double)y pressed:(BOOL)pressed {
    if (_engine == nullptr || !_startupResolved || _stopped) return -1;
    CGPoint point = [self enginePointForViewPoint:CGPointMake(x, y)];
    engine_input_event_t event{};
    event.struct_size = sizeof(event);
    event.type = pressed ? ENGINE_INPUT_EVENT_POINTER_DOWN : ENGINE_INPUT_EVENT_POINTER_UP;
    event.timestamp_micros = static_cast<uint64_t>(CACurrentMediaTime() * 1000000.0);
    event.x = point.x;
    event.y = point.y;
    event.pointer_id = 0;
    event.button = 1;
    return static_cast<int32_t>(engine_send_input(_engine, &event));
}

- (void)sendTouch:(UITouch *)touch type:(uint32_t)type {
    if (_engine == nullptr || !_startupResolved || _stopped) return;
    CGPoint point = [self enginePointForViewPoint:[touch locationInView:self]];
    engine_input_event_t event{};
    event.struct_size = sizeof(event);
    event.type = type;
    event.timestamp_micros = static_cast<uint64_t>(touch.timestamp * 1000000.0);
    event.x = point.x;
    event.y = point.y;
    event.pointer_id = static_cast<int32_t>(reinterpret_cast<uintptr_t>((__bridge void *)touch) & 0x7fffffff);
    event.button = 1;
    if (touch.phase == UITouchPhaseCancelled) {
        event.modifiers = ENGINE_INPUT_MODIFIER_POINTER_CANCEL;
    }
    (void)engine_send_input(_engine, &event);
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
    if (_engine != nullptr) {
        (void)engine_destroy(_engine);
        _engine = nullptr;
    }
    if (_session != nullptr) {
        _session->stopped.store(true);
        Emit(_session, YUME_RUNTIME_EVENT_STOPPED, "aether.stopped");
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
