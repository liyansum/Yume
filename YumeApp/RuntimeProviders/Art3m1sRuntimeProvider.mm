#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <new>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

#include "Art3m1sFFI.h"
#include "../../YumeCore/Sources/CYumeRuntimeBridge/include/CYumeRuntimeBridge.h"

struct Art3m1sSession;

@interface YumeArt3m1sView : UIView
- (instancetype)initWithSession:(Art3m1sSession *)session;
- (int32_t)startEngine;
- (int32_t)pauseEngine;
- (int32_t)resumeEngine;
- (int32_t)sendKey:(uint32_t)key pressed:(BOOL)pressed;
- (int32_t)sendPointerX:(double)x y:(double)y pressed:(BOOL)pressed;
- (int32_t)stopEngine;
- (void)detachSession;
@end

struct Art3m1sSession {
    std::string contentRoot;
    std::string saveRoot;
    std::string derivedRoot;
    std::string logRoot;
    YumeRuntimeEventCallback callback = nullptr;
    void *callbackContext = nullptr;
    YumeRuntimeLogCallback logCallback = nullptr;
    void *logCallbackContext = nullptr;
    __strong YumeArt3m1sView *view = nil;
    std::atomic<bool> started{false};
    std::atomic<bool> stopped{false};
    std::mutex logMutex;
};

static std::mutex gArt3m1sMutex;
static Art3m1sSession *gArt3m1sSession = nullptr;
// art3m1s-core stores callback roots in process-wide OnceLock values. Reusing
// it for another imported game would silently retain the previous save path,
// so fail closed and require a process restart after the first session.
static bool gArt3m1sEverCreated = false;

static int32_t OnMainSync(NSInteger (^operation)(void)) {
    if (NSThread.isMainThread) return static_cast<int32_t>(operation());
    __block NSInteger result = -1;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = operation(); });
    return static_cast<int32_t>(result);
}

static void Emit(Art3m1sSession *session, YumeRuntimeEventKind kind,
                 const char *code) {
    if (session != nullptr && session->callback != nullptr) {
        session->callback(kind, code != nullptr ? code : "", session->callbackContext);
    }
}

static void AppendLog(Art3m1sSession *session, YumeRuntimeLogLevel level,
                      const char *message) {
    if (session == nullptr) return;
    const char *text = message != nullptr ? message : "";
    if (session->logCallback != nullptr) {
        session->logCallback(level, "art3m1s", text, session->logCallbackContext);
    }
    if (session->logRoot.empty()) return;
    std::lock_guard<std::mutex> guard(session->logMutex);
    @autoreleasepool {
        NSString *root = [NSString stringWithUTF8String:session->logRoot.c_str()];
        if (root.length == 0) return;
        [NSFileManager.defaultManager createDirectoryAtPath:root
                                withIntermediateDirectories:YES
                                                 attributes:nil error:nil];
        NSString *path = [root stringByAppendingPathComponent:@"art3m1s-host.log"];
        FILE *stream = fopen(path.fileSystemRepresentation, "ab");
        if (stream == nullptr) return;
        fprintf(stream, "%.3f [thread=%s] %s\n", NSDate.date.timeIntervalSince1970,
                NSThread.isMainThread ? "main" : "worker", text);
        fflush(stream);
        fsync(fileno(stream));
        fclose(stream);
    }
}

static Art3m1sSession *ActiveSession(void) {
    std::lock_guard<std::mutex> guard(gArt3m1sMutex);
    return gArt3m1sSession;
}

static NSString *LogicalPath(const char *rawPath) {
    if (rawPath == nullptr) return nil;
    NSString *value = [NSString stringWithUTF8String:rawPath];
    if (value.length == 0) return nil;
    value = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    while ([value hasPrefix:@"/"]) value = [value substringFromIndex:1];
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *part in parts) {
        if (part.length == 0 || [part isEqualToString:@"."]) continue;
        if ([part isEqualToString:@".."] || [part rangeOfString:@":"].location != NSNotFound)
            return nil;
        [clean addObject:part];
    }
    return clean.count > 0 ? [clean componentsJoinedByString:@"/"] : nil;
}

static BOOL IsContainedPath(NSString *candidate, NSString *root) {
    NSString *normalizedRoot = root.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString *normalized = candidate.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    return [normalized isEqualToString:normalizedRoot] ||
        [normalized hasPrefix:[normalizedRoot stringByAppendingString:@"/"]];
}

static NSString *PathBelowRoot(const std::string &rootValue, NSString *logical,
                               BOOL forWrite) {
    NSString *root = [NSString stringWithUTF8String:rootValue.c_str()];
    if (root.length == 0 || logical.length == 0) return nil;
    NSString *candidate = [root stringByAppendingPathComponent:logical];
    NSString *check = forWrite ? candidate.stringByDeletingLastPathComponent : candidate;
    if (!IsContainedPath(check, root)) return nil;
    return candidate.stringByStandardizingPath;
}

static NSString *ReadPath(Art3m1sSession *session, NSString *logical) {
    if (session == nullptr || logical.length == 0) return nil;
    NSString *saveLogical = logical;
    if ([logical.lowercaseString hasPrefix:@"save/"])
        saveLogical = [logical substringFromIndex:5];
    NSString *save = PathBelowRoot(session->saveRoot, saveLogical, NO);
    if (save != nil && [NSFileManager.defaultManager isReadableFileAtPath:save]) return save;
    NSString *content = PathBelowRoot(session->contentRoot, logical, NO);
    if (content != nil && [NSFileManager.defaultManager isReadableFileAtPath:content]) return content;
    NSString *derived = PathBelowRoot(session->derivedRoot, logical, NO);
    if (derived != nil && [NSFileManager.defaultManager isReadableFileAtPath:derived]) return derived;
    return nil;
}

static NSString *WritePath(Art3m1sSession *session, NSString *logical) {
    if ([logical.lowercaseString hasPrefix:@"save/"])
        logical = [logical substringFromIndex:5];
    return session != nullptr ? PathBelowRoot(session->saveRoot, logical, YES) : nil;
}

static void Art3m1sLog(const char *level, const char *message) {
    Art3m1sSession *session = ActiveSession();
    const YumeRuntimeLogLevel mapped = level != nullptr && level[0] == 'E'
        ? YUME_RUNTIME_LOG_ERROR
        : (level != nullptr && level[0] == 'W' ? YUME_RUNTIME_LOG_WARNING
                                                : YUME_RUNTIME_LOG_INFORMATION);
    AppendLog(session, mapped, message);
}

static int32_t Art3m1sRead(const char *rawPath, uint8_t *buffer,
                           int32_t bufferSize, int64_t offset) {
    Art3m1sSession *session = ActiveSession();
    NSString *path = ReadPath(session, LogicalPath(rawPath));
    if (path == nil) return -1;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    struct stat info {};
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) {
        close(fd);
        return -1;
    }
    if (buffer == nullptr && bufferSize == 0 && offset == -1) {
        close(fd);
        return info.st_size <= INT32_MAX ? static_cast<int32_t>(info.st_size) : -1;
    }
    if (buffer == nullptr || bufferSize < 0 || offset < 0) {
        close(fd);
        return -1;
    }
    const ssize_t count = pread(fd, buffer, static_cast<size_t>(bufferSize), offset);
    close(fd);
    return count >= 0 && count <= INT32_MAX ? static_cast<int32_t>(count) : -1;
}

static int32_t Art3m1sWrite(const char *rawPath, const uint8_t *buffer,
                            int32_t length) {
    Art3m1sSession *session = ActiveSession();
    NSString *path = WritePath(session, LogicalPath(rawPath));
    if (path == nil || length < 0 || (length > 0 && buffer == nullptr)) return -1;
    NSString *parent = path.stringByDeletingLastPathComponent;
    if (![NSFileManager.defaultManager createDirectoryAtPath:parent
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:nil]) return -1;
    NSData *data = [NSData dataWithBytes:buffer length:static_cast<NSUInteger>(length)];
    return [data writeToFile:path options:NSDataWritingAtomic error:nil] ? length : -1;
}

static int32_t Art3m1sDelete(const char *rawPath) {
    Art3m1sSession *session = ActiveSession();
    NSString *path = WritePath(session, LogicalPath(rawPath));
    if (path == nil) return -1;
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return 0;
    return [NSFileManager.defaultManager removeItemAtPath:path error:nil] ? 0 : -1;
}

static int32_t Art3m1sStat(const char *rawPath, int64_t *components,
                           int32_t componentCount) {
    if (components == nullptr || componentCount < 6) return -1;
    Art3m1sSession *session = ActiveSession();
    NSString *logical = LogicalPath(rawPath);
    NSString *path = WritePath(session, logical);
    if (path == nil || ![NSFileManager.defaultManager fileExistsAtPath:path])
        path = ReadPath(session, logical);
    NSDictionary *attributes = path != nil
        ? [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] : nil;
    NSDate *date = attributes[NSFileModificationDate];
    if (date == nil) return -1;
    NSDateComponents *value = [NSCalendar.currentCalendar
        components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                    NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond)
          fromDate:date];
    components[0] = value.year;
    components[1] = value.month;
    components[2] = value.day;
    components[3] = value.hour;
    components[4] = value.minute;
    components[5] = value.second;
    return 6;
}

static NSString *CaseInsensitiveFile(NSString *root, NSString *name) {
    NSArray<NSString *> *children = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:root error:nil];
    for (NSString *child in children) {
        if ([child caseInsensitiveCompare:name] == NSOrderedSame)
            return [root stringByAppendingPathComponent:child];
    }
    return nil;
}

static uint32_t KeyForAction(YumeRuntimeInputAction action) {
    switch (action) {
        case YUME_RUNTIME_INPUT_UP: return 0x26;
        case YUME_RUNTIME_INPUT_DOWN: return 0x28;
        case YUME_RUNTIME_INPUT_LEFT: return 0x25;
        case YUME_RUNTIME_INPUT_RIGHT: return 0x27;
        case YUME_RUNTIME_INPUT_CONFIRM:
        case YUME_RUNTIME_INPUT_POINTER_PRIMARY: return 0x0D;
        case YUME_RUNTIME_INPUT_CANCEL:
        case YUME_RUNTIME_INPUT_MENU: return 0x1B;
        case YUME_RUNTIME_INPUT_PAGE_UP: return 0x21;
        case YUME_RUNTIME_INPUT_PAGE_DOWN: return 0x22;
        case YUME_RUNTIME_INPUT_FAST_FORWARD: return 0x11;
        case YUME_RUNTIME_INPUT_AUTO_MODE: return 'A';
        case YUME_RUNTIME_INPUT_HISTORY: return 'H';
    }
    return 0;
}

@implementation YumeArt3m1sView {
    Art3m1sSession *_session;
    void *_runtime;
    CADisplayLink *_displayLink;
    std::vector<uint8_t> _pixels;
    uint32_t _stageWidth;
    uint32_t _stageHeight;
    CFTimeInterval _lastTimestamp;
    BOOL _firstFrame;
    BOOL _paused;
    BOOL _startRequested;
}

- (instancetype)initWithSession:(Art3m1sSession *)session {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _session = session;
        self.backgroundColor = UIColor.blackColor;
        self.clipsToBounds = YES;
        self.userInteractionEnabled = YES;
        self.layer.contentsGravity = kCAGravityResizeAspect;
        self.layer.magnificationFilter = kCAFilterLinear;
    }
    return self;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (_startRequested && _runtime == nullptr) (void)[self startEngine];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_startRequested && _runtime == nullptr && !CGRectIsEmpty(self.bounds))
        (void)[self startEngine];
}

- (int32_t)startEngine {
    if (_session == nullptr || _session->stopped.load()) return -1;
    if (_runtime != nullptr) return 0;
    _startRequested = YES;
    // UIViewRepresentable constructs the hierarchy before it is attached to a
    // UIWindow. Defer GL creation until both the window and final bounds exist.
    if (self.window == nil || CGRectIsEmpty(self.bounds)) return 0;
    _startRequested = NO;
    NSString *root = [NSString stringWithUTF8String:_session->contentRoot.c_str()];
    NSString *iniPath = CaseInsensitiveFile(root, @"system.ini");
    NSData *ini = iniPath != nil ? [NSData dataWithContentsOfFile:iniPath] : nil;
    if (ini.length == 0) {
        AppendLog(_session, YUME_RUNTIME_LOG_ERROR, "start.failed system.ini missing");
        Emit(_session, YUME_RUNTIME_EVENT_FAILED, "artemis.system-ini-missing");
        return -2;
    }
    NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
    art3m1s_set_angle_path(frameworks.fileSystemRepresentation);
    art3m1s_set_save_dir("save");
    _runtime = art3m1s_runtime_create(1280, 720, 3 /* ANGLE Metal */);
    if (_runtime == nullptr) {
        AppendLog(_session, YUME_RUNTIME_LOG_ERROR, "start.failed runtime_create");
        Emit(_session, YUME_RUNTIME_EVENT_FAILED, "artemis.renderer-create-failed");
        return -3;
    }
    if (art3m1s_runtime_load_project_bytes(_runtime,
            static_cast<const uint8_t *>(ini.bytes), ini.length, "ios") != 0) {
        AppendLog(_session, YUME_RUNTIME_LOG_ERROR, "start.failed load_project");
        art3m1s_runtime_destroy(_runtime);
        _runtime = nullptr;
        Emit(_session, YUME_RUNTIME_EVENT_FAILED, "artemis.project-load-failed");
        return -4;
    }
    _stageWidth = art3m1s_runtime_stage_width(_runtime);
    _stageHeight = art3m1s_runtime_stage_height(_runtime);
    const uint32_t capacity = art3m1s_runtime_pixel_buffer_size(_runtime);
    if (_stageWidth == 0 || _stageHeight == 0 || capacity == 0) {
        art3m1s_runtime_destroy(_runtime);
        _runtime = nullptr;
        Emit(_session, YUME_RUNTIME_EVENT_FAILED, "artemis.invalid-stage");
        return -5;
    }
    _pixels.resize(capacity);
    _lastTimestamp = 0;
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(drawFrame:)];
    _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    _session->started.store(true);
    AppendLog(_session, YUME_RUNTIME_LOG_INFORMATION, "runtime.started backend=angle-metal");
    Emit(_session, YUME_RUNTIME_EVENT_STARTED, "artemis.started");
    return 0;
}

- (void)drawFrame:(CADisplayLink *)link {
    if (_runtime == nullptr || _paused) return;
    uint32_t delta = _lastTimestamp > 0
        ? static_cast<uint32_t>(std::clamp((link.timestamp - _lastTimestamp) * 1000.0, 1.0, 100.0))
        : 16;
    _lastTimestamp = link.timestamp;
    const uint32_t written = art3m1s_runtime_advance_and_render(
        _runtime, delta, _pixels.data(), static_cast<uint32_t>(_pixels.size()));
    if (written > 0) {
        NSData *data = [NSData dataWithBytes:_pixels.data() length:written];
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGImageRef image = CGImageCreate(_stageWidth, _stageHeight, 8, 32,
            _stageWidth * 4, colorSpace,
            kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast,
            provider, nullptr, false, kCGRenderingIntentDefault);
        if (image != nullptr) self.layer.contents = (__bridge id)image;
        if (image != nullptr) CGImageRelease(image);
        CGColorSpaceRelease(colorSpace);
        CGDataProviderRelease(provider);
        if (!_firstFrame) {
            _firstFrame = YES;
            Emit(_session, YUME_RUNTIME_EVENT_FIRST_FRAME, "artemis.first-frame");
        }
    }
    if (art3m1s_runtime_is_exit_requested(_runtime) != 0) [self stopEngine];
}

- (CGPoint)stagePointForViewPoint:(CGPoint)point {
    if (_stageWidth == 0 || _stageHeight == 0) return CGPointZero;
    const CGFloat scale = MIN(self.bounds.size.width / _stageWidth,
                              self.bounds.size.height / _stageHeight);
    const CGFloat width = _stageWidth * scale;
    const CGFloat height = _stageHeight * scale;
    const CGFloat x = (point.x - (self.bounds.size.width - width) / 2.0) / scale;
    const CGFloat y = (point.y - (self.bounds.size.height - height) / 2.0) / scale;
    return CGPointMake(std::clamp(x, 0.0, static_cast<CGFloat>(_stageWidth - 1)),
                       std::clamp(y, 0.0, static_cast<CGFloat>(_stageHeight - 1)));
}

- (void)feedTouches:(NSSet<UITouch *> *)touches phase:(uint8_t)phase {
    if (_runtime == nullptr) return;
    for (UITouch *touch in touches) {
        CGPoint point = [self stagePointForViewPoint:[touch locationInView:self]];
        uintptr_t raw = reinterpret_cast<uintptr_t>((__bridge void *)touch);
        art3m1s_runtime_feed_touch(_runtime, static_cast<uint32_t>(raw), phase,
                                  static_cast<int32_t>(point.x), static_cast<int32_t>(point.y));
        art3m1s_runtime_feed_mouse(_runtime, static_cast<int32_t>(point.x),
                                  static_cast<int32_t>(point.y));
        if (phase == 0 || phase == 2)
            art3m1s_runtime_feed_mouse_button(_runtime, 0, phase == 0 ? 1 : 0);
    }
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self feedTouches:touches phase:0];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self feedTouches:touches phase:1];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self feedTouches:touches phase:2];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self feedTouches:touches phase:2];
}

- (int32_t)pauseEngine {
    if (_runtime == nullptr || _paused) return -1;
    _paused = YES;
    _displayLink.paused = YES;
    art3m1s_runtime_notify_lifecycle(_runtime, 1);
    Emit(_session, YUME_RUNTIME_EVENT_PAUSED, "artemis.paused");
    return 0;
}
- (int32_t)resumeEngine {
    if (_runtime == nullptr || !_paused) return -1;
    art3m1s_runtime_notify_lifecycle(_runtime, 2);
    _paused = NO;
    _lastTimestamp = 0;
    _displayLink.paused = NO;
    Emit(_session, YUME_RUNTIME_EVENT_RESUMED, "artemis.resumed");
    return 0;
}
- (int32_t)sendKey:(uint32_t)key pressed:(BOOL)pressed {
    if (_runtime == nullptr || key == 0) return -1;
    art3m1s_runtime_feed_key(_runtime, key, pressed ? 1 : 0);
    return 0;
}
- (int32_t)sendPointerX:(double)x y:(double)y pressed:(BOOL)pressed {
    if (_runtime == nullptr) return -1;
    CGPoint point = [self stagePointForViewPoint:CGPointMake(x, y)];
    art3m1s_runtime_feed_mouse(_runtime, point.x, point.y);
    art3m1s_runtime_feed_mouse_button(_runtime, 0, pressed ? 1 : 0);
    return 0;
}
- (int32_t)stopEngine {
    if (_session == nullptr || _session->stopped.exchange(true)) return 0;
    [_displayLink invalidate];
    _displayLink = nil;
    if (_runtime != nullptr) {
        art3m1s_runtime_notify_lifecycle(_runtime, 0);
        art3m1s_runtime_destroy(_runtime);
        _runtime = nullptr;
    }
    _pixels.clear();
    self.layer.contents = nil;
    Emit(_session, YUME_RUNTIME_EVENT_STOPPED, "artemis.stopped");
    return 0;
}
- (void)detachSession {
    [_displayLink invalidate];
    _displayLink = nil;
    _session = nullptr;
}
@end

static int32_t Art3m1sCreate(const YumeRuntimeConfiguration *configuration,
                             YumeRuntimeEventCallback callback, void *context,
                             void **providerSession) {
    if (configuration == nullptr || providerSession == nullptr ||
        configuration->content_root == nullptr || configuration->save_root == nullptr)
        return -1;
    std::lock_guard<std::mutex> guard(gArt3m1sMutex);
    if (gArt3m1sSession != nullptr || gArt3m1sEverCreated) return -2;
    auto *session = new (std::nothrow) Art3m1sSession();
    if (session == nullptr) return -3;
    session->contentRoot = configuration->content_root;
    session->saveRoot = configuration->save_root;
    session->derivedRoot = configuration->derived_root ?: "";
    session->logRoot = configuration->log_root ?: "";
    session->callback = callback;
    session->callbackContext = context;
    session->logCallback = configuration->log_callback;
    session->logCallbackContext = configuration->log_callback_context;
    session->view = [[YumeArt3m1sView alloc] initWithSession:session];
    if (session->view == nil) {
        delete session;
        return -3;
    }
    gArt3m1sEverCreated = true;
    gArt3m1sSession = session;
    art3m1s_register_log_callback(Art3m1sLog);
    art3m1s_register_file_reader(Art3m1sRead);
    art3m1s_register_file_writer(Art3m1sWrite);
    art3m1s_register_file_delete(Art3m1sDelete);
    art3m1s_register_file_stat(Art3m1sStat);
    [NSFileManager.defaultManager createDirectoryAtPath:
        [NSString stringWithUTF8String:session->saveRoot.c_str()]
        withIntermediateDirectories:YES attributes:nil error:nil];
    *providerSession = session;
    return 0;
}

static int32_t Art3m1sStart(void *opaque) {
    auto *session = static_cast<Art3m1sSession *>(opaque);
    return session != nullptr && session->view != nil
        ? OnMainSync(^NSInteger { return [session->view startEngine]; }) : -1;
}
static int32_t Art3m1sPause(void *opaque) {
    auto *session = static_cast<Art3m1sSession *>(opaque);
    return session != nullptr && session->view != nil
        ? OnMainSync(^NSInteger { return [session->view pauseEngine]; }) : -1;
}
static int32_t Art3m1sResume(void *opaque) {
    auto *session = static_cast<Art3m1sSession *>(opaque);
    return session != nullptr && session->view != nil
        ? OnMainSync(^NSInteger { return [session->view resumeEngine]; }) : -1;
}
static int32_t Art3m1sSendButton(void *opaque, YumeRuntimeInputAction action,
                                 int32_t pressed) {
    auto *session = static_cast<Art3m1sSession *>(opaque);
    uint32_t key = KeyForAction(action);
    return session != nullptr && session->view != nil && key != 0
        ? OnMainSync(^NSInteger { return [session->view sendKey:key pressed:pressed != 0]; }) : -1;
}
static int32_t Art3m1sSendPointer(void *opaque, double x, double y, int32_t pressed) {
    auto *session = static_cast<Art3m1sSession *>(opaque);
    return session != nullptr && session->view != nil
        ? OnMainSync(^NSInteger { return [session->view sendPointerX:x y:y pressed:pressed != 0]; }) : -1;
}
static int32_t Art3m1sSendText(void *, const char *) { return -1; }
static int32_t Art3m1sStop(void *opaque) {
    auto *session = static_cast<Art3m1sSession *>(opaque);
    return session != nullptr && session->view != nil
        ? OnMainSync(^NSInteger { return [session->view stopEngine]; }) : 0;
}
static void *Art3m1sNativeView(void *opaque) {
    auto *session = static_cast<Art3m1sSession *>(opaque);
    return session != nullptr ? (__bridge void *)session->view : nullptr;
}
static void Art3m1sDestroy(void *opaque) {
    auto *session = static_cast<Art3m1sSession *>(opaque);
    if (session == nullptr) return;
    (void)Art3m1sStop(session);
    [session->view detachSession];
    session->view = nil;
    {
        std::lock_guard<std::mutex> guard(gArt3m1sMutex);
        if (gArt3m1sSession == session) gArt3m1sSession = nullptr;
    }
    delete session;
}

static const YumeRuntimeProviderAPI kArt3m1sProvider = {
    YUME_RUNTIME_ABI_VERSION, "art3m1s", Art3m1sCreate, Art3m1sStart,
    Art3m1sPause, Art3m1sResume, Art3m1sSendButton, Art3m1sSendPointer,
    Art3m1sSendText, Art3m1sStop, Art3m1sNativeView, Art3m1sDestroy
};

extern "C" const YumeRuntimeProviderAPI *yume_art3m1s_runtime_provider(void) {
    return &kArt3m1sProvider;
}
