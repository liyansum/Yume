#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <new>
#include <string>

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
- (void)detachSession;
@end

struct RenPySession {
    std::string contentRoot;
    std::string saveRoot;
    RenPyGeneration generation = RenPyGeneration::Modern;
    YumeRuntimeEventCallback callback = nullptr;
    void *callbackContext = nullptr;
    std::mutex callbackMutex;
    __strong YumeRenPyHostView *view = nil;
    std::atomic<bool> running{false};
    std::atomic<bool> everStarted{false};
    std::atomic<bool> mainReturned{false};
    std::atomic<bool> destroyRequested{false};
    std::atomic<bool> stoppedEventSent{false};
};

static std::mutex gRenPyClaimMutex;
static bool gRenPyClaimed = false;

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
    NSArray<NSString *> *candidates = @[
        @"game/script_version.txt", @"script_version.txt"
    ];
    for (NSString *relative in candidates) {
        NSString *path = [root stringByAppendingPathComponent:relative];
        NSString *value = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
        if ([value containsString:@"(6,"] || [value containsString:@"(7,"]) {
            return RenPyGeneration::Legacy;
        }
        if ([value containsString:@"(8,"]) return RenPyGeneration::Modern;
    }
    if ([[NSFileManager defaultManager]
            fileExistsAtPath:[root stringByAppendingPathComponent:@"game/cache/bytecode-39.rpyb"]]) {
        return RenPyGeneration::Modern;
    }
    return RenPyGeneration::Modern;
}

static void PushSimpleEvent(Uint32 type) {
    SDL_Event event{};
    event.type = type;
    (void)SDL_PushEvent(&event);
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
    [gameView removeFromSuperview];
    gameView.frame = self.bounds;
    gameView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
    [self insertSubview:gameView atIndex:0];
    window.hidden = YES;
    _embeddedGameView = gameView;
    _sdlWindow = window;
    link.paused = YES;
    RenPyEmit(_session, YUME_RUNTIME_EVENT_FIRST_FRAME, "renpy.first-frame");
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _embeddedGameView.frame = self.bounds;
}

- (void)detachSession {
    [_embeddingLink invalidate];
    _embeddingLink = nil;
    UIView *gameView = _embeddedGameView;
    UIWindow *window = _sdlWindow;
    _embeddedGameView = nil;
    _sdlWindow = nil;
    if (gameView != nil && window != nil) {
        [gameView removeFromSuperview];
        gameView.frame = window.bounds;
        [window addSubview:gameView];
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
    session->callback = callback;
    session->callbackContext = context;
    NSString *root = [NSString stringWithUTF8String:session->contentRoot.c_str()];
    session->generation = DetectRenPyGeneration(root);
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
    NSString *launcher = [[runtimeRoot URLByAppendingPathComponent:@"yume-renpy"] path];
    NSString *base = [[runtimeRoot URLByAppendingPathComponent:@"base" isDirectory:YES] path];
    if (![[NSFileManager defaultManager]
            fileExistsAtPath:[base stringByAppendingPathComponent:@"main.py"]]) {
        session->running.store(false);
        RenPyEmit(session, YUME_RUNTIME_EVENT_FAILED, "renpy.resources-missing");
        return -2;
    }

    setenv("RENPY_PATH_TO_SAVES", session->saveRoot.c_str(), 1);
    setenv("RENPY_SEARCHPATH", session->contentRoot.c_str(), 1);
    session->everStarted.store(true);
    [session->view beginEmbedding];
    RenPyEmit(session, YUME_RUNTIME_EVENT_STARTED,
              session->generation == RenPyGeneration::Modern
                  ? "renpy.modern-started" : "renpy.legacy-started");

    std::string executable = launcher.UTF8String;
    dispatch_async(dispatch_get_main_queue(), ^{
        SDL_SetMainReady();
        std::string content = session->contentRoot;
        char *arguments[] = {
            executable.data(), const_cast<char *>("--basedir"), content.data(), nullptr
        };
        int result = session->generation == RenPyGeneration::Modern
            ? yume_renpy_modern_main(3, arguments)
            : yume_renpy_legacy_main(3, arguments);
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
    return 0;
}

static int32_t RenPyPause(void *opaque) {
    auto *session = static_cast<RenPySession *>(opaque);
    if (session == nullptr || !session->running.load()) return -1;
    PushSimpleEvent(SDL_APP_WILLENTERBACKGROUND);
    PushSimpleEvent(SDL_APP_DIDENTERBACKGROUND);
    RenPyEmit(session, YUME_RUNTIME_EVENT_PAUSED, "renpy.paused");
    return 0;
}
static int32_t RenPyResume(void *opaque) {
    auto *session = static_cast<RenPySession *>(opaque);
    if (session == nullptr || !session->running.load()) return -1;
    PushSimpleEvent(SDL_APP_WILLENTERFOREGROUND);
    PushSimpleEvent(SDL_APP_DIDENTERFOREGROUND);
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
    if (session != nullptr && session->running.load()) PushSimpleEvent(SDL_QUIT);
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
