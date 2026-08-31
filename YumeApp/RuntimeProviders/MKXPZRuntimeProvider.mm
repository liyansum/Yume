#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <fcntl.h>
#include <mutex>
#include <new>
#include <signal.h>
#include <string>
#include <unistd.h>
#include <vector>

#include <SDL.h>

#include "../../YumeCore/Sources/CYumeRuntimeBridge/include/CYumeRuntimeBridge.h"
#include "../../ThirdParty/MKXPZ/Source/src/app_bridge.h"

extern "C" int SDL_main(int argc, char *argv[]);
extern "C" void SDL_SetMainReady(void);

enum class MKXPRubyGeneration { Ruby18, Ruby19, Ruby31 };
enum class MKXPRGSSGeneration { XP, VX, VXAce };

struct MKXPSession;

@interface YumeMKXPHostView : UIView
- (instancetype)initWithSession:(MKXPSession *)session;
- (void)startEngineIfAttached;
- (void)syncHostMetalLayer;
- (void)enqueueCPUFrameBytes:(const unsigned char *)rgba
                       width:(int)width
                      height:(int)height;
- (void)presentCPUFrame:(NSData *)data width:(int)width height:(int)height;
- (void)detachSession;
@end

struct MKXPSession {
    std::string contentRoot;
    std::string saveRoot;
    std::string derivedRoot;
    std::string logRoot;
    std::vector<std::string> rtpRoots;
    MKXPRGSSGeneration rgss = MKXPRGSSGeneration::XP;
    MKXPRubyGeneration ruby = MKXPRubyGeneration::Ruby18;
    YumeRuntimeEventCallback callback = nullptr;
    void *callbackContext = nullptr;
    YumeRuntimeLogCallback logCallback = nullptr;
    void *logCallbackContext = nullptr;
    std::mutex callbackMutex;
    std::mutex logMutex;
    __strong YumeMKXPHostView *view = nil;
    std::atomic<bool> running{false};
    std::atomic<bool> everStarted{false};
    std::atomic<bool> mainReturned{false};
    std::atomic<bool> destroyRequested{false};
    std::atomic<bool> stoppedEventSent{false};
    std::atomic<uint64_t> cpuFrameCallbacks{0};
    std::atomic<uint64_t> cpuFrameDrops{0};
    std::atomic<uint64_t> cpuFramesPresented{0};
    std::atomic<uint64_t> inputSequence{0};
};

static void AppendMKXPHostLog(MKXPSession *session, const char *message) {
    if (session == nullptr) return;
    {
        std::lock_guard<std::mutex> callbackLock(session->callbackMutex);
        if (session->logCallback != nullptr) {
            session->logCallback(YUME_RUNTIME_LOG_INFORMATION, "mkxp.host",
                                 message != nullptr ? message : "",
                                 session->logCallbackContext);
        }
    }
    if (session->logRoot.empty()) return;
    std::lock_guard<std::mutex> lock(session->logMutex);
    @autoreleasepool {
        NSString *root = [NSString stringWithUTF8String:session->logRoot.c_str()];
        if (root == nil) return;
        [[NSFileManager defaultManager] createDirectoryAtPath:root
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *path = [root stringByAppendingPathComponent:@"mkxp-host.log"];
        FILE *file = fopen(path.fileSystemRepresentation, "ab");
        if (file == nullptr) return;
        NSString *detail = message != nullptr
            ? ([NSString stringWithUTF8String:message] ?: @"<invalid utf8>")
            : @"";
        NSString *line = [NSString stringWithFormat:@"%.3f [mono=%.3f thread=%@] %@\n",
                          NSDate.date.timeIntervalSince1970, CACurrentMediaTime(),
                          NSThread.isMainThread ? @"main" : @"worker", detail];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (data != nil) fwrite(data.bytes, 1, data.length, file);
        fflush(file);
        fsync(fileno(file));
        fclose(file);
    }
}

static void AppendMKXPPathSummary(MKXPSession *session, const char *label,
                                  const std::string &path) {
    @autoreleasepool {
        NSString *value = [NSString stringWithUTF8String:path.c_str()];
        BOOL isDirectory = NO;
        const BOOL exists = value.length > 0 &&
            [[NSFileManager defaultManager] fileExistsAtPath:value
                                                 isDirectory:&isDirectory];
        NSArray<NSString *> *children = exists && isDirectory
            ? [[NSFileManager defaultManager] contentsOfDirectoryAtPath:value error:nil]
            : nil;
        char line[512];
        std::snprintf(line, sizeof(line),
                      "path.%s exists=%d directory=%d readable=%d writable=%d children=%lu value=%s",
                      label, exists ? 1 : 0, isDirectory ? 1 : 0,
                      value != nil && [[NSFileManager defaultManager] isReadableFileAtPath:value] ? 1 : 0,
                      value != nil && [[NSFileManager defaultManager] isWritableFileAtPath:value] ? 1 : 0,
                      static_cast<unsigned long>(children.count), path.c_str());
        AppendMKXPHostLog(session, line);
    }
}

static std::mutex gMKXPClaimMutex;
static bool gMKXPClaimed = false;
static volatile sig_atomic_t gMKXPCrashLogFD = -1;

static void MKXPCrashSignalHandler(int signalNumber) {
    const int fd = static_cast<int>(gMKXPCrashLogFD);
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
}

static void InstallMKXPCrashBreadcrumb(MKXPSession *session) {
    if (session == nullptr || session->logRoot.empty()) return;
    @autoreleasepool {
        NSString *root = [NSString stringWithUTF8String:session->logRoot.c_str()];
        if (root.length == 0) return;
        [[NSFileManager defaultManager] createDirectoryAtPath:root
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *path = [root stringByAppendingPathComponent:@"mkxp-crash.log"];
        const int fd = open(path.fileSystemRepresentation,
                            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
        if (fd < 0) return;
        const int previous = static_cast<int>(gMKXPCrashLogFD);
        gMKXPCrashLogFD = fd;
        if (previous >= 0) close(previous);
        const int signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP};
        for (const int signalNumber : signals) {
            struct sigaction action {};
            action.sa_handler = MKXPCrashSignalHandler;
            sigemptyset(&action.sa_mask);
            action.sa_flags = SA_RESETHAND;
            (void)sigaction(signalNumber, &action, nullptr);
        }
    }
    AppendMKXPHostLog(session, "crash-handler.install.end");
}

static void ReleaseMKXPClaimAfterFailedCreation(void) {
    std::lock_guard<std::mutex> lock(gMKXPClaimMutex);
    gMKXPClaimed = false;
}

static void MKXPEmit(MKXPSession *session, YumeRuntimeEventKind kind,
                     const char *code) {
    if (session == nullptr) return;
    std::lock_guard<std::mutex> lock(session->callbackMutex);
    if (session->callback != nullptr) {
        session->callback(kind, code != nullptr ? code : "",
                          session->callbackContext);
    }
}

static MKXPRGSSGeneration DetectRGSSGeneration(NSString *root) {
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *iniName in @[@"Game.ini", @"game.ini"]) {
        NSString *iniPath = [root stringByAppendingPathComponent:iniName];
        NSString *ini = [NSString stringWithContentsOfFile:iniPath
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
        if (ini.length == 0) {
            ini = [NSString stringWithContentsOfFile:iniPath
                                           encoding:NSShiftJISStringEncoding
                                              error:nil];
        }
        NSString *lower = ini.lowercaseString;
        // Longer RGSS3 tokens first so "RGSS301.dll" is not read as RGSS1.
        if ([lower containsString:@"rgss3"] || [lower containsString:@"rgss300"] ||
            [lower containsString:@"rgss301"]) {
            return MKXPRGSSGeneration::VXAce;
        }
        if ([lower containsString:@"rgss2"] || [lower containsString:@"rgss200"] ||
            [lower containsString:@"rgss202"]) {
            return MKXPRGSSGeneration::VX;
        }
        if ([lower containsString:@"rgss1"] || [lower containsString:@"rgss100"] ||
            [lower containsString:@"rgss101"] || [lower containsString:@"rgss102"] ||
            [lower containsString:@"rgss103"]) {
            return MKXPRGSSGeneration::XP;
        }
    }

    NSURL *rootURL = [NSURL fileURLWithPath:root isDirectory:YES];
    NSDirectoryEnumerator *enumerator = [files enumeratorAtURL:rootURL
                                    includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                       options:NSDirectoryEnumerationSkipsHiddenFiles
                                                  errorHandler:nil];
    NSInteger foundXP = 0;
    NSInteger foundVX = 0;
    NSInteger foundVXAce = 0;
    const NSUInteger rootDepth = rootURL.pathComponents.count;
    for (NSURL *file in enumerator) {
        NSUInteger depth = file.pathComponents.count - rootDepth;
        if (depth > 4) {
            [enumerator skipDescendants];
            continue;
        }
        NSString *name = file.lastPathComponent.lowercaseString;
        NSString *ext = file.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"rgss3a"] || [name isEqualToString:@"scripts.rvdata2"]) {
            foundVXAce += 1;
        } else if ([ext isEqualToString:@"rgss2a"] || [name isEqualToString:@"scripts.rvdata"]) {
            foundVX += 1;
        } else if ([ext isEqualToString:@"rgssad"] || [name isEqualToString:@"scripts.rxdata"]) {
            foundXP += 1;
        }
    }
    if (foundVXAce > 0) return MKXPRGSSGeneration::VXAce;
    if (foundVX > 0) return MKXPRGSSGeneration::VX;
    return MKXPRGSSGeneration::XP;
}

static MKXPRubyGeneration RubyGenerationForRGSS(MKXPRGSSGeneration rgss) {
    switch (rgss) {
        case MKXPRGSSGeneration::VXAce: return MKXPRubyGeneration::Ruby19;
        case MKXPRGSSGeneration::XP:
        case MKXPRGSSGeneration::VX:
            return MKXPRubyGeneration::Ruby18;
    }
}

static int RGSSVersionNumber(MKXPRGSSGeneration rgss) {
    switch (rgss) {
        case MKXPRGSSGeneration::XP: return 1;
        case MKXPRGSSGeneration::VX: return 2;
        case MKXPRGSSGeneration::VXAce: return 3;
    }
}

static const char *RGSSGenerationLabel(MKXPRGSSGeneration rgss) {
    switch (rgss) {
        case MKXPRGSSGeneration::XP: return "RGSS1/XP";
        case MKXPRGSSGeneration::VX: return "RGSS2/VX";
        case MKXPRGSSGeneration::VXAce: return "RGSS3/VX Ace";
    }
}

static NSString *ConfigOverlayJSON(const std::vector<std::string> &rtpRoots,
                                   MKXPRGSSGeneration rgss) {
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:rtpRoots.size()];
    for (const std::string &path : rtpRoots) {
        NSString *value = [NSString stringWithUTF8String:path.c_str()];
        if (value != nil) [paths addObject:value];
    }
    NSDictionary *object = @{
        @"RTP": paths,
        @"rgssVersion": @(RGSSVersionNumber(rgss)),
        @"fixedAspectRatio": @YES,
        @"enableHapticFeedback": @NO,
        @"JITEnable": @NO,
        @"YJITEnable": @NO
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

static void MKXPDebugLogMirror(const char *tag, const char *source,
                               const char *message, void *context) {
    auto *session = static_cast<MKXPSession *>(context);
    if (session == nullptr) return;
    const std::string tagValue = tag != nullptr ? tag : "";
    const YumeRuntimeLogLevel level =
        tagValue == "FATAL" || tagValue == "ERROR"
            ? YUME_RUNTIME_LOG_ERROR
            : (tagValue == "WARN" ? YUME_RUNTIME_LOG_WARNING
                                   : YUME_RUNTIME_LOG_INFORMATION);
    std::string detail = "[" + tagValue + "] (" +
        std::string(source != nullptr ? source : "") + ") " +
        std::string(message != nullptr ? message : "");
    std::lock_guard<std::mutex> lock(session->callbackMutex);
    if (session->logCallback != nullptr) {
        session->logCallback(level, "mkxp.engine", detail.c_str(),
                             session->logCallbackContext);
    }
}

static void ConfigureMKXP(MKXPSession *session) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *sharedFonts = [NSString stringWithUTF8String:session->derivedRoot.c_str()];
    sharedFonts = [sharedFonts stringByAppendingPathComponent:@"SharedFonts"];
    [files createDirectoryAtPath:sharedFonts
     withIntermediateDirectories:YES attributes:nil error:nil];

    MKXPSessionConfig config{};
    config.managedConfigDir = session->derivedRoot.c_str();
    config.userDataDirectory = session->saveRoot.c_str();
    config.sharedFontsDirectory = sharedFonts.fileSystemRepresentation;
    config.verticalAlignment = MKXP_VALIGN_CENTER;
    config.postloadEnabled = true;
    config.useInGameKeyboard = false;
    config.joiplayCompat = true;
    config.networkEnabled = false;
    switch (session->ruby) {
        case MKXPRubyGeneration::Ruby18:
            config.rubyVersion = MKXP_RUBY_18;
            config.syntaxTransformMode = MKXP_SYNTAX_TRANSFORM_DISABLED;
            break;
        case MKXPRubyGeneration::Ruby19:
            config.rubyVersion = MKXP_RUBY_19;
            config.syntaxTransformMode = MKXP_SYNTAX_TRANSFORM_DISABLED;
            break;
        case MKXPRubyGeneration::Ruby31:
            config.rubyVersion = MKXP_RUBY_31;
            config.syntaxTransformMode = MKXP_SYNTAX_TRANSFORM_LEGACY;
            break;
    }
    AppendMKXPHostLog(session, "configure.apply-session-config.begin");
    mkxp_applySessionConfig(&config);
    AppendMKXPHostLog(session, "configure.apply-session-config.end");
    mkxp_setLauncherIdentity("yume");
    NSString *overlay = ConfigOverlayJSON(session->rtpRoots, session->rgss);
    AppendMKXPHostLog(session, overlay.UTF8String ?: "configure.overlay=<nil>");
    mkxp_setConfigOverlayJSON(overlay.UTF8String);
    if (!session->logRoot.empty()) {
        NSString *logRoot = [NSString stringWithUTF8String:session->logRoot.c_str()];
        NSString *logPath = [logRoot stringByAppendingPathComponent:@"mkxp-z.log"];
        mkxp_setDebugLogPath(logPath.fileSystemRepresentation);
    }
    mkxp_setDebugLogCallback(MKXPDebugLogMirror, session);
}

static void MKXPPresentCPUFrame(const unsigned char *rgba, int width, int height,
                                void *context) {
    auto *session = static_cast<MKXPSession *>(context);
    if (session == nullptr || session->view == nil || rgba == nullptr ||
        width <= 0 || height <= 0) {
        return;
    }
    YumeMKXPHostView *view = session->view;
    [view enqueueCPUFrameBytes:rgba width:width height:height];
}

static void MKXPFirstFrame(void *context) {
    auto *session = static_cast<MKXPSession *>(context);
    AppendMKXPHostLog(session, "frame.first-frame");
    YumeMKXPHostView *view = session != nullptr ? session->view : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view syncHostMetalLayer];
    });
    MKXPEmit(session, YUME_RUNTIME_EVENT_FIRST_FRAME, "mkxp.first-frame");
}
static void MKXPPaused(void *context) {
    MKXPEmit(static_cast<MKXPSession *>(context), YUME_RUNTIME_EVENT_PAUSED,
             "mkxp.paused");
}
static void MKXPResumed(void *context) {
    MKXPEmit(static_cast<MKXPSession *>(context), YUME_RUNTIME_EVENT_RESUMED,
             "mkxp.resumed");
}
static void MKXPTerminated(void *context) {
    auto *session = static_cast<MKXPSession *>(context);
    if (session != nullptr && !session->stoppedEventSent.exchange(true)) {
        MKXPEmit(session, YUME_RUNTIME_EVENT_STOPPED, "mkxp.stopped");
    }
}
static void MKXPError(const char *message, void *context) {
    auto *session = static_cast<MKXPSession *>(context);
    std::string detail = "engine.error ";
    detail += message != nullptr ? message : "<no detail>";
    AppendMKXPHostLog(session, detail.c_str());
    MKXPEmit(session, YUME_RUNTIME_EVENT_FAILED, detail.c_str());
    mkxp_signalErrorDismissed();
}
static void MKXPInfo(const char *message, void *context) {
    auto *session = static_cast<MKXPSession *>(context);
    std::string detail = "engine.message ";
    detail += message != nullptr ? message : "<no detail>";
    AppendMKXPHostLog(session, detail.c_str());
    MKXPEmit(session, YUME_RUNTIME_EVENT_WARNING, detail.c_str());
    mkxp_signalInfoDismissed();
}

@implementation YumeMKXPHostView {
    MKXPSession *_session;
    BOOL _sdlStarted;
    UIImageView *_frameView;
    CAMetalLayer *_angleLayer;
    BOOL _loggedCPUFrame;
    std::atomic<bool> _cpuFramePending;
    CGSize _lastLoggedBounds;
}

- (instancetype)initWithSession:(MKXPSession *)session {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _session = session;
        _cpuFramePending.store(false);
        self.backgroundColor = UIColor.blackColor;
        self.clipsToBounds = YES;
        _angleLayer = [CAMetalLayer layer];
        _angleLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        _angleLayer.framebufferOnly = NO;
        _angleLayer.opaque = YES;
        _angleLayer.zPosition = 0;
        [self.layer addSublayer:_angleLayer];
        _frameView = [[UIImageView alloc] initWithFrame:self.bounds];
        _frameView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                      UIViewAutoresizingFlexibleHeight;
        _frameView.contentMode = UIViewContentModeScaleAspectFit;
        _frameView.backgroundColor = UIColor.clearColor;
        _frameView.opaque = NO;
        _frameView.hidden = YES;
        _frameView.layer.zPosition = 1;
        [self addSubview:_frameView];
        [self syncHostMetalLayer];
    }
    return self;
}

- (void)syncHostMetalLayer {
    CGFloat scale = self.window.screen.nativeScale ?: UIScreen.mainScreen.nativeScale;
    CGRect bounds = self.bounds;
    CGSize drawable = CGSizeMake(std::max(1.0, bounds.size.width * scale),
                                 std::max(1.0, bounds.size.height * scale));
    _frameView.frame = bounds;
    if (_angleLayer != nil) {
        _angleLayer.frame = bounds;
        _angleLayer.contentsScale = scale;
        _angleLayer.drawableSize = drawable;
        _angleLayer.hidden = NO;
        _angleLayer.zPosition = 0;
    }
    if (_session != nullptr && !CGRectIsEmpty(bounds) &&
        !CGSizeEqualToSize(_lastLoggedBounds, bounds.size)) {
        char line[160];
        std::snprintf(line, sizeof(line),
                      "host.layer class=%s cpuBlit=1 bounds=%.0fx%.0f",
                      NSStringFromClass(self.layer.class).UTF8String ?: "?",
                      bounds.size.width, bounds.size.height);
        AppendMKXPHostLog(_session, line);
        _lastLoggedBounds = bounds.size;
    }
}

- (void)enqueueCPUFrameBytes:(const unsigned char *)rgba
                       width:(int)width
                      height:(int)height {
    MKXPSession *session = _session;
    if (session != nullptr) session->cpuFrameCallbacks.fetch_add(1);
    if (rgba == nullptr || width <= 0 || height <= 0) {
        AppendMKXPHostLog(session, "cpu-frame.invalid");
        return;
    }
    if (_cpuFramePending.exchange(true)) {
        if (session != nullptr) {
            const uint64_t drops = session->cpuFrameDrops.fetch_add(1) + 1;
            if (drops == 1 || drops % 120u == 0u) {
                AppendMKXPHostLog(session, ("cpu-frame.dropped total=" +
                    std::to_string(drops) + " callbacks=" +
                    std::to_string(session->cpuFrameCallbacks.load())).c_str());
            }
        }
        return;
    }
    const size_t byteCount = static_cast<size_t>(width) *
                             static_cast<size_t>(height) * 4u;
    NSData *data = [NSData dataWithBytes:rgba length:byteCount];
    if (data == nil) {
        _cpuFramePending.store(false);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_session != nullptr)
            [self presentCPUFrame:data width:width height:height];
        self->_cpuFramePending.store(false);
    });
}

- (void)presentCPUFrame:(NSData *)data width:(int)width height:(int)height {
    if (data == nil || width <= 0 || height <= 0) return;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider =
        CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef image = CGImageCreate(
        width, height, 8, 32, static_cast<size_t>(width) * 4, colorSpace,
        kCGBitmapByteOrder32Big | kCGImageAlphaLast, provider, nullptr, false,
        kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    if (image == nullptr) return;
    UIImage *uiImage = [UIImage imageWithCGImage:image scale:1.0
                                     orientation:UIImageOrientationUp];
    CGImageRelease(image);
    _frameView.image = uiImage;
    _frameView.hidden = NO;
    const uint64_t presented = _session != nullptr
        ? _session->cpuFramesPresented.fetch_add(1) + 1 : 0;
    if (!_loggedCPUFrame && _session != nullptr) {
        _loggedCPUFrame = YES;
        char line[96];
        std::snprintf(line, sizeof(line), "cpu-frame.first %dx%d", width, height);
        AppendMKXPHostLog(_session, line);
    }
    if (_session != nullptr && presented % 120u == 0u) {
        char line[192];
        std::snprintf(line, sizeof(line),
                      "cpu-frame.stats callbacks=%llu presented=%llu dropped=%llu size=%dx%d pending=%d",
                      static_cast<unsigned long long>(_session->cpuFrameCallbacks.load()),
                      static_cast<unsigned long long>(presented),
                      static_cast<unsigned long long>(_session->cpuFrameDrops.load()),
                      width, height, _cpuFramePending.load() ? 1 : 0);
        AppendMKXPHostLog(_session, line);
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self startEngineIfAttached];
}

- (void)startEngineIfAttached {
    if (_sdlStarted || _session == nullptr || self.window == nil) return;
    if (CGRectIsEmpty(self.bounds)) return;
    _sdlStarted = YES;
    [self syncHostMetalLayer];
    mkxp_setHostNativeLayer((__bridge void *)_angleLayer);
    mkxp_setHostUIWindow((__bridge void *)self.window);
    const CGFloat scale = self.window.screen.nativeScale ?: UIScreen.mainScreen.nativeScale;
    // SDL on iOS treats window size as points. Passing pixels poisons
    // SDL_GetWindowSize so graphics-init reports winSize=devicePixels
    // with backingScale=1.00 and the Metal drawable fills the guest
    // screen instead of the player view.
    const int pointW = static_cast<int>(std::max(1.0, std::round(self.bounds.size.width)));
    const int pointH = static_cast<int>(std::max(1.0, std::round(self.bounds.size.height)));
    mkxp_setHostViewSize(pointW, pointH);
    [self.window makeKeyAndVisible];
    AppendMKXPHostLog(_session, "view.in-window");
    {
        char sizeLine[160];
        std::snprintf(sizeLine, sizeof(sizeLine),
                      "host.view-size points=%dx%d scale=%.2f pixels=%.0fx%.0f",
                      pointW, pointH, (double)scale,
                      std::round(self.bounds.size.width * scale),
                      std::round(self.bounds.size.height * scale));
        AppendMKXPHostLog(_session, sizeLine);
    }
    MKXPSession *session = _session;
    AppendMKXPHostLog(session, "engine.game-path-set.begin");
    mkxp_setGamePath(session->contentRoot.c_str());
    AppendMKXPHostLog(session, "engine.game-path-set.end");
    dispatch_async(dispatch_get_main_queue(), ^{
        AppendMKXPHostLog(session, "engine.main-enter");
        SDL_SetMainReady();
        AppendMKXPHostLog(session, ("engine.sdl-main.begin wasInit=" +
            std::to_string(SDL_WasInit(0)) + " videoDriver=" +
            std::string(SDL_GetCurrentVideoDriver() ?: "<none>")).c_str());
        SDL_iPhoneSetEventPump(SDL_TRUE);
        char executable[] = "yume-mkxp-z";
        char *arguments[] = {executable, nullptr};
        const CFTimeInterval startedAt = CACurrentMediaTime();
        const int mainResult = SDL_main(1, arguments);
        SDL_iPhoneSetEventPump(SDL_FALSE);
        AppendMKXPHostLog(session, ("engine.main-returned result=" +
            std::to_string(mainResult) + " elapsed=" +
            std::to_string(CACurrentMediaTime() - startedAt) + " sdlError=" +
            std::string(SDL_GetError() ?: "<none>") + " callbacks=" +
            std::to_string(session->cpuFrameCallbacks.load()) + " presented=" +
            std::to_string(session->cpuFramesPresented.load()) + " dropped=" +
            std::to_string(session->cpuFrameDrops.load())).c_str());
        session->mainReturned.store(true);
        session->running.store(false);
        [session->view detachSession];
        if (!session->stoppedEventSent.exchange(true)) {
            MKXPEmit(session, YUME_RUNTIME_EVENT_STOPPED, "mkxp.stopped");
        }
        if (session->destroyRequested.load()) {
            session->view = nil;
            delete session;
        }
    });
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self syncHostMetalLayer];
    UIEdgeInsets safe = self.safeAreaInsets;
    mkxp_setSafeAreaInsets(safe.top, safe.bottom, safe.left, safe.right);
    if (!CGRectIsEmpty(self.bounds)) {
        mkxp_setHostViewSize(
            static_cast<int>(std::max(1.0, std::round(self.bounds.size.width))),
            static_cast<int>(std::max(1.0, std::round(self.bounds.size.height))));
    }
    [self startEngineIfAttached];
}

- (void)detachSession {
    mkxp_setDebugLogCallback(nullptr, nullptr);
    mkxp_setCPUFrameCallback(nullptr, nullptr);
    mkxp_setHostNativeLayer(nullptr);
    mkxp_setHostUIWindow(nullptr);
    _session = nullptr;
}

@end

static int32_t MKXPCreate(const YumeRuntimeConfiguration *configuration,
                          YumeRuntimeEventCallback callback, void *context,
                          void **providerSession) {
    if (configuration == nullptr || providerSession == nullptr ||
        configuration->abi_version != YUME_RUNTIME_ABI_VERSION ||
        configuration->content_root == nullptr ||
        configuration->save_root == nullptr ||
        configuration->derived_root == nullptr ||
        configuration->networking_allowed != 0) {
        return -1;
    }
    {
        std::lock_guard<std::mutex> lock(gMKXPClaimMutex);
        if (gMKXPClaimed) return -10;
        gMKXPClaimed = true;
    }
    auto *session = new (std::nothrow) MKXPSession();
    if (session == nullptr) {
        ReleaseMKXPClaimAfterFailedCreation();
        return -2;
    }
    session->contentRoot = configuration->content_root;
    session->saveRoot = configuration->save_root;
    session->derivedRoot = configuration->derived_root;
    session->logRoot = configuration->log_root != nullptr ? configuration->log_root : "";
    for (size_t index = 0; index < configuration->rtp_root_count; ++index) {
        const char *path = configuration->rtp_roots[index];
        if (path != nullptr && path[0] != '\0') session->rtpRoots.emplace_back(path);
    }
    session->callback = callback;
    session->callbackContext = context;
    session->logCallback = configuration->log_callback;
    session->logCallbackContext = configuration->log_callback_context;
    NSString *root = [NSString stringWithUTF8String:session->contentRoot.c_str()];
    session->rgss = DetectRGSSGeneration(root);
    session->ruby = RubyGenerationForRGSS(session->rgss);
    AppendMKXPHostLog(session, "session.created");
    AppendMKXPPathSummary(session, "content", session->contentRoot);
    AppendMKXPPathSummary(session, "save", session->saveRoot);
    AppendMKXPPathSummary(session, "derived", session->derivedRoot);
    AppendMKXPPathSummary(session, "logs", session->logRoot);
    std::string generation = "rgss.generation=";
    generation += RGSSGenerationLabel(session->rgss);
    generation += session->ruby == MKXPRubyGeneration::Ruby19
        ? " ruby=1.9"
        : " ruby=1.8";
    AppendMKXPHostLog(session, generation.c_str());
    MKXPEmit(session, YUME_RUNTIME_EVENT_WARNING, generation.c_str());
    std::string rtpCount = "rtp.mount-count=" + std::to_string(session->rtpRoots.size());
    AppendMKXPHostLog(session, rtpCount.c_str());
    for (const auto &rtpRoot : session->rtpRoots) {
        std::string line = "rtp.mount=" + rtpRoot;
        AppendMKXPHostLog(session, line.c_str());
        AppendMKXPPathSummary(session, "rtp", rtpRoot);
    }
    session->view = [[YumeMKXPHostView alloc] initWithSession:session];
    if (session->view == nil) {
        delete session;
        ReleaseMKXPClaimAfterFailedCreation();
        return -3;
    }
    InstallMKXPCrashBreadcrumb(session);
    *providerSession = session;
    return 0;
}

static int32_t MKXPStart(void *opaque) {
    auto *session = static_cast<MKXPSession *>(opaque);
    if (session == nullptr || session->view == nil || session->running.exchange(true)) return -1;
    AppendMKXPHostLog(session, "start.enter");
    MKXPEmit(session, YUME_RUNTIME_EVENT_WARNING, "mkxp.stage.reset.begin");
    mkxp_resetSessionState();
    AppendMKXPHostLog(session, "start.reset-complete");
    MKXPEmit(session, YUME_RUNTIME_EVENT_WARNING, "mkxp.stage.configure.begin");
    ConfigureMKXP(session);
    AppendMKXPHostLog(session, "start.configured");
    mkxp_setFrameRenderedCallback(MKXPFirstFrame, session);
    mkxp_setCPUFrameCallback(MKXPPresentCPUFrame, session);
    mkxp_setPausedCallback(MKXPPaused, session);
    mkxp_setResumedCallback(MKXPResumed, session);
    mkxp_setEngineTerminatedCallback(MKXPTerminated, session);
    mkxp_setErrorMessageCallback(MKXPError, session);
    mkxp_setInfoMessageCallback(MKXPInfo, session);
    session->everStarted.store(true);
    MKXPEmit(session, YUME_RUNTIME_EVENT_STARTED, "mkxp.started");
    // SDL_main must wait until this view is in the host window so ANGLE
    // can bind the visible CALayer. didMoveToWindow / layoutSubviews start it.
    [session->view startEngineIfAttached];
    return 0;
}

static int32_t MKXPPause(void *opaque) {
    auto *session = static_cast<MKXPSession *>(opaque);
    if (session == nullptr || !session->running.load()) return -1;
    mkxp_requestPause();
    AppendMKXPHostLog(session, "lifecycle.pause-requested");
    return 0;
}
static int32_t MKXPResume(void *opaque) {
    auto *session = static_cast<MKXPSession *>(opaque);
    if (session == nullptr || !session->running.load()) return -1;
    mkxp_requestResume();
    AppendMKXPHostLog(session, "lifecycle.resume-requested");
    return 0;
}

static int MKXPScancode(YumeRuntimeInputAction action) {
    switch (action) {
        case YUME_RUNTIME_INPUT_UP: return MKXP_SCANCODE_UP;
        case YUME_RUNTIME_INPUT_DOWN: return MKXP_SCANCODE_DOWN;
        case YUME_RUNTIME_INPUT_LEFT: return MKXP_SCANCODE_LEFT;
        case YUME_RUNTIME_INPUT_RIGHT: return MKXP_SCANCODE_RIGHT;
        case YUME_RUNTIME_INPUT_CONFIRM: return MKXP_SCANCODE_Z;
        case YUME_RUNTIME_INPUT_CANCEL: return MKXP_SCANCODE_X;
        case YUME_RUNTIME_INPUT_MENU: return MKXP_SCANCODE_ESCAPE;
        case YUME_RUNTIME_INPUT_PAGE_UP: return MKXP_SCANCODE_Q;
        case YUME_RUNTIME_INPUT_PAGE_DOWN: return MKXP_SCANCODE_W;
        case YUME_RUNTIME_INPUT_FAST_FORWARD: return MKXP_SCANCODE_LCTRL;
        case YUME_RUNTIME_INPUT_AUTO_MODE: return MKXP_SCANCODE_A;
        case YUME_RUNTIME_INPUT_HISTORY: return MKXP_SCANCODE_H;
        case YUME_RUNTIME_INPUT_POINTER_PRIMARY: return MKXP_SCANCODE_RETURN;
    }
    return MKXP_SCANCODE_UNKNOWN;
}

static int32_t MKXPSendButton(void *opaque, YumeRuntimeInputAction action,
                              int32_t pressed) {
    auto *session = static_cast<MKXPSession *>(opaque);
    const int key = MKXPScancode(action);
    if (session == nullptr || !session->running.load() || key == MKXP_SCANCODE_UNKNOWN) return -1;
    mkxp_injectKeyEvent(key, pressed != 0 ? 1 : 0);
    const uint64_t sequence = session->inputSequence.fetch_add(1) + 1;
    AppendMKXPHostLog(session, ("input.key sequence=" + std::to_string(sequence) +
        " action=" + std::to_string(static_cast<int>(action)) + " scancode=" +
        std::to_string(key) + " pressed=" + std::to_string(pressed != 0)).c_str());
    return 0;
}
static int32_t MKXPSendPointer(void *opaque, double x, double y, int32_t pressed) {
    auto *session = static_cast<MKXPSession *>(opaque);
    if (session != nullptr) {
        const uint64_t sequence = session->inputSequence.fetch_add(1) + 1;
        char line[192];
        std::snprintf(line, sizeof(line),
                      "input.pointer sequence=%llu ignored=1 x=%.1f y=%.1f pressed=%d",
                      static_cast<unsigned long long>(sequence), x, y,
                      pressed != 0 ? 1 : 0);
        AppendMKXPHostLog(session, line);
    }
    return 0;
}
static int32_t MKXPSendText(void *opaque, const char *text) {
    auto *session = static_cast<MKXPSession *>(opaque);
    if (session == nullptr || !session->running.load() || text == nullptr) return -1;
    mkxp_pushTextInput(text);
    const uint64_t sequence = session->inputSequence.fetch_add(1) + 1;
    AppendMKXPHostLog(session, ("input.text sequence=" + std::to_string(sequence) +
        " bytes=" + std::to_string(std::strlen(text))).c_str());
    return 0;
}
static int32_t MKXPStop(void *opaque) {
    auto *session = static_cast<MKXPSession *>(opaque);
    if (session == nullptr || !session->running.load()) return 0;
    AppendMKXPHostLog(session, ("lifecycle.stop-requested callbacks=" +
        std::to_string(session->cpuFrameCallbacks.load()) + " presented=" +
        std::to_string(session->cpuFramesPresented.load()) + " inputs=" +
        std::to_string(session->inputSequence.load())).c_str());
    mkxp_requestTerminate();
    return 0;
}
static void *MKXPNativeView(void *opaque) {
    auto *session = static_cast<MKXPSession *>(opaque);
    return session != nullptr ? (__bridge void *)session->view : nullptr;
}
static void MKXPDestroy(void *opaque) {
    auto *session = static_cast<MKXPSession *>(opaque);
    if (session == nullptr) return;
    AppendMKXPHostLog(session, "lifecycle.destroy-requested");
    {
        std::lock_guard<std::mutex> lock(session->callbackMutex);
        session->callback = nullptr;
        session->callbackContext = nullptr;
        session->logCallback = nullptr;
        session->logCallbackContext = nullptr;
    }
    mkxp_setDebugLogCallback(nullptr, nullptr);
    session->destroyRequested.store(true);
    (void)MKXPStop(session);
    if (session->mainReturned.load() || !session->running.load()) {
        [session->view detachSession];
        session->view = nil;
        if (!session->everStarted.load()) ReleaseMKXPClaimAfterFailedCreation();
        delete session;
    }
}

static const YumeRuntimeProviderAPI kMKXPProvider = {
    YUME_RUNTIME_ABI_VERSION, "mkxp-z", MKXPCreate, MKXPStart, MKXPPause,
    MKXPResume, MKXPSendButton, MKXPSendPointer, MKXPSendText, MKXPStop,
    MKXPNativeView, MKXPDestroy
};

extern "C" const YumeRuntimeProviderAPI *yume_mkxp_runtime_provider(void) {
    return &kMKXPProvider;
}
