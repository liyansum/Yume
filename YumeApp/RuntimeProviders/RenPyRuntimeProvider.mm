#define GLES_SILENCE_DEPRECATION 1
#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <QuartzCore/CAEAGLLayer.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <new>
#include <signal.h>
#include <string>
#include <unistd.h>

#include <SDL.h>
#include <SDL_syswm.h>

#include "../../YumeCore/Sources/CYumeRuntimeBridge/include/CYumeRuntimeBridge.h"

extern "C" int yume_renpy_modern_main(int argc, char **argv);
extern "C" int yume_renpy_legacy_main(int argc, char **argv);

enum class RenPyGeneration { Modern, Legacy };
struct RenPySession;

@interface YumeRenPyHostView : UIView
- (instancetype)initWithSession:(RenPySession *)session;
- (void)beginEmbedding;
- (void)startEngineIfAttached;
- (void)detachSession;
@end

struct RenPySession {
    std::string contentRoot;
    std::string saveRoot;
    std::string logRoot;
    std::string launcherPath;
    std::string runtimeBasePath;
    RenPyGeneration generation = RenPyGeneration::Modern;
    YumeRuntimeEventCallback callback = nullptr;
    void *callbackContext = nullptr;
    std::mutex callbackMutex;
    std::mutex logMutex;
    __strong YumeRenPyHostView *view = nil;
    std::atomic<bool> running{false};
    std::atomic<bool> everStarted{false};
    std::atomic<bool> mainReturned{false};
    std::atomic<bool> destroyRequested{false};
    std::atomic<bool> stoppedEventSent{false};
};

static void AppendRenPyHostLog(RenPySession *session, const char *message) {
    if (session == nullptr || session->logRoot.empty()) return;
    std::lock_guard<std::mutex> lock(session->logMutex);
    @autoreleasepool {
        NSString *root = [NSString stringWithUTF8String:session->logRoot.c_str()];
        if (root == nil) return;
        [[NSFileManager defaultManager] createDirectoryAtPath:root
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *path = [root stringByAppendingPathComponent:@"renpy-host.log"];
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

static std::mutex gRenPyClaimMutex;
static bool gRenPyClaimed = false;
static volatile sig_atomic_t gRenPyCrashLogFD = -1;

static void RenPyCrashSignalHandler(int signalNumber) {
    const int fd = static_cast<int>(gRenPyCrashLogFD);
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

static void InstallRenPyCrashBreadcrumb(RenPySession *session) {
    if (session == nullptr || session->logRoot.empty()) return;
    @autoreleasepool {
        NSString *root = [NSString stringWithUTF8String:session->logRoot.c_str()];
        if (root.length == 0) return;
        [[NSFileManager defaultManager] createDirectoryAtPath:root
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *path = [root stringByAppendingPathComponent:@"renpy-crash.log"];
        const int fd = open(path.fileSystemRepresentation,
                            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
        if (fd < 0) return;
        const int previous = static_cast<int>(gRenPyCrashLogFD);
        gRenPyCrashLogFD = fd;
        if (previous >= 0) close(previous);
        const int signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP};
        for (const int signalNumber : signals) {
            struct sigaction action {};
            action.sa_handler = RenPyCrashSignalHandler;
            sigemptyset(&action.sa_mask);
            action.sa_flags = SA_RESETHAND;
            (void)sigaction(signalNumber, &action, nullptr);
        }
    }
    AppendRenPyHostLog(session, "crash-handler.install.end");
}

static void RedirectRenPyOutput(RenPySession *session) {
    if (session == nullptr || session->logRoot.empty()) return;
    @autoreleasepool {
        NSString *root = [NSString stringWithUTF8String:session->logRoot.c_str()];
        if (root.length == 0) return;
        [[NSFileManager defaultManager] createDirectoryAtPath:root
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *path = [root stringByAppendingPathComponent:@"renpy-python.log"];
        FILE *stream = fopen(path.fileSystemRepresentation, "ab");
        if (stream == nullptr) return;
        const int fd = fileno(stream);
        (void)dup2(fd, STDOUT_FILENO);
        (void)dup2(fd, STDERR_FILENO);
        setvbuf(stdout, nullptr, _IONBF, 0);
        setvbuf(stderr, nullptr, _IONBF, 0);
    }
}

static void ReleaseRenPyClaim(void) {
    std::lock_guard<std::mutex> lock(gRenPyClaimMutex);
    gRenPyClaimed = false;
}

static void RenPyEmit(RenPySession *session, YumeRuntimeEventKind kind,
                      const char *code) {
    if (session == nullptr) return;
    YumeRuntimeEventCallback callback = nullptr;
    void *context = nullptr;
    {
        std::lock_guard<std::mutex> lock(session->callbackMutex);
        callback = session->callback;
        context = session->callbackContext;
    }
    if (callback != nullptr) callback(kind, code, context);
}

static RenPyGeneration DetectRenPyGeneration(NSString *root) {
    if (const char *override = std::getenv("YUME_RENPY_GENERATION")) {
        NSString *value = [[NSString stringWithUTF8String:override] lowercaseString];
        if ([value isEqualToString:@"modern"] || [value isEqualToString:@"8"]) {
            return RenPyGeneration::Modern;
        }
        if ([value isEqualToString:@"legacy"] || [value isEqualToString:@"7"]) {
            return RenPyGeneration::Legacy;
        }
    }
    NSFileManager *files = NSFileManager.defaultManager;
    NSArray<NSString *> *versionFiles = @[
        @"game/script_version.txt", @"script_version.txt",
        @"renpy/vc_version.py", @"game/renpy/vc_version.py"
    ];
    for (NSString *relative in versionFiles) {
        NSString *path = [root stringByAppendingPathComponent:relative];
        NSString *value = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
        if (value.length == 0) continue;
        if ([value containsString:@"(8,"] || [value containsString:@"version = 8"]) {
            return RenPyGeneration::Modern;
        }
        if ([value containsString:@"(6,"] || [value containsString:@"(7,"] ||
            [value containsString:@"version = 7"] || [value containsString:@"version = 6"]) {
            return RenPyGeneration::Legacy;
        }
    }
    NSArray<NSString *> *modernMarkers = @[
        @"game/cache/bytecode-39.rpyb", @"game/cache/bytecode-312.rpyb",
        @"lib/python3.9", @"lib/python3.10", @"lib/python3.11", @"lib/python3.12"
    ];
    for (NSString *relative in modernMarkers) {
        if ([files fileExistsAtPath:[root stringByAppendingPathComponent:relative]]) {
            return RenPyGeneration::Modern;
        }
    }
    NSArray<NSString *> *legacyMarkers = @[
        @"game/cache/bytecode-27.rpyb", @"lib/python2.7"
    ];
    for (NSString *relative in legacyMarkers) {
        if ([files fileExistsAtPath:[root stringByAppendingPathComponent:relative]]) {
            return RenPyGeneration::Legacy;
        }
    }
    return RenPyGeneration::Modern;
}

static void PushSimpleEvent(Uint32 type) {
    SDL_Event event{};
    event.type = type;
    (void)SDL_PushEvent(&event);
}

static __weak UIWindow *gYumeHostWindow;
static __weak UIView *gYumeHostView;

extern "C" void *YumeGetHostUIWindow(void) {
    return (__bridge void *)gYumeHostWindow;
}

extern "C" void *YumeGetHostGameView(void) {
    return (__bridge void *)gYumeHostView;
}

static UIView *YumeViewOwningLayer(CALayer *layer) {
    if (layer == nil) return nil;
    id delegate = layer.delegate;
    if ([delegate isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)delegate;
        if (view.layer == layer) return view;
    }
    return nil;
}

static void YumeAttachEAGLDrawableToHost(id drawable) {
    if (drawable == nil || ![drawable isKindOfClass:[CALayer class]]) return;
    CALayer *layer = (CALayer *)drawable;
    UIView *host = (__bridge UIView *)YumeGetHostGameView();
    if (host == nil || host.window == nil || CGRectIsEmpty(host.bounds)) return;
    UIView *glView = YumeViewOwningLayer(layer);
    if (glView == nil || glView == host) return;
    if (glView.superview == host) {
        glView.frame = host.bounds;
        return;
    }
    glView.frame = host.bounds;
    glView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                              UIViewAutoresizingFlexibleHeight;
    [host insertSubview:glView atIndex:0];
    [host layoutIfNeeded];
    [host.window layoutIfNeeded];
    std::fprintf(stdout, "yume.eagl-host-bound host=%p view=%p bounds=%.0fx%.0f\n",
                 (__bridge void *)host, (__bridge void *)glView,
                 host.bounds.size.width, host.bounds.size.height);
    std::fflush(stdout);
}

static BOOL (*YumeEAGLRenderbufferStorageIMP)(id, SEL, GLenum, id);

static BOOL YumeEAGLRenderbufferStorageHook(id self, SEL selector, GLenum target,
                                            id drawable) {
    YumeAttachEAGLDrawableToHost(drawable);
    [CATransaction flush];
    if (YumeEAGLRenderbufferStorageIMP == nullptr) return NO;
    BOOL ok = YumeEAGLRenderbufferStorageIMP(self, selector, target, drawable);
    std::fprintf(stdout, "yume.eagl-storage ok=%d\n", ok ? 1 : 0);
    std::fflush(stdout);
    return ok;
}

static void YumeInstallEAGLDrawableHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method method = class_getInstanceMethod(
            [EAGLContext class], @selector(renderbufferStorage:fromDrawable:));
        if (method == nullptr) return;
        YumeEAGLRenderbufferStorageIMP =
            (BOOL (*)(id, SEL, GLenum, id))method_getImplementation(method);
        method_setImplementation(method, (IMP)YumeEAGLRenderbufferStorageHook);
    });
}

static UIWindow *FindSDLUIKitWindow(void) {
    SDL_Window *window = SDL_GetKeyboardFocus();
    if (window == nullptr) window = SDL_GetMouseFocus();
    if (window == nullptr) window = SDL_GetGrabbedWindow();
    for (Uint32 id = 1; id <= 256 && window == nullptr; ++id) {
        window = SDL_GetWindowFromID(id);
    }
    if (window == nullptr) return nil;

    SDL_SysWMinfo information{};
    SDL_VERSION(&information.version);
    if (!SDL_GetWindowWMInfo(window, &information)) return nil;
    return information.info.uikit.window;
}

@implementation YumeRenPyHostView {
    RenPySession *_session;
    CADisplayLink *_embeddingLink;
    __weak UIView *_embeddedGameView;
    __weak UIWindow *_sdlWindow;
    BOOL _sdlStarted;
}

- (instancetype)initWithSession:(RenPySession *)session {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _session = session;
        self.backgroundColor = UIColor.blackColor;
        self.clipsToBounds = YES;
    }
    return self;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self startEngineIfAttached];
}

- (void)startEngineIfAttached {
    if (_sdlStarted || _session == nullptr || self.window == nil) return;
    if (CGRectIsEmpty(self.bounds)) return;
    _sdlStarted = YES;
    gYumeHostWindow = self.window;
    gYumeHostView = self;
    [self.window makeKeyAndVisible];
    AppendRenPyHostLog(_session, "view.in-window");
    AppendRenPyHostLog(_session, "view.host-bound");
    RenPySession *session = _session;
    std::string executable = session->launcherPath;
    dispatch_async(dispatch_get_main_queue(), ^{
        AppendRenPyHostLog(session, "engine.sdl-main.begin");
        // Never chdir into the imported game. Windows/mac exports ship
        // lib/python2.7/iosupport.py that uses pyobjus against macOS
        // Foundation paths and abort on iOS.
        if (!session->runtimeBasePath.empty()) {
            (void)chdir(session->runtimeBasePath.c_str());
            AppendRenPyHostLog(session, ("engine.chdir=" + session->runtimeBasePath).c_str());
        }
        // LiveContainer cannot create EAGL drawables. Do not force GLES;
        // Ren'Py is launched with RENPY_RENDERER=sw.
        SDL_SetHint(SDL_HINT_RENDER_DRIVER, "software");
        SDL_SetHint(SDL_HINT_FRAMEBUFFER_ACCELERATION, "0");
        SDL_SetHint(SDL_HINT_VIDEO_MINIMIZE_ON_FOCUS_LOSS, "0");
        SDL_SetMainReady();
        std::string executableArgument = executable;
        std::string gameRoot = session->contentRoot;
        AppendRenPyHostLog(session, ("engine.basedir=" + gameRoot).c_str());
        AppendRenPyHostLog(session, ("engine.argv0=" + executableArgument).c_str());
        std::fprintf(stdout, "yume.python-redirect-ready argv0=%s basedir=%s\n",
                     executableArgument.c_str(), gameRoot.c_str());
        std::fflush(stdout);
        std::fflush(stderr);
        // Official launcher_main preinitializes isolated Python from this
        // argv. A "--basedir" flag is treated as an unknown interpreter
        // option and exits 1 with no traceback. Ren'Py accepts the game
        // root as a positional basedir after it injects main.py.
        char *arguments[] = {
            executableArgument.data(),
            gameRoot.data(),
            nullptr
        };
        int result = session->generation == RenPyGeneration::Modern
            ? yume_renpy_modern_main(2, arguments)
            : yume_renpy_legacy_main(2, arguments);
        std::string resultLine = "engine.main-returned result=" + std::to_string(result);
        AppendRenPyHostLog(session, resultLine.c_str());
        session->mainReturned.store(true);
        session->running.store(false);
        [session->view detachSession];
        if (result != 0) RenPyEmit(session, YUME_RUNTIME_EVENT_FAILED, "renpy.engine-error");
        if (!session->stoppedEventSent.exchange(true)) {
            RenPyEmit(session, YUME_RUNTIME_EVENT_STOPPED, "renpy.stopped");
        }
        if (session->destroyRequested.load()) {
            session->view = nil;
            delete session;
        }
    });
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
    UIWindow *window = FindSDLUIKitWindow();
    if (window == nil) return;
    UIView *gameView = window.rootViewController.view;
    if (gameView == nil) return;
    if (window == self.window && gameView == window.rootViewController.view) {
        AppendRenPyHostLog(_session, "view.embed-skip-host-window");
        link.paused = YES;
        RenPyEmit(_session, YUME_RUNTIME_EVENT_FIRST_FRAME, "renpy.first-frame");
        return;
    }
    [gameView removeFromSuperview];
    gameView.frame = self.bounds;
    gameView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
    [self insertSubview:gameView atIndex:0];
    window.userInteractionEnabled = NO;
    window.windowLevel = UIWindowLevelNormal - 1;
    window.alpha = 0;
    window.hidden = NO;
    if (self.window != nil) [self.window makeKeyAndVisible];
    _embeddedGameView = gameView;
    _sdlWindow = window;
    link.paused = YES;
    AppendRenPyHostLog(_session, "view.embedded first-frame");
    RenPyEmit(_session, YUME_RUNTIME_EVENT_FIRST_FRAME, "renpy.first-frame");
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _embeddedGameView.frame = self.bounds;
    [self startEngineIfAttached];
}

- (void)detachSession {
    [_embeddingLink invalidate];
    _embeddingLink = nil;
    UIView *gameView = _embeddedGameView;
    UIWindow *window = _sdlWindow;
    _embeddedGameView = nil;
    _sdlWindow = nil;
    gYumeHostWindow = nil;
    gYumeHostView = nil;
    if (gameView != nil && window != nil) {
        [gameView removeFromSuperview];
        gameView.frame = window.bounds;
        [window addSubview:gameView];
        window.alpha = 1;
        window.userInteractionEnabled = YES;
        window.hidden = NO;
    }
    _session = nullptr;
}
@end

static int32_t RenPyCreate(const YumeRuntimeConfiguration *configuration,
                           YumeRuntimeEventCallback callback, void *context,
                           void **providerSession) {
    if (configuration == nullptr || providerSession == nullptr ||
        configuration->abi_version != YUME_RUNTIME_ABI_VERSION ||
        configuration->content_root == nullptr ||
        configuration->save_root == nullptr ||
        configuration->networking_allowed != 0) return -1;
    {
        std::lock_guard<std::mutex> lock(gRenPyClaimMutex);
        if (gRenPyClaimed) return -10;
        gRenPyClaimed = true;
    }
    auto *session = new (std::nothrow) RenPySession();
    if (session == nullptr) {
        ReleaseRenPyClaim();
        return -2;
    }
    session->contentRoot = configuration->content_root;
    session->saveRoot = configuration->save_root;
    session->logRoot = configuration->log_root != nullptr ? configuration->log_root : "";
    session->callback = callback;
    session->callbackContext = context;
    NSString *root = [NSString stringWithUTF8String:session->contentRoot.c_str()];
    session->generation = DetectRenPyGeneration(root);
    AppendRenPyHostLog(session, session->generation == RenPyGeneration::Modern
        ? "session.created generation=modern"
        : "session.created generation=legacy");
    session->view = [[YumeRenPyHostView alloc] initWithSession:session];
    if (session->view == nil) {
        delete session;
        ReleaseRenPyClaim();
        return -3;
    }
    *providerSession = session;
    return 0;
}

static int32_t RenPyStart(void *opaque) {
    auto *session = static_cast<RenPySession *>(opaque);
    if (session == nullptr || session->view == nil || session->running.exchange(true)) return -1;
    NSString *generation = session->generation == RenPyGeneration::Modern
        ? @"RenPyModern" : @"RenPyLegacy";
    NSURL *runtimeRoot = [[NSBundle mainBundle].resourceURL
        URLByAppendingPathComponent:@"Runtimes" isDirectory:YES];
    runtimeRoot = [runtimeRoot URLByAppendingPathComponent:generation isDirectory:YES];
    NSString *generationRoot = [runtimeRoot path];
    NSString *base = [generationRoot stringByAppendingPathComponent:@"base"];
    if (![[NSFileManager defaultManager]
            fileExistsAtPath:[base stringByAppendingPathComponent:@"main.py"]]) {
        session->running.store(false);
        AppendRenPyHostLog(session, "start.failed resources-missing");
        RenPyEmit(session, YUME_RUNTIME_EVENT_FAILED, "renpy.resources-missing");
        return -2;
    }

    setenv("RENPY_PATH_TO_SAVES", session->saveRoot.c_str(), 1);
    setenv("RENPY_SEARCHPATH", session->contentRoot.c_str(), 1);
    setenv("YUME_RENPY_GAMEDIR", session->contentRoot.c_str(), 1);
    setenv("RENPY_LOG_TO_STDOUT", "1", 1);
    // LiveContainer does not give EAGL backing to extra SDL windows.
    // Prefer Ren'Py's software renderer; GLES still tries the host
    // CAEAGLLayer if the game forces gl/gles.
    setenv("RENPY_RENDERER", "sw", 1);
    setenv("PYTHONHOME", base.UTF8String ?: "", 1);
    AppendRenPyHostLog(session, "start.renderer=sw");
    InstallRenPyCrashBreadcrumb(session);
    RedirectRenPyOutput(session);
    AppendRenPyHostLog(session, "start.environment-configured");
    session->everStarted.store(true);
    // chdir to the generation root (the directory that contains base/),
    // never into the imported Windows tree. launcher_main on iOS looks
    // for python home at dirname(argv[0])/base.
    session->runtimeBasePath = generationRoot.UTF8String ?: "";
    session->launcherPath = [generationRoot stringByAppendingPathComponent:@"main"].UTF8String;
    [session->view beginEmbedding];
    RenPyEmit(session, YUME_RUNTIME_EVENT_STARTED,
              session->generation == RenPyGeneration::Modern
                  ? "renpy.modern-started" : "renpy.legacy-started");
    [session->view startEngineIfAttached];
    return 0;
}

static int32_t RenPyPause(void *opaque) {
    auto *session = static_cast<RenPySession *>(opaque);
    if (session == nullptr || !session->running.load()) return -1;
    PushSimpleEvent(SDL_APP_WILLENTERBACKGROUND);
    PushSimpleEvent(SDL_APP_DIDENTERBACKGROUND);
    AppendRenPyHostLog(session, "lifecycle.paused");
    RenPyEmit(session, YUME_RUNTIME_EVENT_PAUSED, "renpy.paused");
    return 0;
}
static int32_t RenPyResume(void *opaque) {
    auto *session = static_cast<RenPySession *>(opaque);
    if (session == nullptr || !session->running.load()) return -1;
    PushSimpleEvent(SDL_APP_WILLENTERFOREGROUND);
    PushSimpleEvent(SDL_APP_DIDENTERFOREGROUND);
    AppendRenPyHostLog(session, "lifecycle.resumed");
    RenPyEmit(session, YUME_RUNTIME_EVENT_RESUMED, "renpy.resumed");
    return 0;
}

static SDL_Scancode RenPyScancode(YumeRuntimeInputAction action) {
    switch (action) {
        case YUME_RUNTIME_INPUT_UP: return SDL_SCANCODE_UP;
        case YUME_RUNTIME_INPUT_DOWN: return SDL_SCANCODE_DOWN;
        case YUME_RUNTIME_INPUT_LEFT: return SDL_SCANCODE_LEFT;
        case YUME_RUNTIME_INPUT_RIGHT: return SDL_SCANCODE_RIGHT;
        case YUME_RUNTIME_INPUT_CONFIRM: return SDL_SCANCODE_RETURN;
        case YUME_RUNTIME_INPUT_CANCEL: return SDL_SCANCODE_ESCAPE;
        case YUME_RUNTIME_INPUT_MENU: return SDL_SCANCODE_ESCAPE;
        case YUME_RUNTIME_INPUT_PAGE_UP: return SDL_SCANCODE_PAGEUP;
        case YUME_RUNTIME_INPUT_PAGE_DOWN: return SDL_SCANCODE_PAGEDOWN;
        case YUME_RUNTIME_INPUT_FAST_FORWARD: return SDL_SCANCODE_LCTRL;
        case YUME_RUNTIME_INPUT_AUTO_MODE: return SDL_SCANCODE_A;
        case YUME_RUNTIME_INPUT_HISTORY: return SDL_SCANCODE_H;
        case YUME_RUNTIME_INPUT_POINTER_PRIMARY: return SDL_SCANCODE_RETURN;
    }
    return SDL_SCANCODE_UNKNOWN;
}

static SDL_Keycode RenPyKeycode(YumeRuntimeInputAction action) {
    switch (action) {
        case YUME_RUNTIME_INPUT_UP: return SDLK_UP;
        case YUME_RUNTIME_INPUT_DOWN: return SDLK_DOWN;
        case YUME_RUNTIME_INPUT_LEFT: return SDLK_LEFT;
        case YUME_RUNTIME_INPUT_RIGHT: return SDLK_RIGHT;
        case YUME_RUNTIME_INPUT_CONFIRM:
        case YUME_RUNTIME_INPUT_POINTER_PRIMARY: return SDLK_RETURN;
        case YUME_RUNTIME_INPUT_CANCEL:
        case YUME_RUNTIME_INPUT_MENU: return SDLK_ESCAPE;
        case YUME_RUNTIME_INPUT_PAGE_UP: return SDLK_PAGEUP;
        case YUME_RUNTIME_INPUT_PAGE_DOWN: return SDLK_PAGEDOWN;
        case YUME_RUNTIME_INPUT_FAST_FORWARD: return SDLK_LCTRL;
        case YUME_RUNTIME_INPUT_AUTO_MODE: return SDLK_a;
        case YUME_RUNTIME_INPUT_HISTORY: return SDLK_h;
    }
    return SDLK_UNKNOWN;
}

static int32_t RenPySendButton(void *opaque, YumeRuntimeInputAction action,
                               int32_t pressed) {
    auto *session = static_cast<RenPySession *>(opaque);
    const SDL_Scancode scancode = RenPyScancode(action);
    if (session == nullptr || !session->running.load() ||
        scancode == SDL_SCANCODE_UNKNOWN) return -1;
    SDL_Event event{};
    event.key.type = pressed ? SDL_KEYDOWN : SDL_KEYUP;
    event.key.state = pressed ? 1 : 0;
    event.key.keysym.scancode = scancode;
    event.key.keysym.sym = RenPyKeycode(action);
    return SDL_PushEvent(&event) >= 0 ? 0 : -2;
}

static int32_t RenPySendPointer(void *opaque, double x, double y, int32_t pressed) {
    auto *session = static_cast<RenPySession *>(opaque);
    if (session == nullptr || !session->running.load()) return -1;
    SDL_Event motion{};
    motion.motion.type = SDL_MOUSEMOTION;
    motion.motion.x = static_cast<int32_t>(x);
    motion.motion.y = static_cast<int32_t>(y);
    (void)SDL_PushEvent(&motion);
    SDL_Event button{};
    button.button.type = pressed ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
    button.button.button = 1;
    button.button.state = pressed ? 1 : 0;
    button.button.x = static_cast<int32_t>(x);
    button.button.y = static_cast<int32_t>(y);
    return SDL_PushEvent(&button) >= 0 ? 0 : -2;
}

static int32_t RenPySendText(void *opaque, const char *text) {
    auto *session = static_cast<RenPySession *>(opaque);
    if (session == nullptr || !session->running.load() || text == nullptr) return -1;
    SDL_Event event{};
    event.text.type = SDL_TEXTINPUT;
    std::strncpy(event.text.text, text, sizeof(event.text.text) - 1);
    return SDL_PushEvent(&event) >= 0 ? 0 : -2;
}
static int32_t RenPyStop(void *opaque) {
    auto *session = static_cast<RenPySession *>(opaque);
    if (session != nullptr && session->running.load()) {
        AppendRenPyHostLog(session, "lifecycle.stop-requested");
        PushSimpleEvent(SDL_QUIT);
    }
    return 0;
}
static void *RenPyNativeView(void *opaque) {
    auto *session = static_cast<RenPySession *>(opaque);
    return session != nullptr ? (__bridge void *)session->view : nullptr;
}
static void RenPyDestroy(void *opaque) {
    auto *session = static_cast<RenPySession *>(opaque);
    if (session == nullptr) return;
    {
        std::lock_guard<std::mutex> lock(session->callbackMutex);
        session->callback = nullptr;
        session->callbackContext = nullptr;
    }
    session->destroyRequested.store(true);
    (void)RenPyStop(session);
    if (session->mainReturned.load() || !session->running.load()) {
        [session->view detachSession];
        session->view = nil;
        if (!session->everStarted.load()) ReleaseRenPyClaim();
        delete session;
    }
}

static const YumeRuntimeProviderAPI kRenPyProvider = {
    YUME_RUNTIME_ABI_VERSION, "renios", RenPyCreate, RenPyStart, RenPyPause,
    RenPyResume, RenPySendButton, RenPySendPointer, RenPySendText, RenPyStop,
    RenPyNativeView, RenPyDestroy
};

extern "C" const YumeRuntimeProviderAPI *yume_renios_runtime_provider(void) {
    return &kRenPyProvider;
}
