#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <mutex>
#include <new>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

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
    struct EnvironmentEntry {
        std::string key;
        std::string value;
        bool existed = false;
    };

    std::string contentRoot;
    std::string saveRoot;
    std::string logRoot;
    std::string launcherPath;
    std::string runtimeBasePath;
    RenPyGeneration generation = RenPyGeneration::Modern;
    YumeRuntimeEventCallback callback = nullptr;
    void *callbackContext = nullptr;
    YumeRuntimeLogCallback logCallback = nullptr;
    void *logCallbackContext = nullptr;
    std::mutex callbackMutex;
    std::mutex logMutex;
    __strong YumeRenPyHostView *view = nil;
    std::atomic<bool> running{false};
    std::atomic<bool> everStarted{false};
    std::atomic<bool> mainScheduled{false};
    std::atomic<bool> mainEntered{false};
    std::atomic<bool> mainReturned{false};
    std::atomic<bool> stopRequested{false};
    // 0 = launcher setup, 1 = launcher_main committed, 2 = stop won before
    // entry, 3 = launcher returned. This atomically hands SDL_QUIT ownership
    // between stop and worker.
    std::atomic<int> launchGate{0};
    std::atomic<bool> destroyRequested{false};
    std::atomic<bool> stoppedEventSent{false};
    // 0 = not scheduled, 1 = worker active, 2 = worker finished,
    // 3 = destroy waits for worker, 4 = deletion claimed.
    std::atomic<int> workerLifecycle{0};
    std::atomic<uint64_t> inputSequence{0};
    std::mutex pythonLogMutex;
    uint64_t pythonLogOffset = 0;
    std::vector<EnvironmentEntry> environment;
    bool environmentConfigured = false;
    int savedStdout = -1;
    int savedStderr = -1;
};

static void AppendRenPyHostLog(RenPySession *session, const char *message) {
    if (session == nullptr) return;
    {
        std::lock_guard<std::mutex> callbackLock(session->callbackMutex);
        if (session->logCallback != nullptr) {
            session->logCallback(YUME_RUNTIME_LOG_INFORMATION, "renpy.host",
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
        NSString *path = [root stringByAppendingPathComponent:@"renpy-host.log"];
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

static void AppendRenPyPathSummary(RenPySession *session, const char *label,
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
        AppendRenPyHostLog(session, line);
    }
}

static void MirrorRenPyPythonLog(RenPySession *session) {
    if (session == nullptr || session->logRoot.empty()) return;
    std::lock_guard<std::mutex> lock(session->pythonLogMutex);
    @autoreleasepool {
        NSString *root = [NSString stringWithUTF8String:session->logRoot.c_str()];
        NSString *path = [root stringByAppendingPathComponent:@"renpy-python.log"];
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
        if (handle == nil) return;
        [handle seekToFileOffset:session->pythonLogOffset];
        NSData *data = [handle readDataToEndOfFile];
        session->pythonLogOffset += data.length;
        [handle closeFile];
        if (data.length == 0) return;
        NSString *text = [[NSString alloc] initWithData:data
                                               encoding:NSUTF8StringEncoding];
        if (text == nil) text = [[NSString alloc] initWithData:data
                                                     encoding:NSISOLatin1StringEncoding];
        for (NSString *line in [text componentsSeparatedByCharactersInSet:
                NSCharacterSet.newlineCharacterSet]) {
            if (line.length == 0) continue;
            std::lock_guard<std::mutex> callbackLock(session->callbackMutex);
            if (session->logCallback != nullptr) {
                session->logCallback(YUME_RUNTIME_LOG_INFORMATION, "renpy.python",
                                     line.UTF8String ?: "<invalid utf8>",
                                     session->logCallbackContext);
            }
        }
    }
}

static std::mutex gRenPyClaimMutex;
static bool gRenPyClaimed = false;
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
        struct stat status {};
        if (fstat(fileno(stream), &status) == 0)
            session->pythonLogOffset = static_cast<uint64_t>(status.st_size);
        std::fflush(stdout);
        std::fflush(stderr);
        const int savedStdout = dup(STDOUT_FILENO);
        const int savedStderr = dup(STDERR_FILENO);
        if (savedStdout < 0 || savedStderr < 0) {
            if (savedStdout >= 0) close(savedStdout);
            if (savedStderr >= 0) close(savedStderr);
            fclose(stream);
            AppendRenPyHostLog(session, "output.redirect-save-failed");
            return;
        }
        (void)fcntl(savedStdout, F_SETFD, FD_CLOEXEC);
        (void)fcntl(savedStderr, F_SETFD, FD_CLOEXEC);
        const int fd = fileno(stream);
        if (dup2(fd, STDOUT_FILENO) < 0 || dup2(fd, STDERR_FILENO) < 0) {
            (void)dup2(savedStdout, STDOUT_FILENO);
            (void)dup2(savedStderr, STDERR_FILENO);
            close(savedStdout);
            close(savedStderr);
            fclose(stream);
            AppendRenPyHostLog(session, "output.redirect-dup-failed");
            return;
        }
        session->savedStdout = savedStdout;
        session->savedStderr = savedStderr;
        fclose(stream);
    }
}

static void RestoreRenPyOutput(RenPySession *session) {
    if (session == nullptr) return;
    std::fflush(stdout);
    std::fflush(stderr);
    if (session->savedStdout >= 0) {
        (void)dup2(session->savedStdout, STDOUT_FILENO);
        close(session->savedStdout);
        session->savedStdout = -1;
    }
    if (session->savedStderr >= 0) {
        (void)dup2(session->savedStderr, STDERR_FILENO);
        close(session->savedStderr);
        session->savedStderr = -1;
    }
}

static void SetRenPyEnvironment(RenPySession *session, const char *key,
                                const char *value) {
    if (session == nullptr || key == nullptr || value == nullptr) return;
    const char *previous = getenv(key);
    session->environment.push_back({key, previous != nullptr ? previous : "",
                                    previous != nullptr});
    (void)setenv(key, value, 1);
}

static void RestoreRenPyEnvironment(RenPySession *session) {
    if (session == nullptr || !session->environmentConfigured) return;
    for (auto iterator = session->environment.rbegin();
         iterator != session->environment.rend(); ++iterator) {
        if (iterator->existed) {
            (void)setenv(iterator->key.c_str(), iterator->value.c_str(), 1);
        } else {
            (void)unsetenv(iterator->key.c_str());
        }
    }
    session->environment.clear();
    session->environmentConfigured = false;
}

static void ReleaseRenPyClaim(void) {
    std::lock_guard<std::mutex> lock(gRenPyClaimMutex);
    gRenPyClaimed = false;
}

static void DetachRenPyViewOnMain(RenPySession *session) {
    if (session == nullptr) return;
    dispatch_block_t detach = ^{
        [session->view detachSession];
    };
    if (NSThread.isMainThread) {
        detach();
    } else {
        dispatch_sync(dispatch_get_main_queue(), detach);
    }
}

static void DeleteRenPySession(RenPySession *session) {
    if (session == nullptr) return;
    RestoreRenPyOutput(session);
    RestoreRenPyEnvironment(session);
    dispatch_block_t detach = ^{
        [session->view detachSession];
        session->view = nil;
    };
    if (NSThread.isMainThread) {
        detach();
    } else {
        dispatch_sync(dispatch_get_main_queue(), detach);
    }
    // The official launcher finalizes Python, but its statically linked
    // extension modules are not guaranteed to survive a second initialize in
    // the same process. Match Spark's process-isolated model: only a session
    // that never entered launcher_main releases the in-process claim.
    if (!session->mainEntered.load()) ReleaseRenPyClaim();
    delete session;
}

static void FinishRenPyWorker(RenPySession *session) {
    // This must be the worker's final operation on the session. A destroyer
    // that observes state 2 may free it immediately after the transition.
    session->mainReturned.store(true);
    int expected = 1;
    if (session->workerLifecycle.compare_exchange_strong(expected, 2)) return;
    if (expected == 3) {
        expected = 3;
        if (session->workerLifecycle.compare_exchange_strong(expected, 4)) {
            DeleteRenPySession(session);
        }
    }
}

static NSString *ExistingRenPyPath(NSString *root, NSString *relative) {
    if (root.length == 0 || relative.length == 0) return nil;
    NSString *current = root.stringByStandardizingPath;
    for (NSString *component in [relative componentsSeparatedByString:@"/"]) {
        if (component.length == 0 || [component isEqualToString:@"."]) continue;
        NSString *candidate = [current stringByAppendingPathComponent:component];
        if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) {
            NSString *match = nil;
            for (NSString *child in [NSFileManager.defaultManager
                    contentsOfDirectoryAtPath:current error:nil]) {
                if ([child caseInsensitiveCompare:component] == NSOrderedSame) {
                    match = child;
                    break;
                }
            }
            if (match == nil) return nil;
            candidate = [current stringByAppendingPathComponent:match];
        }
        current = candidate;
    }
    return current;
}

static void RenPyEmit(RenPySession *session, YumeRuntimeEventKind kind,
                      const char *code) {
    if (session == nullptr) return;
    std::lock_guard<std::mutex> lock(session->callbackMutex);
    if (session->callback != nullptr) {
        session->callback(kind, code, session->callbackContext);
    }
}

static int RenPyGenerationFromVersionFile(NSString *path) {
    NSData *data = path.length > 0 ? [NSData dataWithContentsOfFile:path] : nil;
    if (data.length == 0) return -1;
    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    if (data.length >= 4 && bytes[2] == 0x0d && bytes[3] == 0x0a) {
        // Python 2.7 and Python 3 bytecode have unambiguous magic prefixes.
        // Ren'Py 7 uses 03 f3 0d 0a; supported Ren'Py 8 releases use a
        // Python 3 magic whose second byte is 0d.
        if (bytes[0] == 0x03 && bytes[1] == 0xf3) return 0;
        if (bytes[1] == 0x0d) return 1;
    }
    NSString *value = [[NSString alloc] initWithData:data
                                             encoding:NSUTF8StringEncoding];
    if (value == nil) return -1;
    NSString *lower = value.lowercaseString;
    if ([lower containsString:@"version = u'8."] ||
        [lower containsString:@"version = u\"8."] ||
        [lower containsString:@"version = '8."] ||
        [lower containsString:@"version = \"8."] ||
        [lower containsString:@"(8,"] ||
        [lower containsString:@"version = 8"]) return 1;
    if ([lower containsString:@"version = u'7."] ||
        [lower containsString:@"version = u\"7."] ||
        [lower containsString:@"version = '7."] ||
        [lower containsString:@"version = \"7."] ||
        [lower containsString:@"(6,"] || [lower containsString:@"(7,"] ||
        [lower containsString:@"version = 6"] ||
        [lower containsString:@"version = 7"]) return 0;
    return -1;
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
    NSArray<NSString *> *versionFiles = @[
        @"game/script_version.txt", @"script_version.txt",
        @"renpy/vc_version.py", @"renpy/vc_version.pyc",
        @"renpy/vc_version.pyo", @"game/renpy/vc_version.py",
        @"game/renpy/vc_version.pyc", @"game/renpy/vc_version.pyo"
    ];
    for (NSString *relative in versionFiles) {
        NSString *path = ExistingRenPyPath(root, relative);
        if (path == nil) continue;
        const int detected = RenPyGenerationFromVersionFile(path);
        if (detected == 1) return RenPyGeneration::Modern;
        if (detected == 0) return RenPyGeneration::Legacy;
    }
    for (NSString *relative in @[@"renpy/__pycache__", @"game/renpy/__pycache__"]) {
        NSString *directory = ExistingRenPyPath(root, relative);
        if (directory.length == 0) continue;
        for (NSString *name in [NSFileManager.defaultManager
                contentsOfDirectoryAtPath:directory error:nil]) {
            if (![name.lowercaseString hasPrefix:@"vc_version"] ||
                [name.pathExtension caseInsensitiveCompare:@"pyc"] != NSOrderedSame)
                continue;
            const int detected = RenPyGenerationFromVersionFile(
                [directory stringByAppendingPathComponent:name]);
            if (detected == 1) return RenPyGeneration::Modern;
            if (detected == 0) return RenPyGeneration::Legacy;
        }
    }
    NSArray<NSString *> *modernMarkers = @[
        @"game/cache/bytecode-39.rpyb", @"game/cache/bytecode-312.rpyb",
        @"lib/python3.9", @"lib/python3.10", @"lib/python3.11", @"lib/python3.12"
    ];
    for (NSString *relative in modernMarkers) {
        if (ExistingRenPyPath(root, relative) != nil) {
            return RenPyGeneration::Modern;
        }
    }
    NSArray<NSString *> *legacyMarkers = @[
        @"game/cache/bytecode-27.rpyb", @"lib/python2.7"
    ];
    for (NSString *relative in legacyMarkers) {
        if (ExistingRenPyPath(root, relative) != nil) {
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
    uint64_t _embeddingPollCount;
    CFTimeInterval _lastEmbeddingDiagnostic;
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
    if (_sdlStarted || _session == nullptr || self.window == nil ||
        !_session->running.load() || _session->stopRequested.load() ||
        _session->destroyRequested.load()) return;
    if (CGRectIsEmpty(self.bounds)) return;
    _sdlStarted = YES;
    gYumeHostWindow = self.window;
    gYumeHostView = self;
    [self.window makeKeyAndVisible];
    AppendRenPyHostLog(_session, "view.in-window");
    char viewLine[256];
    std::snprintf(viewLine, sizeof(viewLine),
                  "view.host-bound bounds=%.1fx%.1f scale=%.2f window=%p scenes=%lu",
                  self.bounds.size.width, self.bounds.size.height,
                  self.window.screen.scale, (__bridge void *)self.window,
                  static_cast<unsigned long>(UIApplication.sharedApplication.connectedScenes.count));
    AppendRenPyHostLog(_session, viewLine);
    RenPySession *session = _session;
    std::string executable = session->launcherPath;
    int idleWorker = 0;
    if (!session->workerLifecycle.compare_exchange_strong(idleWorker, 1)) return;
    session->mainScheduled.store(true);
    // Spark launches launcher_main on a global worker queue. Python/SDL owns
    // this thread until the game exits; running it on UIKit's main queue would
    // freeze view embedding, controls, lifecycle delivery, and the watchdog.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            if (session->stopRequested.load()) {
                RestoreRenPyOutput(session);
                RestoreRenPyEnvironment(session);
                session->running.store(false);
                DetachRenPyViewOnMain(session);
                if (!session->stoppedEventSent.exchange(true))
                    RenPyEmit(session, YUME_RUNTIME_EVENT_STOPPED,
                              "renpy.stopped-before-launch");
                FinishRenPyWorker(session);
                return;
            }
            AppendRenPyHostLog(session, ("engine.sdl-main.begin wasInit=" +
                std::to_string(SDL_WasInit(0)) + " videoDriver=" +
                std::string(SDL_GetCurrentVideoDriver() ?: "<none>")).c_str());
            // Never chdir into the imported game. Windows/mac exports ship
            // lib/python2.7/iosupport.py that uses pyobjus against macOS
            // Foundation paths and abort on iOS.
            char previousWorkingDirectory[PATH_MAX] = {};
            const bool capturedWorkingDirectory =
                getcwd(previousWorkingDirectory, sizeof(previousWorkingDirectory)) != nullptr;
            if (!session->runtimeBasePath.empty()) {
                (void)chdir(session->runtimeBasePath.c_str());
                AppendRenPyHostLog(session, ("engine.chdir=" + session->runtimeBasePath).c_str());
            }
            // Spark and the official iOS runtime render through MetalANGLE. Do not
            // force SDL's software renderer: neither embedded Ren'Py generation
            // exposes "sw" as a valid RENPY_RENDERER value.
            SDL_SetHint(SDL_HINT_VIDEO_MINIMIZE_ON_FOCUS_LOSS, "0");
            SDL_SetMainReady();
            std::string executableArgument = executable;
            std::string gameRoot = session->contentRoot;
            AppendRenPyHostLog(session, ("engine.basedir=" + gameRoot).c_str());
            AppendRenPyHostLog(session, ("engine.argv0=" + executableArgument).c_str());
            RedirectRenPyOutput(session);
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
            // launcher_main is normally wrapped by SDL_RunApp, which enables the
            // UIKit event pump before entering Python. Yume is already inside the
            // host UIApplication, so reproduce that part without starting a
            // second UIApplicationMain.
            SDL_iPhoneSetEventPump(SDL_TRUE);
            // Atomically close the hand-off race with RenPyStop. If stop wins
            // the gate, no SDL_QUIT is left in the process-wide queue. If this
            // worker wins, stop observes state 1 and delivers SDL_QUIT while
            // launcher_main owns the event loop.
            int preparing = 0;
            if (!session->launchGate.compare_exchange_strong(preparing, 1)) {
                SDL_iPhoneSetEventPump(SDL_FALSE);
                if (capturedWorkingDirectory) (void)chdir(previousWorkingDirectory);
                RestoreRenPyOutput(session);
                MirrorRenPyPythonLog(session);
                RestoreRenPyEnvironment(session);
                session->running.store(false);
                DetachRenPyViewOnMain(session);
                if (!session->stoppedEventSent.exchange(true))
                    RenPyEmit(session, YUME_RUNTIME_EVENT_STOPPED,
                              "renpy.stopped-before-launch");
                FinishRenPyWorker(session);
                return;
            }
            session->mainEntered.store(true);
            const CFTimeInterval startedAt = CACurrentMediaTime();
            int result = session->generation == RenPyGeneration::Modern
                ? yume_renpy_modern_main(2, arguments)
                : yume_renpy_legacy_main(2, arguments);
            // Stop can race the instant launcher_main returns while `running`
            // is still true for cleanup. Publish state 3 first, then remove a
            // QUIT that may have been delivered by a stopper which observed
            // state 1 immediately before this store. NativeRuntimeSession
            // serializes native engines, so no other provider owns SDL here.
            session->launchGate.store(3);
            session->mainReturned.store(true);
            SDL_FlushEvent(SDL_QUIT);
            SDL_iPhoneSetEventPump(SDL_FALSE);
            if (capturedWorkingDirectory) {
                (void)chdir(previousWorkingDirectory);
                AppendRenPyHostLog(session, "engine.cwd-restored");
            }
            RestoreRenPyOutput(session);
            MirrorRenPyPythonLog(session);
            RestoreRenPyEnvironment(session);
            std::string resultLine = "engine.main-returned result=" + std::to_string(result) +
                " elapsed=" + std::to_string(CACurrentMediaTime() - startedAt) +
                " wasInit=" + std::to_string(SDL_WasInit(0)) + " videoDriver=" +
                std::string(SDL_GetCurrentVideoDriver() ?: "<none>") + " sdlError=" +
                std::string(SDL_GetError() ?: "<none>");
            AppendRenPyHostLog(session, resultLine.c_str());
            session->running.store(false);
            DetachRenPyViewOnMain(session);
            if (result != 0)
                RenPyEmit(session, YUME_RUNTIME_EVENT_FAILED, "renpy.engine-error");
            if (!session->stoppedEventSent.exchange(true)) {
                RenPyEmit(session, YUME_RUNTIME_EVENT_STOPPED, "renpy.stopped");
            }
            FinishRenPyWorker(session);
        }
    });
}

- (void)beginEmbedding {
    if (_embeddingLink != nil) return;
    AppendRenPyHostLog(_session, "view.embedding-watch.begin");
    _embeddingLink = [CADisplayLink displayLinkWithTarget:self
                                                 selector:@selector(pollForSDLView:)];
    [_embeddingLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)pollForSDLView:(CADisplayLink *)link {
    _embeddingPollCount += 1;
    if (_embeddingPollCount == 1 ||
        CACurrentMediaTime() - _lastEmbeddingDiagnostic >= 2.0) {
        _lastEmbeddingDiagnostic = CACurrentMediaTime();
        MirrorRenPyPythonLog(_session);
        SDL_Window *keyboard = SDL_GetKeyboardFocus();
        SDL_Window *mouse = SDL_GetMouseFocus();
        char line[320];
        std::snprintf(line, sizeof(line),
                      "view.embedding-poll count=%llu embedded=%d sdlInit=%u video=%s keyboardWindow=%u mouseWindow=%u sdlError=%s",
                      static_cast<unsigned long long>(_embeddingPollCount),
                      _embeddedGameView != nil ? 1 : 0, SDL_WasInit(0),
                      SDL_GetCurrentVideoDriver() ?: "<none>",
                      keyboard != nullptr ? SDL_GetWindowID(keyboard) : 0,
                      mouse != nullptr ? SDL_GetWindowID(mouse) : 0,
                      SDL_GetError() ?: "<none>");
        AppendRenPyHostLog(_session, line);
    }
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
    session->logCallback = configuration->log_callback;
    session->logCallbackContext = configuration->log_callback_context;
    NSString *root = [NSString stringWithUTF8String:session->contentRoot.c_str()];
    session->generation = DetectRenPyGeneration(root);
    AppendRenPyHostLog(session, session->generation == RenPyGeneration::Modern
        ? "session.created generation=modern"
        : "session.created generation=legacy");
    AppendRenPyPathSummary(session, "content", session->contentRoot);
    AppendRenPyPathSummary(session, "save", session->saveRoot);
    AppendRenPyPathSummary(session, "logs", session->logRoot);
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
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *mainScript = [base stringByAppendingPathComponent:@"main.py"];
    NSString *siteModule = session->generation == RenPyGeneration::Modern
        ? [base stringByAppendingPathComponent:@"lib/python3.12/site.pyc"]
        : [base stringByAppendingPathComponent:@"lib/python2.7/site.pyo"];
    AppendRenPyPathSummary(session, "runtime", generationRoot.UTF8String ?: "");
    NSDictionary *mainAttributes = [fileManager attributesOfItemAtPath:mainScript error:nil];
    NSDictionary *siteAttributes = [fileManager attributesOfItemAtPath:siteModule error:nil];
    AppendRenPyHostLog(session, ("start.preflight mainBytes=" +
        std::to_string([mainAttributes[NSFileSize] unsignedLongLongValue]) +
        " siteBytes=" +
        std::to_string([siteAttributes[NSFileSize] unsignedLongLongValue]) +
        " bundle=" + std::string(NSBundle.mainBundle.bundlePath.UTF8String ?: "<nil>")).c_str());
    if (![fileManager fileExistsAtPath:mainScript] ||
        ![fileManager fileExistsAtPath:siteModule]) {
        session->running.store(false);
        AppendRenPyHostLog(session, "start.failed resources-missing");
        RenPyEmit(session, YUME_RUNTIME_EVENT_FAILED, "renpy.resources-missing");
        return -2;
    }

    NSString *saveRoot = [NSString stringWithUTF8String:session->saveRoot.c_str()];
    NSString *logRoot = [NSString stringWithUTF8String:session->logRoot.c_str()];
    NSError *directoryError = nil;
    if (saveRoot.length > 0)
        [fileManager createDirectoryAtPath:saveRoot withIntermediateDirectories:YES
                                attributes:nil error:&directoryError];
    if (directoryError == nil && logRoot.length > 0)
        [fileManager createDirectoryAtPath:logRoot withIntermediateDirectories:YES
                                attributes:nil error:&directoryError];
    if (directoryError != nil) {
        session->running.store(false);
        AppendRenPyHostLog(session,
            ("start.failed writable-root " +
             std::string(directoryError.localizedDescription.UTF8String ?: "unknown")).c_str());
        RenPyEmit(session, YUME_RUNTIME_EVENT_FAILED, "renpy.writable-root");
        return -3;
    }

    SetRenPyEnvironment(session, "RENPY_PATH_TO_SAVES", session->saveRoot.c_str());
    SetRenPyEnvironment(session, "RENPY_LOGDIR", session->logRoot.c_str());
    SetRenPyEnvironment(session, "RENPY_SEARCHPATH", session->contentRoot.c_str());
    SetRenPyEnvironment(session, "YUME_RENPY_GAMEDIR", session->contentRoot.c_str());
    SetRenPyEnvironment(session, "RENPY_LOG_TO_STDOUT", "1");
    // These are the MetalANGLE renderer identifiers exported by the staged
    // iOS runtimes. Modern Ren'Py exposes "angle"; the legacy runtime also
    // exposes the ANGLE2 path used for its newer GL2 interface.
    const char *renderer = session->generation == RenPyGeneration::Modern
        ? "angle" : "angle2";
    SetRenPyEnvironment(session, "RENPY_RENDERER", renderer);
    SetRenPyEnvironment(session, "PYTHONHOME", base.UTF8String ?: "");
    session->environmentConfigured = true;
    AppendRenPyHostLog(session, ("start.renderer=" + std::string(renderer) +
        " safe-mode=0").c_str());
    AppendRenPyHostLog(session, ("start.main=" + std::string(mainScript.UTF8String ?: "")).c_str());
    AppendRenPyHostLog(session, ("start.site=" + std::string(siteModule.UTF8String ?: "")).c_str());
    AppendRenPyHostLog(session, ("start.environment PYTHONHOME=" +
        std::string(getenv("PYTHONHOME") ?: "") + " RENPY_SEARCHPATH=" +
        std::string(getenv("RENPY_SEARCHPATH") ?: "") + " RENPY_LOGDIR=" +
        std::string(getenv("RENPY_LOGDIR") ?: "") + " saves=" +
        std::string(getenv("RENPY_PATH_TO_SAVES") ?: "")).c_str());
    AppendRenPyHostLog(session, "crash-handler=system-default shared-process-safe");
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
    const int result = SDL_PushEvent(&event);
    AppendRenPyHostLog(session, ("input.key sequence=" +
        std::to_string(session->inputSequence.fetch_add(1) + 1) + " action=" +
        std::to_string(static_cast<int>(action)) + " scancode=" +
        std::to_string(static_cast<int>(scancode)) + " pressed=" +
        std::to_string(pressed != 0) + " pushResult=" + std::to_string(result) +
        " sdlError=" + std::string(SDL_GetError() ?: "<none>")).c_str());
    return result >= 0 ? 0 : -2;
}

static int32_t RenPySendPointer(void *opaque, double x, double y, int32_t pressed) {
    auto *session = static_cast<RenPySession *>(opaque);
    if (session == nullptr || !session->running.load()) return -1;
    SDL_Event motion{};
    motion.motion.type = SDL_MOUSEMOTION;
    motion.motion.x = static_cast<int32_t>(x);
    motion.motion.y = static_cast<int32_t>(y);
    const int motionResult = SDL_PushEvent(&motion);
    SDL_Event button{};
    button.button.type = pressed ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
    button.button.button = 1;
    button.button.state = pressed ? 1 : 0;
    button.button.x = static_cast<int32_t>(x);
    button.button.y = static_cast<int32_t>(y);
    const int buttonResult = SDL_PushEvent(&button);
    char line[256];
    std::snprintf(line, sizeof(line),
                  "input.pointer sequence=%llu x=%.1f y=%.1f pressed=%d motionResult=%d buttonResult=%d sdlError=%s",
                  static_cast<unsigned long long>(session->inputSequence.fetch_add(1) + 1),
                  x, y, pressed != 0 ? 1 : 0, motionResult, buttonResult,
                  SDL_GetError() ?: "<none>");
    AppendRenPyHostLog(session, line);
    return buttonResult >= 0 ? 0 : -2;
}

static int32_t RenPySendText(void *opaque, const char *text) {
    auto *session = static_cast<RenPySession *>(opaque);
    if (session == nullptr || !session->running.load() || text == nullptr) return -1;
    const std::string bytes(text);
    size_t cursor = 0;
    int result = 1;
    while (cursor < bytes.size()) {
        constexpr size_t kTextCapacity =
            sizeof(((SDL_TextInputEvent *)nullptr)->text);
        size_t end = std::min(cursor + kTextCapacity - 1,
                              bytes.size());
        if (end < bytes.size()) {
            while (end > cursor &&
                   (static_cast<unsigned char>(bytes[end]) & 0xc0u) == 0x80u)
                --end;
        }
        if (end == cursor) return -2;
        SDL_Event event{};
        event.text.type = SDL_TEXTINPUT;
        std::memcpy(event.text.text, bytes.data() + cursor, end - cursor);
        event.text.text[end - cursor] = '\0';
        result = SDL_PushEvent(&event);
        if (result < 0) break;
        cursor = end;
    }
    AppendRenPyHostLog(session, ("input.text sequence=" +
        std::to_string(session->inputSequence.fetch_add(1) + 1) + " bytes=" +
        std::to_string(std::strlen(text)) + " pushResult=" +
        std::to_string(result)).c_str());
    return result >= 0 ? 0 : -2;
}
static int32_t RenPyStop(void *opaque) {
    auto *session = static_cast<RenPySession *>(opaque);
    if (session != nullptr && session->running.load() &&
        !session->stopRequested.exchange(true)) {
        AppendRenPyHostLog(session, ("lifecycle.stop-requested inputs=" +
            std::to_string(session->inputSequence.load()) + " mainReturned=" +
            std::to_string(session->mainReturned.load())).c_str());
        int preparing = 0;
        if (session->launchGate.compare_exchange_strong(preparing, 2)) {
            if (session->workerLifecycle.load() == 0) {
                // No launcher worker can still consume process-wide
                // environment or output state, so this unscheduled session
                // may stop inline.
                session->running.store(false);
                RestoreRenPyOutput(session);
                RestoreRenPyEnvironment(session);
                if (!session->stoppedEventSent.exchange(true)) {
                    RenPyEmit(session, YUME_RUNTIME_EVENT_STOPPED,
                              "renpy.stopped-before-launch");
                }
            } else {
                AppendRenPyHostLog(session,
                                   "lifecycle.stop-deferred-to-worker");
            }
        } else if (preparing == 1) {
            PushSimpleEvent(SDL_QUIT);
        }
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
    AppendRenPyHostLog(session, "lifecycle.destroy-requested");
    {
        std::lock_guard<std::mutex> lock(session->callbackMutex);
        session->callback = nullptr;
        session->callbackContext = nullptr;
        session->logCallback = nullptr;
        session->logCallbackContext = nullptr;
    }
    session->destroyRequested.store(true);
    (void)RenPyStop(session);
    for (;;) {
        int state = session->workerLifecycle.load();
        if (state == 0) {
            if (session->workerLifecycle.compare_exchange_weak(state, 4)) {
                DeleteRenPySession(session);
                return;
            }
            continue;
        }
        if (state == 1) {
            if (session->workerLifecycle.compare_exchange_weak(state, 3)) return;
            continue;
        }
        if (state == 2) {
            if (session->workerLifecycle.compare_exchange_weak(state, 4)) {
                DeleteRenPySession(session);
                return;
            }
            continue;
        }
        return;
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
