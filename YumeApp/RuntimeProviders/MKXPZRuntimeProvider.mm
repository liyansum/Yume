#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <atomic>
#include <cstdio>
#include <mutex>
#include <new>
#include <string>
#include <unistd.h>
#include <vector>

#include "../../YumeCore/Sources/CYumeRuntimeBridge/include/CYumeRuntimeBridge.h"
#include "../../ThirdParty/MKXPZ/Source/src/app_bridge.h"

extern "C" int SDL_main(int argc, char *argv[]);
extern "C" void SDL_SetMainReady(void);

enum class MKXPRubyGeneration { Ruby18, Ruby19, Ruby31 };

struct MKXPSession;

@interface YumeMKXPHostView : UIView
- (instancetype)initWithSession:(MKXPSession *)session;
- (void)beginEmbedding;
- (BOOL)embedIfAvailable;
- (void)detachSession;
@end

struct MKXPSession {
    std::string contentRoot;
    std::string saveRoot;
    std::string derivedRoot;
    std::string logRoot;
    std::vector<std::string> rtpRoots;
    MKXPRubyGeneration ruby = MKXPRubyGeneration::Ruby31;
    YumeRuntimeEventCallback callback = nullptr;
    void *callbackContext = nullptr;
    std::mutex callbackMutex;
    std::mutex logMutex;
    __strong YumeMKXPHostView *view = nil;
    std::atomic<bool> running{false};
    std::atomic<bool> everStarted{false};
    std::atomic<bool> mainReturned{false};
    std::atomic<bool> destroyRequested{false};
    std::atomic<bool> stoppedEventSent{false};
};

static void AppendMKXPHostLog(MKXPSession *session, const char *message) {
    if (session == nullptr || session->logRoot.empty()) return;
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
        NSString *line = [NSString stringWithFormat:@"%.3f %@\n",
                          NSDate.date.timeIntervalSince1970, detail];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (data != nil) fwrite(data.bytes, 1, data.length, file);
        fflush(file);
        fsync(fileno(file));
        fclose(file);
    }
}

static std::mutex gMKXPClaimMutex;
static bool gMKXPClaimed = false;

static void ReleaseMKXPClaimAfterFailedCreation(void) {
    std::lock_guard<std::mutex> lock(gMKXPClaimMutex);
    gMKXPClaimed = false;
}

static void MKXPEmit(MKXPSession *session, YumeRuntimeEventKind kind,
                     const char *code) {
    if (session == nullptr) return;
    YumeRuntimeEventCallback callback = nullptr;
    void *context = nullptr;
    {
        std::lock_guard<std::mutex> lock(session->callbackMutex);
        callback = session->callback;
        context = session->callbackContext;
    }
    if (callback != nullptr) callback(kind, code != nullptr ? code : "", context);
}

static MKXPRubyGeneration DetectRubyGeneration(NSString *root) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSArray<NSString *> *modernRuntimeMarkers = @[
        @"ruby300.dll", @"ruby310.dll", @"x64-msvcrt-ruby300.dll",
        @"x64-msvcrt-ruby310.dll"
    ];
    for (NSString *marker in modernRuntimeMarkers) {
        if ([files fileExistsAtPath:[root stringByAppendingPathComponent:marker]]) {
            return MKXPRubyGeneration::Ruby31;
        }
    }
    bool hasVXAceArchive = false;
    for (NSString *entry in [files contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
        if ([[entry.pathExtension lowercaseString] isEqualToString:@"rgss3a"]) {
            hasVXAceArchive = true;
            break;
        }
    }
    if (hasVXAceArchive ||
        [files fileExistsAtPath:[root stringByAppendingPathComponent:@"Data/Scripts.rvdata2"]] ||
        [files fileExistsAtPath:[root stringByAppendingPathComponent:@"data/scripts.rvdata2"]]) {
        return MKXPRubyGeneration::Ruby19;
    }
    return MKXPRubyGeneration::Ruby18;
}

static NSString *ConfigOverlayJSON(const std::vector<std::string> &rtpRoots) {
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:rtpRoots.size()];
    for (const std::string &path : rtpRoots) {
        NSString *value = [NSString stringWithUTF8String:path.c_str()];
        if (value != nil) [paths addObject:value];
    }
    NSDictionary *object = @{
        @"RTP": paths,
        @"fixedAspectRatio": @YES,
        @"enableHapticFeedback": @NO
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
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
    mkxp_applySessionConfig(&config);
    mkxp_setLauncherIdentity("yume");
    NSString *overlay = ConfigOverlayJSON(session->rtpRoots);
    mkxp_setConfigOverlayJSON(overlay.UTF8String);
    if (!session->logRoot.empty()) {
        NSString *logRoot = [NSString stringWithUTF8String:session->logRoot.c_str()];
        NSString *logPath = [logRoot stringByAppendingPathComponent:@"mkxp-z.log"];
        mkxp_setDebugLogPath(logPath.fileSystemRepresentation);
    }
}

static void MKXPFirstFrame(void *context) {
    auto *session = static_cast<MKXPSession *>(context);
    AppendMKXPHostLog(session, "frame.first-frame");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (session != nullptr && session->view != nil) {
            [session->view embedIfAvailable];
        }
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
    CADisplayLink *_embeddingLink;
    __weak UIView *_embeddedGameView;
    __weak UIWindow *_sdlWindow;
}

- (instancetype)initWithSession:(MKXPSession *)session {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _session = session;
        self.backgroundColor = UIColor.blackColor;
        self.clipsToBounds = YES;
    }
    return self;
}

- (void)beginEmbedding {
    if (_embeddingLink != nil) return;
    _embeddingLink = [CADisplayLink displayLinkWithTarget:self
                                                 selector:@selector(pollForSDLView:)];
    [_embeddingLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)pollForSDLView:(CADisplayLink *)link {
    if (_embeddedGameView != nil) {
        _embeddedGameView.frame = self.bounds;
        return;
    }
    if ([self embedIfAvailable]) link.paused = YES;
}

- (BOOL)embedIfAvailable {
    if (_embeddedGameView != nil) return YES;
    void *windowPointer = mkxp_getSDLUIKitWindow();
    if (windowPointer == nullptr) return NO;
    UIWindow *window = (__bridge UIWindow *)windowPointer;
    UIView *gameView = window.rootViewController.view;
    if (gameView == nil) return NO;
    [gameView removeFromSuperview];
    gameView.frame = self.bounds;
    gameView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
    [self insertSubview:gameView atIndex:0];
    window.hidden = YES;
    _embeddedGameView = gameView;
    _sdlWindow = window;
    AppendMKXPHostLog(_session, "view.embedded");
    return YES;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _embeddedGameView.frame = self.bounds;
    UIEdgeInsets safe = self.safeAreaInsets;
    mkxp_setSafeAreaInsets(safe.top, safe.bottom, safe.left, safe.right);
}

- (void)restoreSDLView {
    [_embeddingLink invalidate];
    _embeddingLink = nil;
    UIView *gameView = _embeddedGameView;
    UIWindow *window = _sdlWindow;
    _embeddedGameView = nil;
    _sdlWindow = nil;
    if (gameView == nil || window == nil) return;
    [gameView removeFromSuperview];
    gameView.frame = window.bounds;
    gameView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
    [window addSubview:gameView];
    window.hidden = NO;
}

- (void)detachSession {
    [self restoreSDLView];
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
    NSString *root = [NSString stringWithUTF8String:session->contentRoot.c_str()];
    session->ruby = DetectRubyGeneration(root);
    AppendMKXPHostLog(session, "session.created");
    AppendMKXPHostLog(session, session->ruby == MKXPRubyGeneration::Ruby19
        ? "ruby.detected=1.9 (RGSS3/VX Ace)"
        : session->ruby == MKXPRubyGeneration::Ruby18
            ? "ruby.detected=1.8 (RGSS1/2)"
            : "ruby.detected=3.1");
    std::string rtpCount = "rtp.mount-count=" + std::to_string(session->rtpRoots.size());
    AppendMKXPHostLog(session, rtpCount.c_str());
    for (const auto &rtpRoot : session->rtpRoots) {
        std::string line = "rtp.mount=" + rtpRoot;
        AppendMKXPHostLog(session, line.c_str());
    }
    session->view = [[YumeMKXPHostView alloc] initWithSession:session];
    if (session->view == nil) {
        delete session;
        ReleaseMKXPClaimAfterFailedCreation();
        return -3;
    }
    *providerSession = session;
    return 0;
}

static int32_t MKXPStart(void *opaque) {
    auto *session = static_cast<MKXPSession *>(opaque);
    if (session == nullptr || session->view == nil || session->running.exchange(true)) return -1;
    mkxp_resetSessionState();
    AppendMKXPHostLog(session, "start.reset-complete");
    ConfigureMKXP(session);
    AppendMKXPHostLog(session, "start.configured");
    mkxp_setFrameRenderedCallback(MKXPFirstFrame, session);
    mkxp_setPausedCallback(MKXPPaused, session);
    mkxp_setResumedCallback(MKXPResumed, session);
    mkxp_setEngineTerminatedCallback(MKXPTerminated, session);
    mkxp_setErrorMessageCallback(MKXPError, session);
    mkxp_setInfoMessageCallback(MKXPInfo, session);
    mkxp_setGamePath(session->contentRoot.c_str());
    AppendMKXPHostLog(session, "start.game-path-set");
    session->everStarted.store(true);
    [session->view beginEmbedding];
    MKXPEmit(session, YUME_RUNTIME_EVENT_STARTED, "mkxp.started");

    dispatch_async(dispatch_get_main_queue(), ^{
        SDL_SetMainReady();
        char executable[] = "yume-mkxp-z";
        char *arguments[] = {executable, nullptr};
        (void)SDL_main(1, arguments);
        AppendMKXPHostLog(session, "engine.main-returned");
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
    return 0;
}

static int32_t MKXPPause(void *opaque) {
    auto *session = static_cast<MKXPSession *>(opaque);
    if (session == nullptr || !session->running.load()) return -1;
    mkxp_requestPause();
    return 0;
}
static int32_t MKXPResume(void *opaque) {
    auto *session = static_cast<MKXPSession *>(opaque);
    if (session == nullptr || !session->running.load()) return -1;
    mkxp_requestResume();
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
    return 0;
}
static int32_t MKXPSendPointer(void *, double, double, int32_t) {
    return 0;
}
static int32_t MKXPSendText(void *opaque, const char *text) {
    auto *session = static_cast<MKXPSession *>(opaque);
    if (session == nullptr || !session->running.load() || text == nullptr) return -1;
    mkxp_pushTextInput(text);
    return 0;
}
static int32_t MKXPStop(void *opaque) {
    auto *session = static_cast<MKXPSession *>(opaque);
    if (session == nullptr || !session->running.load()) return 0;
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
    {
        std::lock_guard<std::mutex> lock(session->callbackMutex);
        session->callback = nullptr;
        session->callbackContext = nullptr;
    }
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
