#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cctype>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <new>
#include <string>
#include <sys/stat.h>
#include <unordered_map>
#include <unistd.h>
#include <vector>

#include "Art3m1sFFI.h"
#include <SDL.h>
#include <SDL_sound.h>
#include "../../YumeCore/Sources/CYumeRuntimeBridge/include/CYumeRuntimeBridge.h"

struct Art3m1sSession;

@interface YumeArt3m1sAudioTrack : NSObject
@property(nonatomic, strong) AVAudioPlayerNode *node;
@property(nonatomic, strong) AVAudioPCMBuffer *buffer;
@property(nonatomic, strong) AVAudioPCMBuffer *loopBuffer;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *category;
@property(nonatomic) float rawGain;
@property(nonatomic) NSInteger rawPan;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL notifyOnFinish;
@end
@implementation YumeArt3m1sAudioTrack
@end

@interface YumeArt3m1sVideoTrack : NSObject
@property(nonatomic, strong) AVPlayer *player;
@property(nonatomic, strong) AVPlayerItem *item;
@property(nonatomic, strong) AVPlayerItemVideoOutput *output;
@property(nonatomic, strong) AVPlayerLayer *layer;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic) BOOL loopPlayback;
@property(nonatomic) BOOL skippable;
@property(nonatomic) BOOL fullscreen;
@property(nonatomic) CFTimeInterval openedAt;
@end
@implementation YumeArt3m1sVideoTrack
@end

@interface YumeArt3m1sView : UIView
- (instancetype)initWithSession:(Art3m1sSession *)session;
- (int32_t)startEngine;
- (int32_t)pauseEngine;
- (int32_t)resumeEngine;
- (int32_t)sendKey:(uint32_t)key pressed:(BOOL)pressed;
- (int32_t)sendPointerX:(double)x y:(double)y pressed:(BOOL)pressed;
- (void)handleUICommand:(NSString *)kind payload:(NSDictionary *)payload;
- (void)handleMediaCommand:(NSString *)kind payload:(NSDictionary *)payload;
- (int32_t)stopEngine;
- (void)detachSession;
@end

struct Art3m1sSession {
    struct PFSArchive {
        void *handle = nullptr;
        std::string path;
    };

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
    std::mutex pfsMutex;
    std::vector<PFSArchive> pfsArchives;
};

static std::mutex gArt3m1sMutex;
static Art3m1sSession *gArt3m1sSession = nullptr;

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

// Artemis games are commonly authored on a case-insensitive Windows volume.
// Resolve each component only after the exact path misses, while re-checking
// containment after every symlink resolution.
static NSString *ExistingPathBelowRoot(const std::string &rootValue,
                                       NSString *logical) {
    NSString *root = [NSString stringWithUTF8String:rootValue.c_str()];
    if (root.length == 0 || logical.length == 0) return nil;
    NSString *resolvedRoot = root.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString *current = resolvedRoot;
    NSArray<NSString *> *parts = [logical componentsSeparatedByString:@"/"];
    for (NSUInteger index = 0; index < parts.count; index++) {
        NSString *part = parts[index];
        if (part.length == 0) continue;
        NSString *candidate = [current stringByAppendingPathComponent:part];
        BOOL isDirectory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:candidate
                                                isDirectory:&isDirectory]) {
            NSString *match = nil;
            for (NSString *child in [NSFileManager.defaultManager
                    contentsOfDirectoryAtPath:current error:nil]) {
                if ([child caseInsensitiveCompare:part] == NSOrderedSame) {
                    match = child;
                    break;
                }
            }
            if (match == nil) return nil;
            candidate = [current stringByAppendingPathComponent:match];
            if (![NSFileManager.defaultManager fileExistsAtPath:candidate
                                                    isDirectory:&isDirectory]) return nil;
        }
        candidate = candidate.stringByStandardizingPath.stringByResolvingSymlinksInPath;
        if (!IsContainedPath(candidate, resolvedRoot)) return nil;
        if (index + 1 < parts.count && !isDirectory) return nil;
        current = candidate;
    }
    return current;
}

static NSString *ReadPath(Art3m1sSession *session, NSString *logical) {
    if (session == nullptr || logical.length == 0) return nil;
    NSString *saveLogical = logical;
    if ([logical.lowercaseString hasPrefix:@"save/"])
        saveLogical = [logical substringFromIndex:5];
    NSString *save = PathBelowRoot(session->saveRoot, saveLogical, NO);
    if (save != nil && [NSFileManager.defaultManager isReadableFileAtPath:save]) return save;
    save = ExistingPathBelowRoot(session->saveRoot, saveLogical);
    if (save != nil && [NSFileManager.defaultManager isReadableFileAtPath:save]) return save;
    NSString *content = PathBelowRoot(session->contentRoot, logical, NO);
    if (content != nil && [NSFileManager.defaultManager isReadableFileAtPath:content]) return content;
    content = ExistingPathBelowRoot(session->contentRoot, logical);
    if (content != nil && [NSFileManager.defaultManager isReadableFileAtPath:content]) return content;
    NSString *derived = PathBelowRoot(session->derivedRoot, logical, NO);
    if (derived != nil && [NSFileManager.defaultManager isReadableFileAtPath:derived]) return derived;
    derived = ExistingPathBelowRoot(session->derivedRoot, logical);
    if (derived != nil && [NSFileManager.defaultManager isReadableFileAtPath:derived]) return derived;
    return nil;
}

static NSString *WritePath(Art3m1sSession *session, NSString *logical) {
    if ([logical.lowercaseString hasPrefix:@"save/"])
        logical = [logical substringFromIndex:5];
    return session != nullptr ? PathBelowRoot(session->saveRoot, logical, YES) : nil;
}

static std::string ArtemisCharset(NSData *ini) {
    if (ini.length == 0) return "SHIFT_JIS";
    const uint8_t *bytes = static_cast<const uint8_t *>(ini.bytes);
    bool inIOSSection = false;
    size_t cursor = 0;
    while (cursor < ini.length) {
        size_t end = cursor;
        while (end < ini.length && bytes[end] != '\r' && bytes[end] != '\n') ++end;
        std::string line(reinterpret_cast<const char *>(bytes + cursor), end - cursor);
        cursor = end;
        while (cursor < ini.length && (bytes[cursor] == '\r' || bytes[cursor] == '\n'))
            ++cursor;
        const size_t first = line.find_first_not_of(" \t");
        if (first == std::string::npos || line[first] == ';' || line[first] == '#') continue;
        const size_t last = line.find_last_not_of(" \t");
        line = line.substr(first, last - first + 1);
        std::string upper = line;
        std::transform(upper.begin(), upper.end(), upper.begin(),
                       [](unsigned char value) {
                           return static_cast<char>(std::toupper(value));
                       });
        if (upper.front() == '[' && upper.back() == ']') {
            inIOSSection = upper == "[IOS]";
            continue;
        }
        if (!inIOSSection) continue;
        const size_t equals = upper.find('=');
        if (equals == std::string::npos) continue;
        std::string key = upper.substr(0, equals);
        const size_t keyEnd = key.find_last_not_of(" \t");
        if (keyEnd != std::string::npos) key.resize(keyEnd + 1);
        if (key != "CHARSET") continue;
        std::string value = upper.substr(equals + 1);
        const size_t valueStart = value.find_first_not_of(" \t");
        const size_t valueEnd = value.find_last_not_of(" \t");
        if (valueStart == std::string::npos) return "SHIFT_JIS";
        value = value.substr(valueStart, valueEnd - valueStart + 1);
        return value == "UTF-8" || value == "UTF8" ? "UTF-8" : "SHIFT_JIS";
    }
    return "SHIFT_JIS";
}

static void ClosePFSArchives(Art3m1sSession *session) {
    if (session == nullptr) return;
    std::lock_guard<std::mutex> guard(session->pfsMutex);
    for (auto &archive : session->pfsArchives) {
        if (archive.handle != nullptr) pfs_close(archive.handle);
        archive.handle = nullptr;
    }
    session->pfsArchives.clear();
}

static BOOL OpenPFSArchives(Art3m1sSession *session, NSString *root,
                            NSData *ini) {
    if (session == nullptr || root.length == 0) return NO;
    NSArray<NSString *> *children = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:root error:nil];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *child in children) {
        if ([child.pathExtension caseInsensitiveCompare:@"pfs"] != NSOrderedSame)
            continue;
        NSString *path = [root stringByAppendingPathComponent:child];
        BOOL directory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] &&
            !directory) [paths addObject:path];
    }
    [paths sortUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        const BOOL leftRoot = [left.lastPathComponent caseInsensitiveCompare:@"root.pfs"] ==
                              NSOrderedSame;
        const BOOL rightRoot = [right.lastPathComponent caseInsensitiveCompare:@"root.pfs"] ==
                               NSOrderedSame;
        if (leftRoot != rightRoot) return leftRoot ? NSOrderedAscending : NSOrderedDescending;
        return [left.lastPathComponent localizedStandardCompare:right.lastPathComponent];
    }];
    if (paths.count == 0) return YES;

    const std::string charset = ArtemisCharset(ini);
    size_t opened = 0;
    {
        std::lock_guard<std::mutex> guard(session->pfsMutex);
        for (NSString *path in paths) {
            void *handle = pfs_open_with_encoding(path.fileSystemRepresentation,
                                                  charset.c_str());
            if (handle == nullptr) {
                NSString *line = [NSString stringWithFormat:
                    @"pfs.open-failed file=%@ encoding=%s", path.lastPathComponent,
                    charset.c_str()];
                AppendLog(session, YUME_RUNTIME_LOG_WARNING, line.UTF8String);
                continue;
            }
            session->pfsArchives.push_back({handle, path.fileSystemRepresentation});
            ++opened;
            NSString *line = [NSString stringWithFormat:
                @"pfs.opened file=%@ entries=%d encoding=%s", path.lastPathComponent,
                pfs_entry_count(handle), charset.c_str()];
            AppendLog(session, YUME_RUNTIME_LOG_INFORMATION, line.UTF8String);
        }
    }
    return opened > 0;
}

static int32_t ReadFromPFS(Art3m1sSession *session, NSString *logical,
                           uint8_t *buffer, int32_t bufferSize, int64_t offset) {
    if (session == nullptr || logical.length == 0) return -1;
    const char *path = logical.UTF8String;
    if (path == nullptr) return -1;
    std::lock_guard<std::mutex> guard(session->pfsMutex);
    // root.pfs is stored first; patches and later archives override it.
    for (auto archive = session->pfsArchives.rbegin();
         archive != session->pfsArchives.rend(); ++archive) {
        const int32_t size = pfs_file_size(archive->handle, path);
        if (size < 0) continue;
        if (buffer == nullptr && bufferSize == 0 && offset == -1) return size;
        if (buffer == nullptr || bufferSize <= 0 || offset < 0) return -1;
        return pfs_read(archive->handle, path, static_cast<uint64_t>(offset),
                        buffer, static_cast<uint32_t>(bufferSize));
    }
    return -1;
}

static NSDate *PFSModificationDate(Art3m1sSession *session,
                                   NSString *logical) {
    if (session == nullptr || logical.length == 0) return nil;
    const char *path = logical.UTF8String;
    if (path == nullptr) return nil;
    std::lock_guard<std::mutex> guard(session->pfsMutex);
    for (auto archive = session->pfsArchives.rbegin();
         archive != session->pfsArchives.rend(); ++archive) {
        if (pfs_file_size(archive->handle, path) < 0) continue;
        NSString *archivePath = [NSString stringWithUTF8String:archive->path.c_str()];
        NSDictionary *attributes = archivePath.length > 0
            ? [NSFileManager.defaultManager attributesOfItemAtPath:archivePath error:nil]
            : nil;
        return attributes[NSFileModificationDate];
    }
    return nil;
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
    NSString *logical = LogicalPath(rawPath);
    NSString *path = ReadPath(session, logical);
    if (path == nil) return ReadFromPFS(session, logical, buffer, bufferSize, offset);
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
    if (date == nil) date = PFSModificationDate(session, logical);
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

static NSArray<NSString *> *MediaCandidates(NSDictionary *payload,
                                             NSArray<NSString *> *extensions) {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *key in @[@"resolved_file", @"file"]) {
        NSString *raw = [payload[key] isKindOfClass:NSString.class] ? payload[key] : nil;
        NSString *logical = LogicalPath(raw.UTF8String);
        if (logical.length == 0) continue;
        NSMutableArray<NSString *> *variants = [NSMutableArray arrayWithObject:logical];
        if (logical.pathExtension.length == 0) {
            for (NSString *extension in extensions)
                [variants addObject:[logical stringByAppendingPathExtension:extension]];
        }
        for (NSString *candidate in variants) {
            NSString *dedupe = candidate.lowercaseString;
            if ([seen containsObject:dedupe]) continue;
            [seen addObject:dedupe];
            [result addObject:candidate];
        }
    }
    return result;
}

static NSData *ReadMediaResource(Art3m1sSession *session,
                                 NSArray<NSString *> *candidates,
                                 NSString **resolvedLogical) {
    if (session == nullptr) return nil;
    for (NSString *logical in candidates) {
        const int32_t size = Art3m1sRead(logical.UTF8String, nullptr, 0, -1);
        if (size < 0) continue;
        NSMutableData *data = [NSMutableData dataWithLength:static_cast<NSUInteger>(size)];
        int64_t offset = 0;
        BOOL failed = NO;
        while (offset < size) {
            const int32_t request = static_cast<int32_t>(std::min<int64_t>(
                1024 * 1024, static_cast<int64_t>(size) - offset));
            int32_t read = Art3m1sRead(logical.UTF8String,
                static_cast<uint8_t *>(data.mutableBytes) + offset, request, offset);
            if (read <= 0 || read > request) {
                failed = YES;
                break;
            }
            offset += read;
        }
        if (failed) continue;
        if (resolvedLogical != nullptr) *resolvedLogical = logical;
        return data;
    }
    return nil;
}

static AVAudioPCMBuffer *DecodeAudioResource(Art3m1sSession *session,
                                             NSDictionary *payload,
                                             NSString **resolvedLogical) {
    NSArray<NSString *> *candidates = MediaCandidates(payload,
        @[@"ogg", @"wav", @"mp3", @"flac", @"opus", @"aac", @"m4a", @"aif", @"aiff"]);
    NSString *logical = nil;
    NSData *encoded = ReadMediaResource(session, candidates, &logical);
    if (encoded.length == 0 || encoded.length > UINT32_MAX) return nil;

    Sound_AudioInfo desired {};
    desired.format = AUDIO_S16SYS;
    desired.channels = 2;
    desired.rate = 48000;
    NSString *extension = logical.pathExtension.lowercaseString;
    Sound_Sample *sample = Sound_NewSampleFromMem(
        static_cast<const uint8_t *>(encoded.bytes), static_cast<Uint32>(encoded.length),
        extension.length > 0 ? extension.UTF8String : nullptr, &desired, 64 * 1024);
    if (sample == nullptr) return nil;
    const Uint32 decodedBytes = Sound_DecodeAll(sample);
    AVAudioPCMBuffer *result = nil;
    if ((sample->flags & SOUND_SAMPLEFLAG_ERROR) == 0 && decodedBytes >= 4 &&
        decodedBytes % 4 == 0 && sample->desired.format == AUDIO_S16SYS &&
        sample->desired.channels == 2 && sample->desired.rate == 48000) {
        AVAudioFormat *format = [[AVAudioFormat alloc]
            initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:48000 channels:2
                      interleaved:YES];
        const AVAudioFrameCount frames = decodedBytes / 4;
        result = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frames];
        result.frameLength = frames;
        AudioBufferList *buffers = result.mutableAudioBufferList;
        if (buffers == nullptr || buffers->mNumberBuffers != 1 ||
            buffers->mBuffers[0].mDataByteSize < decodedBytes) {
            result = nil;
        } else {
            memcpy(buffers->mBuffers[0].mData, sample->buffer, decodedBytes);
            buffers->mBuffers[0].mDataByteSize = decodedBytes;
        }
    }
    Sound_FreeSample(sample);
    if (result != nil && resolvedLogical != nullptr) *resolvedLogical = logical;
    return result;
}

static NSURL *VideoResourceURL(Art3m1sSession *session, NSDictionary *payload,
                               NSString **resolvedLogical) {
    NSArray<NSString *> *candidates = MediaCandidates(payload,
        @[@"mp4", @"m4v", @"mov", @"avi", @"mpg", @"mpeg", @"wmv", @"webm"]);
    for (NSString *logical in candidates) {
        NSString *physical = ReadPath(session, logical);
        if (physical != nil) {
            if (resolvedLogical != nullptr) *resolvedLogical = logical;
            return [NSURL fileURLWithPath:physical];
        }
    }

    NSString *logical = nil;
    NSData *data = ReadMediaResource(session, candidates, &logical);
    if (data == nil || logical.length == 0) return nil;
    NSString *derived = [NSString stringWithUTF8String:session->derivedRoot.c_str()];
    if (derived.length == 0) derived = NSTemporaryDirectory();
    NSString *directory = [derived stringByAppendingPathComponent:@"art3m1s-media"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                 withIntermediateDirectories:YES attributes:nil error:nil])
        return nil;
    uint64_t hash = 1469598103934665603ULL;
    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    for (NSUInteger index = 0; index < data.length; ++index) {
        hash ^= bytes[index];
        hash *= 1099511628211ULL;
    }
    NSString *extension = logical.pathExtension.length > 0 ? logical.pathExtension : @"mp4";
    NSString *name = [NSString stringWithFormat:@"%016llx.%@",
        static_cast<unsigned long long>(hash), extension.lowercaseString];
    NSString *path = [directory stringByAppendingPathComponent:name];
    if (![NSFileManager.defaultManager fileExistsAtPath:path] &&
        ![data writeToFile:path options:NSDataWritingAtomic error:nil]) return nil;
    if (resolvedLogical != nullptr) *resolvedLogical = logical;
    return [NSURL fileURLWithPath:path];
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

static void Art3m1sUICommand(const char *rawKind, const char *rawPayload) {
    if (rawKind == nullptr || rawPayload == nullptr) return;
    NSString *kind = [NSString stringWithUTF8String:rawKind];
    NSData *data = [[NSString stringWithUTF8String:rawPayload]
        dataUsingEncoding:NSUTF8StringEncoding];
    id decoded = data != nil
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (kind.length == 0 || ![decoded isKindOfClass:NSDictionary.class]) return;
    NSDictionary *payload = decoded;

    // art3m1s emits commands while the runtime has an active mutable borrow.
    // Always defer the host action so response FFIs cannot re-enter Rust.
    dispatch_async(dispatch_get_main_queue(), ^{
        Art3m1sSession *session = ActiveSession();
        if (session == nullptr || session->stopped.load() || session->view == nil) return;
        [session->view handleUICommand:kind payload:payload];
    });
}

static void Art3m1sMediaCommand(const char *rawKind, const char *rawPayload) {
    if (rawKind == nullptr || rawPayload == nullptr) return;
    NSString *kind = [NSString stringWithUTF8String:rawKind];
    NSData *data = [[NSString stringWithUTF8String:rawPayload]
        dataUsingEncoding:NSUTF8StringEncoding];
    id decoded = data != nil
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (kind.length == 0 || ![decoded isKindOfClass:NSDictionary.class]) return;
    NSDictionary *payload = decoded;

    // Media commands are emitted from inside the core's mutable runtime call.
    // Defer all playback and completion work to avoid re-entering Rust.
    dispatch_async(dispatch_get_main_queue(), ^{
        Art3m1sSession *session = ActiveSession();
        if (session == nullptr || session->stopped.load() || session->view == nil) return;
        [session->view handleMediaCommand:kind payload:payload];
    });
}

static int32_t Art3m1sFontList(int32_t monospace, int32_t vertical,
                               uint8_t *buffer, int32_t bufferCapacity) {
    if (buffer == nullptr || bufferCapacity <= 0) return -1;
    (void)vertical; // CoreText performs vertical glyph layout per font/glyph.
    return OnMainSync(^NSInteger {
        NSArray<NSString *> *families = [UIFont.familyNames
            sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        NSUInteger offset = 0;
        for (NSString *family in families) {
            if (monospace != 0) {
                NSString *fontName = [UIFont fontNamesForFamilyName:family].firstObject;
                UIFont *font = fontName != nil ? [UIFont fontWithName:fontName size:12] : nil;
                if (font == nil || !(font.fontDescriptor.symbolicTraits &
                                     UIFontDescriptorTraitMonoSpace)) continue;
            }
            NSData *name = [family dataUsingEncoding:NSUTF8StringEncoding];
            NSUInteger required = name.length + (offset == 0 ? 0 : 1);
            if (required > static_cast<NSUInteger>(bufferCapacity) - offset) break;
            if (offset != 0) buffer[offset++] = '\n';
            memcpy(buffer + offset, name.bytes, name.length);
            offset += name.length;
        }
        return offset <= INT32_MAX ? static_cast<NSInteger>(offset) : -1;
    });
}

static int32_t Art3m1sWindowState(void) {
    return OnMainSync(^NSInteger {
        // An iOS scene occupies its full window. Only the background state is
        // equivalent to the desktop engine's minimized bit.
        NSInteger flags = 1;
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground)
            flags |= 2;
        return flags;
    });
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
    int32_t _lastDirection;
    UIAlertController *_activeDialog;
    UIImageView *_avoidOverlay;
    std::unordered_map<void *, uint32_t> _touchIdentifiers;
    uint32_t _nextTouchIdentifier;
    AVAudioEngine *_audioEngine;
    YumeArt3m1sAudioTrack *_bgmTrack;
    NSMutableDictionary<NSString *, YumeArt3m1sAudioTrack *> *_audioTracks;
    NSMutableSet<YumeArt3m1sAudioTrack *> *_retiringAudioTracks;
    NSUInteger _audioGeneration;
    BOOL _soundInitialized;
    float _masterVolume;
    float _bgmVolume;
    float _seVolume;
    float _voiceVolume;
    YumeArt3m1sVideoTrack *_fullscreenVideo;
    NSMutableDictionary<NSString *, YumeArt3m1sVideoTrack *> *_layerVideos;
    std::vector<uint8_t> _videoRGBA;
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
        _lastDirection = -1;
        _nextTouchIdentifier = 1;
        _audioTracks = [NSMutableDictionary dictionary];
        _retiringAudioTracks = [NSMutableSet set];
        _layerVideos = [NSMutableDictionary dictionary];
        _masterVolume = _bgmVolume = _seVolume = _voiceVolume = 1.0f;
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
    _fullscreenVideo.layer.frame = self.bounds;
    [self notifyDirectionIfNeeded];
}

- (int32_t)currentDirection {
    UIInterfaceOrientation orientation = self.window.windowScene.interfaceOrientation;
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft: return 1;
        case UIInterfaceOrientationPortraitUpsideDown: return 2;
        case UIInterfaceOrientationLandscapeRight: return 3;
        case UIInterfaceOrientationPortrait:
        case UIInterfaceOrientationUnknown: return 0;
    }
}

- (void)notifyDirectionIfNeeded {
    if (_runtime == nullptr) return;
    int32_t direction = [self currentDirection];
    if (direction == _lastDirection) return;
    _lastDirection = direction;
    art3m1s_runtime_notify_direction_changed(_runtime, direction);
}

- (BOOL)prepareAudioHost {
    if (_audioEngine != nil && _audioEngine.isRunning && _soundInitialized) return YES;
    if (!_soundInitialized) {
        _soundInitialized = Sound_Init() != 0;
        if (!_soundInitialized) {
            NSString *line = [NSString stringWithFormat:@"media.audio decoder-init failed: %s",
                Sound_GetError() ?: "unknown"];
            AppendLog(_session, YUME_RUNTIME_LOG_ERROR, line.UTF8String);
            return NO;
        }
    }
    NSError *error = nil;
    AVAudioSession *audioSession = AVAudioSession.sharedInstance;
    [audioSession setCategory:AVAudioSessionCategoryPlayback
                         mode:AVAudioSessionModeDefault
                      options:AVAudioSessionCategoryOptionMixWithOthers error:&error];
    if (error != nil) {
        NSString *line = [NSString stringWithFormat:@"media.audio session-category warning: %@",
            error.localizedDescription];
        AppendLog(_session, YUME_RUNTIME_LOG_WARNING, line.UTF8String);
    }
    error = nil;
    [audioSession setActive:YES error:&error];
    if (error != nil) {
        NSString *line = [NSString stringWithFormat:@"media.audio session-active warning: %@",
            error.localizedDescription];
        AppendLog(_session, YUME_RUNTIME_LOG_WARNING, line.UTF8String);
    }
    _audioEngine = [[AVAudioEngine alloc] init];
    [_audioEngine prepare];
    error = nil;
    if (![_audioEngine startAndReturnError:&error]) {
        NSString *line = [NSString stringWithFormat:@"media.audio engine-start failed: %@",
            error.localizedDescription ?: @"unknown"];
        AppendLog(_session, YUME_RUNTIME_LOG_ERROR, line.UTF8String);
        _audioEngine = nil;
        return NO;
    }
    return YES;
}

- (float)categoryVolumeForTrack:(YumeArt3m1sAudioTrack *)track {
    if ([track.category isEqualToString:@"bgm"]) return _bgmVolume;
    if ([track.category isEqualToString:@"voice"]) return _voiceVolume;
    return _seVolume;
}

- (void)applyAudioLevels:(YumeArt3m1sAudioTrack *)track {
    if (track == nil) return;
    track.node.volume = std::clamp(track.rawGain, 0.0f, 1.0f) *
        std::clamp(_masterVolume, 0.0f, 1.0f) *
        std::clamp([self categoryVolumeForTrack:track], 0.0f, 1.0f);
    track.node.pan = std::clamp(static_cast<float>(track.rawPan) / 1000.0f,
                                -1.0f, 1.0f);
}

- (BOOL)isCurrentAudioTrack:(YumeArt3m1sAudioTrack *)track {
    if (track == nil) return NO;
    if (_bgmTrack == track || [_retiringAudioTracks containsObject:track]) return YES;
    return track.identifier.length > 0 && _audioTracks[track.identifier] == track;
}

- (void)cleanupAudioTrack:(YumeArt3m1sAudioTrack *)track {
    if (track == nil) return;
    track.notifyOnFinish = NO;
    if (_bgmTrack == track) _bgmTrack = nil;
    if (track.identifier.length > 0 && _audioTracks[track.identifier] == track)
        [_audioTracks removeObjectForKey:track.identifier];
    [_retiringAudioTracks removeObject:track];
    [track.node stop];
    if (_audioEngine != nil) [_audioEngine detachNode:track.node];
}

- (void)notifySoundFinished:(NSString *)identifier {
    if (_runtime == nullptr) return;
    art3m1s_runtime_notify_sound_finished(
        _runtime, identifier.length > 0 ? identifier.UTF8String : nullptr);
}

- (void)audioTrackDidFinish:(YumeArt3m1sAudioTrack *)track {
    if (![self isCurrentAudioTrack:track] || !track.notifyOnFinish) return;
    NSString *identifier = track.identifier;
    [self cleanupAudioTrack:track];
    [self notifySoundFinished:identifier];
}

- (void)rampTrack:(YumeArt3m1sAudioTrack *)track
           toGain:(float)target
          duration:(uint64_t)durationMs
         stopAfter:(BOOL)stopAfter {
    if (track == nil) return;
    target = std::clamp(target, 0.0f, 1.0f);
    if (durationMs == 0) {
        track.rawGain = target;
        [self applyAudioLevels:track];
        if (stopAfter) [self cleanupAudioTrack:track];
        return;
    }
    const float initial = track.rawGain;
    const NSUInteger generation = track.generation;
    const NSUInteger steps = std::clamp<NSUInteger>(durationMs / 20, 1, 100);
    __weak YumeArt3m1sView *weakSelf = self;
    for (NSUInteger step = 1; step <= steps; ++step) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            static_cast<int64_t>((durationMs * step / steps) * NSEC_PER_MSEC)),
            dispatch_get_main_queue(), ^{
                YumeArt3m1sView *strongSelf = weakSelf;
                if (strongSelf == nil || track.generation != generation ||
                    ![strongSelf isCurrentAudioTrack:track]) return;
                const float fraction = static_cast<float>(step) / steps;
                track.rawGain = initial + (target - initial) * fraction;
                [strongSelf applyAudioLevels:track];
                if (stopAfter && step == steps) [strongSelf cleanupAudioTrack:track];
            });
    }
}

- (void)rampPanForTrack:(YumeArt3m1sAudioTrack *)track
                   toPan:(NSInteger)target
                duration:(uint64_t)durationMs {
    if (track == nil) return;
    target = std::clamp<NSInteger>(target, -1000, 1000);
    if (durationMs == 0) {
        track.rawPan = target;
        [self applyAudioLevels:track];
        return;
    }
    const NSInteger initial = track.rawPan;
    const NSUInteger generation = track.generation;
    const NSUInteger steps = std::clamp<NSUInteger>(durationMs / 20, 1, 100);
    __weak YumeArt3m1sView *weakSelf = self;
    for (NSUInteger step = 1; step <= steps; ++step) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            static_cast<int64_t>((durationMs * step / steps) * NSEC_PER_MSEC)),
            dispatch_get_main_queue(), ^{
                YumeArt3m1sView *strongSelf = weakSelf;
                if (strongSelf == nil || track.generation != generation ||
                    ![strongSelf isCurrentAudioTrack:track]) return;
                const double fraction = static_cast<double>(step) / steps;
                track.rawPan = static_cast<NSInteger>(
                    std::lround(initial + (target - initial) * fraction));
                [strongSelf applyAudioLevels:track];
            });
    }
}

- (void)retireAudioTrack:(YumeArt3m1sAudioTrack *)track fadeMs:(uint64_t)fadeMs {
    if (track == nil) return;
    track.notifyOnFinish = NO;
    if (_bgmTrack == track) _bgmTrack = nil;
    if (track.identifier.length > 0 && _audioTracks[track.identifier] == track)
        [_audioTracks removeObjectForKey:track.identifier];
    if (fadeMs == 0) {
        [self cleanupAudioTrack:track];
        return;
    }
    [_retiringAudioTracks addObject:track];
    [self rampTrack:track toGain:0 duration:fadeMs stopAfter:YES];
}

- (YumeArt3m1sAudioTrack *)makeAudioTrack:(NSDictionary *)payload
                                identifier:(NSString *)identifier
                                  category:(NSString *)category
                                      loop:(BOOL)loop
                                    fadeMs:(uint64_t)fadeMs {
    if (![self prepareAudioHost]) return nil;
    NSString *logical = nil;
    AVAudioPCMBuffer *buffer = DecodeAudioResource(_session, payload, &logical);
    if (buffer == nil) {
        NSString *line = [NSString stringWithFormat:@"media.audio decode-failed file=%@ error=%s",
            payload[@"resolved_file"] ?: payload[@"file"] ?: @"(missing)",
            Sound_GetError() ?: "unknown"];
        AppendLog(_session, YUME_RUNTIME_LOG_ERROR, line.UTF8String);
        return nil;
    }
    YumeArt3m1sAudioTrack *track = [[YumeArt3m1sAudioTrack alloc] init];
    track.node = [[AVAudioPlayerNode alloc] init];
    track.buffer = buffer;
    track.identifier = identifier;
    track.category = category;
    track.rawGain = [payload[@"gain"] respondsToSelector:@selector(floatValue)]
        ? std::clamp([payload[@"gain"] floatValue] / 1000.0f, 0.0f, 1.0f) : 1.0f;
    track.rawPan = [payload[@"pan"] respondsToSelector:@selector(integerValue)]
        ? std::clamp<NSInteger>([payload[@"pan"] integerValue], -1000, 1000) : 0;
    track.generation = ++_audioGeneration;
    track.notifyOnFinish = !loop;

    NSString *loopFile = [payload[@"loop_file"] isKindOfClass:NSString.class]
        ? payload[@"loop_file"] : nil;
    NSString *resolvedLoop = [payload[@"resolved_loop_file"] isKindOfClass:NSString.class]
        ? payload[@"resolved_loop_file"] : nil;
    if (loop && (loopFile.length > 0 || resolvedLoop.length > 0)) {
        NSMutableDictionary *loopPayload = [NSMutableDictionary dictionary];
        if (loopFile.length > 0) loopPayload[@"file"] = loopFile;
        if (resolvedLoop.length > 0) loopPayload[@"resolved_file"] = resolvedLoop;
        track.loopBuffer = DecodeAudioResource(_session, loopPayload, nullptr);
        if (track.loopBuffer == nil)
            AppendLog(_session, YUME_RUNTIME_LOG_WARNING,
                      "media.audio A-B loop segment missing; looping intro segment");
    }

    [_audioEngine attachNode:track.node];
    [_audioEngine connect:track.node to:_audioEngine.mainMixerNode format:buffer.format];
    const float targetGain = track.rawGain;
    if (fadeMs > 0) track.rawGain = 0;
    [self applyAudioLevels:track];
    if (track.loopBuffer != nil) {
        [track.node scheduleBuffer:track.buffer completionHandler:nil];
        [track.node scheduleBuffer:track.loopBuffer atTime:nil
                           options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
    } else if (loop) {
        [track.node scheduleBuffer:track.buffer atTime:nil
                           options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
    } else {
        __weak YumeArt3m1sView *weakSelf = self;
        __weak YumeArt3m1sAudioTrack *weakTrack = track;
        [track.node scheduleBuffer:track.buffer atTime:nil options:0
            completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
            completionHandler:^(AVAudioPlayerNodeCompletionCallbackType type) {
                (void)type;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf audioTrackDidFinish:weakTrack];
                });
            }];
    }
    [track.node play];
    if (fadeMs > 0) [self rampTrack:track toGain:targetGain duration:fadeMs stopAfter:NO];
    NSString *line = [NSString stringWithFormat:@"media.audio playing category=%@ id=%@ file=%@",
        category, identifier ?: @"bgm", logical ?: @"unknown"];
    AppendLog(_session, YUME_RUNTIME_LOG_INFORMATION, line.UTF8String);
    return track;
}

- (void)cleanupVideoTrack:(YumeArt3m1sVideoTrack *)track {
    if (track == nil) return;
    [NSNotificationCenter.defaultCenter removeObserver:self
        name:AVPlayerItemDidPlayToEndTimeNotification object:track.item];
    [NSNotificationCenter.defaultCenter removeObserver:self
        name:AVPlayerItemFailedToPlayToEndTimeNotification object:track.item];
    [track.player pause];
    [track.layer removeFromSuperlayer];
    if (_fullscreenVideo == track) _fullscreenVideo = nil;
    if (track.identifier.length > 0 && _layerVideos[track.identifier] == track)
        [_layerVideos removeObjectForKey:track.identifier];
}

- (void)finishVideoTrack:(YumeArt3m1sVideoTrack *)track notifyCore:(BOOL)notifyCore {
    if (track == nil) return;
    BOOL current = _fullscreenVideo == track ||
        (track.identifier.length > 0 && _layerVideos[track.identifier] == track);
    if (!current) return;
    NSString *identifier = track.identifier;
    [self cleanupVideoTrack:track];
    if (notifyCore && _runtime != nullptr) {
        art3m1s_runtime_notify_video_finished(
            _runtime, identifier.length > 0 ? identifier.UTF8String : nullptr);
    }
}

- (void)videoDidEnd:(NSNotification *)notification {
    YumeArt3m1sVideoTrack *track = nil;
    if (_fullscreenVideo.item == notification.object) track = _fullscreenVideo;
    if (track == nil) {
        for (YumeArt3m1sVideoTrack *candidate in _layerVideos.allValues) {
            if (candidate.item == notification.object) {
                track = candidate;
                break;
            }
        }
    }
    if (track == nil) return;
    if (track.loopPlayback) {
        [track.player seekToTime:kCMTimeZero
                toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero
               completionHandler:^(BOOL finished) {
                   if (finished) [track.player play];
               }];
        return;
    }
    [self finishVideoTrack:track notifyCore:YES];
}

- (void)videoDidFail:(NSNotification *)notification {
    NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    NSString *line = [NSString stringWithFormat:@"media.video playback-failed: %@",
        error.localizedDescription ?: @"unknown"];
    AppendLog(_session, YUME_RUNTIME_LOG_ERROR, line.UTF8String);
    YumeArt3m1sVideoTrack *track = nil;
    if (_fullscreenVideo.item == notification.object) track = _fullscreenVideo;
    if (track == nil) {
        for (YumeArt3m1sVideoTrack *candidate in _layerVideos.allValues) {
            if (candidate.item == notification.object) {
                track = candidate;
                break;
            }
        }
    }
    [self finishVideoTrack:track notifyCore:YES];
}

- (void)playVideo:(NSDictionary *)payload {
    NSString *identifier = [payload[@"id"] isKindOfClass:NSString.class]
        ? payload[@"id"] : nil;
    const BOOL fullscreen = identifier.length == 0;
    if (fullscreen) [self finishVideoTrack:_fullscreenVideo notifyCore:NO];
    else [self finishVideoTrack:_layerVideos[identifier] notifyCore:NO];

    NSString *logical = nil;
    NSURL *url = VideoResourceURL(_session, payload, &logical);
    if (url == nil) {
        NSString *line = [NSString stringWithFormat:@"media.video missing file=%@",
            payload[@"resolved_file"] ?: payload[@"file"] ?: @"(missing)"];
        AppendLog(_session, YUME_RUNTIME_LOG_ERROR, line.UTF8String);
        if (_runtime != nullptr)
            art3m1s_runtime_notify_video_finished(
                _runtime, fullscreen ? nullptr : identifier.UTF8String);
        return;
    }
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    YumeArt3m1sVideoTrack *track = [[YumeArt3m1sVideoTrack alloc] init];
    track.item = item;
    track.player = [AVPlayer playerWithPlayerItem:item];
    track.identifier = identifier;
    track.fullscreen = fullscreen;
    track.loopPlayback = [payload[@"loop"] respondsToSelector:@selector(boolValue)] &&
        [payload[@"loop"] boolValue];
    track.skippable = [payload[@"skippable"] respondsToSelector:@selector(boolValue)] &&
        [payload[@"skippable"] boolValue];
    track.openedAt = CACurrentMediaTime();
    if (fullscreen) {
        track.layer = [AVPlayerLayer playerLayerWithPlayer:track.player];
        track.layer.frame = self.bounds;
        track.layer.videoGravity = AVLayerVideoGravityResizeAspect;
        track.layer.backgroundColor = UIColor.blackColor.CGColor;
        track.layer.zPosition = 100;
        [self.layer addSublayer:track.layer];
        _fullscreenVideo = track;
    } else {
        NSDictionary *attributes = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
        };
        track.output = [[AVPlayerItemVideoOutput alloc]
            initWithPixelBufferAttributes:attributes];
        [item addOutput:track.output];
        _layerVideos[identifier] = track;
    }
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(videoDidEnd:)
        name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(videoDidFail:)
        name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [track.player play];
    NSString *line = [NSString stringWithFormat:@"media.video playing id=%@ file=%@",
        identifier ?: @"fullscreen", logical ?: @"unknown"];
    AppendLog(_session, YUME_RUNTIME_LOG_INFORMATION, line.UTF8String);
}

- (void)updateLayerVideoFramesAtHostTime:(CFTimeInterval)hostTime {
    if (_runtime == nullptr) return;
    NSMutableArray<YumeArt3m1sVideoTrack *> *tracks = [NSMutableArray array];
    if (_fullscreenVideo != nil) [tracks addObject:_fullscreenVideo];
    [tracks addObjectsFromArray:_layerVideos.allValues];
    for (YumeArt3m1sVideoTrack *track in tracks) {
        if (track.item.status == AVPlayerItemStatusFailed ||
            (track.item.status == AVPlayerItemStatusUnknown &&
             hostTime - track.openedAt >= 15.0)) {
            NSString *line = [NSString stringWithFormat:
                @"media.video %@ id=%@ error=%@",
                track.item.status == AVPlayerItemStatusFailed
                    ? @"failed" : @"startup-timeout",
                track.identifier ?: @"fullscreen",
                track.item.error.localizedDescription ?: @"unknown"];
            AppendLog(_session, YUME_RUNTIME_LOG_ERROR, line.UTF8String);
            [self finishVideoTrack:track notifyCore:YES];
        }
    }
    if (_layerVideos.count == 0) return;
    for (YumeArt3m1sVideoTrack *track in _layerVideos.allValues) {
        CMTime itemTime = [track.output itemTimeForHostTime:hostTime];
        if (![track.output hasNewPixelBufferForItemTime:itemTime]) continue;
        CVPixelBufferRef pixelBuffer = [track.output copyPixelBufferForItemTime:itemTime
                                                             itemTimeForDisplay:nil];
        if (pixelBuffer == nullptr) continue;
        CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        const size_t width = CVPixelBufferGetWidth(pixelBuffer);
        const size_t height = CVPixelBufferGetHeight(pixelBuffer);
        const size_t sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
        const uint8_t *source = static_cast<const uint8_t *>(
            CVPixelBufferGetBaseAddress(pixelBuffer));
        if (source != nullptr && width > 0 && height > 0 &&
            width <= UINT32_MAX && height <= UINT32_MAX &&
            width <= SIZE_MAX / 4 && height <= SIZE_MAX / (width * 4)) {
            _videoRGBA.resize(width * height * 4);
            for (size_t y = 0; y < height; ++y) {
                const uint8_t *input = source + y * sourceStride;
                uint8_t *output = _videoRGBA.data() + y * width * 4;
                for (size_t x = 0; x < width; ++x) {
                    output[x * 4 + 0] = input[x * 4 + 2];
                    output[x * 4 + 1] = input[x * 4 + 1];
                    output[x * 4 + 2] = input[x * 4 + 0];
                    output[x * 4 + 3] = input[x * 4 + 3];
                }
            }
            art3m1s_runtime_upload_video_layer_frame(_runtime,
                track.identifier.UTF8String, static_cast<uint32_t>(width),
                static_cast<uint32_t>(height), _videoRGBA.data(), _videoRGBA.size());
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(pixelBuffer);
    }
}

- (void)stopAllMedia {
    [self retireAudioTrack:_bgmTrack fadeMs:0];
    for (YumeArt3m1sAudioTrack *track in _audioTracks.allValues)
        [self retireAudioTrack:track fadeMs:0];
    for (YumeArt3m1sAudioTrack *track in _retiringAudioTracks.allObjects)
        [self cleanupAudioTrack:track];
    [self finishVideoTrack:_fullscreenVideo notifyCore:NO];
    for (YumeArt3m1sVideoTrack *track in _layerVideos.allValues)
        [self finishVideoTrack:track notifyCore:NO];
}

- (void)handleMediaCommand:(NSString *)kind payload:(NSDictionary *)payload {
    if (_runtime == nullptr) return;
    if ([kind isEqualToString:@"audio_set_volume"]) {
        NSString *channel = [payload[@"channel"] isKindOfClass:NSString.class]
            ? payload[@"channel"] : @"";
        const float value = [payload[@"value"] respondsToSelector:@selector(floatValue)]
            ? std::clamp([payload[@"value"] floatValue], 0.0f, 1.0f) : 1.0f;
        if ([channel isEqualToString:@"master"]) _masterVolume = value;
        else if ([channel isEqualToString:@"bgm"]) _bgmVolume = value;
        else if ([channel isEqualToString:@"se"]) _seVolume = value;
        else if ([channel isEqualToString:@"voice"]) _voiceVolume = value;
        [self applyAudioLevels:_bgmTrack];
        for (YumeArt3m1sAudioTrack *track in _audioTracks.allValues)
            [self applyAudioLevels:track];
        for (YumeArt3m1sAudioTrack *track in _retiringAudioTracks)
            [self applyAudioLevels:track];
        return;
    }
    if ([kind isEqualToString:@"audio_bgm_play"] ||
        [kind isEqualToString:@"audio_bgm_crossfade"]) {
        const BOOL crossfade = [kind isEqualToString:@"audio_bgm_crossfade"];
        const uint64_t fadeMs = [payload[crossfade ? @"time_ms" : @"fade_ms"]
            respondsToSelector:@selector(unsignedLongLongValue)]
            ? [payload[crossfade ? @"time_ms" : @"fade_ms"] unsignedLongLongValue] : 0;
        const BOOL loop = [payload[@"loop"] respondsToSelector:@selector(boolValue)] &&
            [payload[@"loop"] boolValue];
        YumeArt3m1sAudioTrack *old = _bgmTrack;
        if (!crossfade) [self retireAudioTrack:old fadeMs:0];
        YumeArt3m1sAudioTrack *track = [self makeAudioTrack:payload identifier:nil
            category:@"bgm" loop:loop fadeMs:fadeMs];
        if (track == nil) {
            if (crossfade) [self retireAudioTrack:old fadeMs:fadeMs];
            [self notifySoundFinished:nil];
            return;
        }
        _bgmTrack = track;
        if (crossfade) [self retireAudioTrack:old fadeMs:fadeMs];
        return;
    }
    if ([kind isEqualToString:@"audio_bgm_stop"]) {
        const uint64_t fadeMs = [payload[@"fade_ms"] respondsToSelector:
            @selector(unsignedLongLongValue)] ? [payload[@"fade_ms"] unsignedLongLongValue] : 0;
        [self retireAudioTrack:_bgmTrack fadeMs:fadeMs];
        return;
    }
    if ([kind isEqualToString:@"audio_bgm_fade"]) {
        float gain = [payload[@"gain"] respondsToSelector:@selector(floatValue)]
            ? [payload[@"gain"] floatValue] / 1000.0f : 1.0f;
        uint64_t duration = [payload[@"time_ms"] respondsToSelector:
            @selector(unsignedLongLongValue)] ? [payload[@"time_ms"] unsignedLongLongValue] : 0;
        [self rampTrack:_bgmTrack toGain:gain duration:duration stopAfter:NO];
        return;
    }
    if ([kind isEqualToString:@"audio_bgm_pan"]) {
        NSInteger pan = [payload[@"pan"] respondsToSelector:@selector(integerValue)]
            ? [payload[@"pan"] integerValue] : 0;
        uint64_t duration = [payload[@"time_ms"] respondsToSelector:
            @selector(unsignedLongLongValue)] ? [payload[@"time_ms"] unsignedLongLongValue] : 0;
        [self rampPanForTrack:_bgmTrack toPan:pan duration:duration];
        return;
    }
    if ([kind isEqualToString:@"audio_se_play"] ||
        [kind isEqualToString:@"audio_voice_play"]) {
        NSString *identifier = [payload[@"id"] isKindOfClass:NSString.class]
            ? payload[@"id"] : nil;
        if (identifier.length == 0) return;
        [self retireAudioTrack:_audioTracks[identifier] fadeMs:0];
        const BOOL loop = [payload[@"loop"] respondsToSelector:@selector(boolValue)] &&
            [payload[@"loop"] boolValue];
        const uint64_t fadeMs = [payload[@"fade_ms"] respondsToSelector:
            @selector(unsignedLongLongValue)] ? [payload[@"fade_ms"] unsignedLongLongValue] : 0;
        NSString *category = [kind isEqualToString:@"audio_voice_play"] ? @"voice" : @"se";
        YumeArt3m1sAudioTrack *track = [self makeAudioTrack:payload identifier:identifier
            category:category loop:loop fadeMs:fadeMs];
        if (track == nil) [self notifySoundFinished:identifier];
        else _audioTracks[identifier] = track;
        return;
    }
    if ([kind isEqualToString:@"audio_se_stop"]) {
        NSString *identifier = [payload[@"id"] isKindOfClass:NSString.class]
            ? payload[@"id"] : nil;
        uint64_t fadeMs = [payload[@"fade_ms"] respondsToSelector:
            @selector(unsignedLongLongValue)] ? [payload[@"fade_ms"] unsignedLongLongValue] : 0;
        [self retireAudioTrack:_audioTracks[identifier] fadeMs:fadeMs];
        return;
    }
    if ([kind isEqualToString:@"audio_se_fade"] ||
        [kind isEqualToString:@"audio_se_pan"]) {
        NSString *identifier = [payload[@"id"] isKindOfClass:NSString.class]
            ? payload[@"id"] : nil;
        YumeArt3m1sAudioTrack *track = _audioTracks[identifier];
        uint64_t duration = [payload[@"time_ms"] respondsToSelector:
            @selector(unsignedLongLongValue)] ? [payload[@"time_ms"] unsignedLongLongValue] : 0;
        if ([kind isEqualToString:@"audio_se_fade"]) {
            float gain = [payload[@"gain"] respondsToSelector:@selector(floatValue)]
                ? [payload[@"gain"] floatValue] / 1000.0f : 1.0f;
            [self rampTrack:track toGain:gain duration:duration stopAfter:NO];
        } else {
            NSInteger pan = [payload[@"pan"] respondsToSelector:@selector(integerValue)]
                ? [payload[@"pan"] integerValue] : 0;
            [self rampPanForTrack:track toPan:pan duration:duration];
        }
        return;
    }
    if ([kind isEqualToString:@"audio_stop_all"]) {
        [self retireAudioTrack:_bgmTrack fadeMs:0];
        for (YumeArt3m1sAudioTrack *track in _audioTracks.allValues)
            [self retireAudioTrack:track fadeMs:0];
        return;
    }
    if ([kind isEqualToString:@"video_play"]) {
        [self playVideo:payload];
        return;
    }
    if ([kind isEqualToString:@"video_stop_all"]) {
        [self finishVideoTrack:_fullscreenVideo notifyCore:NO];
        for (YumeArt3m1sVideoTrack *track in _layerVideos.allValues)
            [self finishVideoTrack:track notifyCore:NO];
        return;
    }
    NSString *line = [NSString stringWithFormat:@"media.%@ is not implemented", kind];
    AppendLog(_session, YUME_RUNTIME_LOG_WARNING, line.UTF8String);
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
    if (!OpenPFSArchives(_session, root, ini)) {
        AppendLog(_session, YUME_RUNTIME_LOG_ERROR,
                  "start.failed no PFS archive could be opened");
        Emit(_session, YUME_RUNTIME_EVENT_FAILED, "artemis.pfs-open-failed");
        return -3;
    }
    NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
    art3m1s_set_angle_path(frameworks.fileSystemRepresentation);
    art3m1s_set_save_dir("save");
    _runtime = art3m1s_runtime_create(1280, 720, 3 /* ANGLE Metal */);
    if (_runtime == nullptr) {
        ClosePFSArchives(_session);
        AppendLog(_session, YUME_RUNTIME_LOG_ERROR, "start.failed runtime_create");
        Emit(_session, YUME_RUNTIME_EVENT_FAILED, "artemis.renderer-create-failed");
        return -4;
    }
    (void)[self prepareAudioHost];
    if (art3m1s_runtime_load_project_bytes(_runtime,
            static_cast<const uint8_t *>(ini.bytes), ini.length, "ios") != 0) {
        AppendLog(_session, YUME_RUNTIME_LOG_ERROR, "start.failed load_project");
        art3m1s_runtime_destroy(_runtime);
        _runtime = nullptr;
        ClosePFSArchives(_session);
        Emit(_session, YUME_RUNTIME_EVENT_FAILED, "artemis.project-load-failed");
        return -5;
    }
    _stageWidth = art3m1s_runtime_stage_width(_runtime);
    _stageHeight = art3m1s_runtime_stage_height(_runtime);
    const uint32_t capacity = art3m1s_runtime_pixel_buffer_size(_runtime);
    const uint64_t expected = static_cast<uint64_t>(_stageWidth) * _stageHeight * 4;
    if (_stageWidth == 0 || _stageHeight == 0 || expected > UINT32_MAX ||
        capacity < expected) {
        art3m1s_runtime_destroy(_runtime);
        _runtime = nullptr;
        ClosePFSArchives(_session);
        Emit(_session, YUME_RUNTIME_EVENT_FAILED, "artemis.invalid-stage");
        return -6;
    }
    _pixels.resize(capacity);
    _lastTimestamp = 0;
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(drawFrame:)];
    _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    _session->started.store(true);
    [self notifyDirectionIfNeeded];
    AppendLog(_session, YUME_RUNTIME_LOG_INFORMATION, "runtime.started backend=angle-metal");
    Emit(_session, YUME_RUNTIME_EVENT_STARTED, "artemis.started");
    return 0;
}

- (void)drawFrame:(CADisplayLink *)link {
    if (_runtime == nullptr || _paused) return;
    [self updateLayerVideoFramesAtHostTime:link.timestamp];
    uint32_t delta = _lastTimestamp > 0
        ? static_cast<uint32_t>(std::clamp((link.timestamp - _lastTimestamp) * 1000.0, 1.0, 100.0))
        : 16;
    _lastTimestamp = link.timestamp;
    const uint32_t written = art3m1s_runtime_advance_and_render(
        _runtime, delta, _pixels.data(), static_cast<uint32_t>(_pixels.size()));
    const uint64_t expected = static_cast<uint64_t>(_stageWidth) * _stageHeight * 4;
    if (expected <= _pixels.size() && written >= expected) {
        NSData *data = [NSData dataWithBytes:_pixels.data()
                                      length:static_cast<NSUInteger>(expected)];
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
    const BOOL hadTouches = !_touchIdentifiers.empty();
    for (UITouch *touch in touches) {
        CGPoint point = [self stagePointForViewPoint:[touch locationInView:self]];
        void *key = (__bridge void *)touch;
        auto found = _touchIdentifiers.find(key);
        if (found == _touchIdentifiers.end()) {
            if (phase == 2) continue;
            uint32_t identifier = _nextTouchIdentifier++;
            if (_nextTouchIdentifier == 0) _nextTouchIdentifier = 1;
            found = _touchIdentifiers.emplace(key, identifier).first;
        }
        art3m1s_runtime_feed_touch(_runtime, found->second, phase,
                                  static_cast<int32_t>(point.x), static_cast<int32_t>(point.y));
        art3m1s_runtime_feed_mouse(_runtime, static_cast<int32_t>(point.x),
                                  static_cast<int32_t>(point.y));
        if (phase == 2) _touchIdentifiers.erase(found);
    }
    if (!hadTouches && !_touchIdentifiers.empty())
        art3m1s_runtime_feed_mouse_button(_runtime, 0, 1);
    else if (hadTouches && _touchIdentifiers.empty())
        art3m1s_runtime_feed_mouse_button(_runtime, 0, 0);
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_fullscreenVideo != nil && _fullscreenVideo.skippable) {
        [self finishVideoTrack:_fullscreenVideo notifyCore:YES];
        return;
    }
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

- (UIViewController *)hostingViewController {
    UIResponder *responder = self;
    while ((responder = responder.nextResponder) != nil) {
        if ([responder isKindOfClass:UIViewController.class])
            return (UIViewController *)responder;
    }
    return nil;
}

- (void)showDialog:(NSDictionary *)payload {
    if (_runtime == nullptr) return;
    if (_activeDialog != nil) {
        [_activeDialog dismissViewControllerAnimated:NO completion:nil];
        _activeDialog = nil;
    }
    NSString *title = [payload[@"title"] isKindOfClass:NSString.class]
        ? payload[@"title"] : @"";
    NSString *message = [payload[@"message"] isKindOfClass:NSString.class]
        ? payload[@"message"] : @"";
    BOOL hasCancel = [payload[@"hasCancel"] respondsToSelector:@selector(boolValue)]
        && [payload[@"hasCancel"] boolValue];
    BOOL hasTextField = [payload[@"textfield"] respondsToSelector:@selector(boolValue)]
        && [payload[@"textfield"] boolValue];
    NSString *initialText = [payload[@"initialText"] isKindOfClass:NSString.class]
        ? payload[@"initialText"] : @"";
    NSNumber *textLimit = [payload[@"textfieldSize"] isKindOfClass:NSNumber.class]
        ? payload[@"textfieldSize"] : nil;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    if (hasTextField) {
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.text = initialText;
            if (textLimit != nil && textLimit.integerValue > 0)
                field.accessibilityHint = [NSString stringWithFormat:@"Maximum %@ characters",
                                                                     textLimit];
        }];
    }
    __weak YumeArt3m1sView *weakSelf = self;
    void (^submit)(BOOL) = ^(BOOL accepted) {
        YumeArt3m1sView *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_runtime == nullptr) return;
        NSString *text = alert.textFields.firstObject.text ?: @"";
        strongSelf->_activeDialog = nil;
        art3m1s_runtime_submit_dialog(strongSelf->_runtime, accepted ? 1 : 0,
                                     text.UTF8String);
    };
    if (hasCancel) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
            style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
                submit(NO);
            }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            submit(YES);
        }]];

    UIViewController *presenter = [self hostingViewController];
    while (presenter.presentedViewController != nil &&
           !presenter.presentedViewController.isBeingDismissed)
        presenter = presenter.presentedViewController;
    if (presenter == nil || presenter.view.window == nil) {
        AppendLog(_session, YUME_RUNTIME_LOG_WARNING,
                  "ui.dialog unavailable; submitted cancel response");
        art3m1s_runtime_submit_dialog(_runtime, 0, nullptr);
        return;
    }
    _activeDialog = alert;
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)setAvoidVisible:(BOOL)visible file:(NSString *)file {
    if (!visible) {
        [_avoidOverlay removeFromSuperview];
        _avoidOverlay = nil;
        return;
    }
    if (_avoidOverlay == nil) {
        _avoidOverlay = [[UIImageView alloc] initWithFrame:self.bounds];
        _avoidOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                         UIViewAutoresizingFlexibleHeight;
        _avoidOverlay.backgroundColor = UIColor.blackColor;
        _avoidOverlay.contentMode = UIViewContentModeScaleAspectFill;
        _avoidOverlay.clipsToBounds = YES;
        _avoidOverlay.userInteractionEnabled = YES;
        [self addSubview:_avoidOverlay];
    }
    NSString *logical = file.length > 0 ? LogicalPath(file.UTF8String) : nil;
    NSString *path = logical != nil ? ReadPath(_session, logical) : nil;
    _avoidOverlay.image = path != nil ? [UIImage imageWithContentsOfFile:path] : nil;
    [self bringSubviewToFront:_avoidOverlay];
}

- (void)handleUICommand:(NSString *)kind payload:(NSDictionary *)payload {
    if (_runtime == nullptr || _session == nullptr || _session->stopped.load()) return;
    if ([kind isEqualToString:@"dialog_show"]) {
        [self showDialog:payload];
    } else if ([kind isEqualToString:@"write_clipboard"]) {
        NSString *value = [payload[@"string"] isKindOfClass:NSString.class]
            ? payload[@"string"] : @"";
        UIPasteboard.generalPasteboard.string = value;
    } else if ([kind isEqualToString:@"vibrate"]) {
        UINotificationFeedbackGenerator *feedback =
            [[UINotificationFeedbackGenerator alloc] init];
        [feedback notificationOccurred:UINotificationFeedbackTypeWarning];
    } else if ([kind isEqualToString:@"mouse"]) {
        NSNumber *left = [payload[@"left"] isKindOfClass:NSNumber.class]
            ? payload[@"left"] : nil;
        NSNumber *top = [payload[@"top"] isKindOfClass:NSNumber.class]
            ? payload[@"top"] : nil;
        if (left != nil && top != nil)
            art3m1s_runtime_feed_mouse(_runtime, left.intValue, top.intValue);
    } else if ([kind isEqualToString:@"avoid"]) {
        NSString *action = [payload[@"action"] isKindOfClass:NSString.class]
            ? payload[@"action"] : @"";
        NSString *file = [payload[@"file"] isKindOfClass:NSString.class]
            ? payload[@"file"] : nil;
        [self setAvoidVisible:[action isEqualToString:@"show"] file:file];
    } else if ([kind isEqualToString:@"http_request"]) {
        // Imported games run with networking disabled. Complete the pending
        // request explicitly so httpget/httppost follows its failure branch.
        AppendLog(_session, YUME_RUNTIME_LOG_WARNING,
                  "ui.http rejected because imported-game networking is disabled");
        art3m1s_runtime_submit_http_result(_runtime, 0, nullptr, 0);
    } else if ([kind isEqualToString:@"purchase"]) {
        NSString *variable = [payload[@"varname"] isKindOfClass:NSString.class]
            ? payload[@"varname"] : nil;
        if (variable.length > 0)
            art3m1s_runtime_set_string_variable(_runtime, variable.UTF8String, "-1");
    } else if ([kind isEqualToString:@"openbrowser"] ||
               [kind isEqualToString:@"callnative"] ||
               [kind isEqualToString:@"exec"] ||
               [kind isEqualToString:@"shell_execute"]) {
        NSString *line = [NSString stringWithFormat:@"ui.%@ ignored by offline sandbox", kind];
        AppendLog(_session, YUME_RUNTIME_LOG_WARNING, line.UTF8String);
    } else if (![kind isEqualToString:@"caption"] &&
               ![kind isEqualToString:@"statusbar"] &&
               ![kind isEqualToString:@"http_cancel"] &&
               ![kind isEqualToString:@"file_clear_cache"] &&
               ![kind isEqualToString:@"file_wasm_sync"]) {
        NSString *line = [NSString stringWithFormat:@"ui.%@ is not implemented", kind];
        AppendLog(_session, YUME_RUNTIME_LOG_WARNING, line.UTF8String);
    }
}

- (int32_t)pauseEngine {
    if (_runtime == nullptr || _paused) return -1;
    _paused = YES;
    _displayLink.paused = YES;
    [_audioEngine pause];
    [_fullscreenVideo.player pause];
    for (YumeArt3m1sVideoTrack *track in _layerVideos.allValues) [track.player pause];
    art3m1s_runtime_notify_lifecycle(_runtime, 1);
    Emit(_session, YUME_RUNTIME_EVENT_PAUSED, "artemis.paused");
    return 0;
}
- (int32_t)resumeEngine {
    if (_runtime == nullptr || !_paused) return -1;
    art3m1s_runtime_notify_lifecycle(_runtime, 2);
    NSError *audioError = nil;
    if (_audioEngine != nil && !_audioEngine.isRunning &&
        ![_audioEngine startAndReturnError:&audioError]) {
        NSString *line = [NSString stringWithFormat:@"media.audio resume failed: %@",
            audioError.localizedDescription ?: @"unknown"];
        AppendLog(_session, YUME_RUNTIME_LOG_WARNING, line.UTF8String);
    }
    [_fullscreenVideo.player play];
    for (YumeArt3m1sVideoTrack *track in _layerVideos.allValues) [track.player play];
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
    _startRequested = NO;
    [_displayLink invalidate];
    _displayLink = nil;
    [_activeDialog dismissViewControllerAnimated:NO completion:nil];
    _activeDialog = nil;
    [_avoidOverlay removeFromSuperview];
    _avoidOverlay = nil;
    [self stopAllMedia];
    [_audioEngine stop];
    _audioEngine = nil;
    if (_soundInitialized) {
        Sound_Quit();
        _soundInitialized = NO;
    }
    [AVAudioSession.sharedInstance setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    if (_runtime != nullptr) {
        art3m1s_runtime_notify_lifecycle(_runtime, 0);
        art3m1s_runtime_destroy(_runtime);
        _runtime = nullptr;
    }
    ClosePFSArchives(_session);
    _pixels.clear();
    _touchIdentifiers.clear();
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
        configuration->abi_version != YUME_RUNTIME_ABI_VERSION ||
        configuration->content_root == nullptr || configuration->save_root == nullptr ||
        configuration->networking_allowed != 0)
        return -1;
    std::lock_guard<std::mutex> guard(gArt3m1sMutex);
    if (gArt3m1sSession != nullptr) return -2;
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
    gArt3m1sSession = session;
    art3m1s_register_log_callback(Art3m1sLog);
    art3m1s_register_file_reader(Art3m1sRead);
    art3m1s_register_file_writer(Art3m1sWrite);
    art3m1s_register_file_delete(Art3m1sDelete);
    art3m1s_register_file_stat(Art3m1sStat);
    art3m1s_register_media_command_callback(Art3m1sMediaCommand);
    art3m1s_register_ui_command_callback(Art3m1sUICommand);
    art3m1s_register_font_query(Art3m1sFontList);
    art3m1s_register_window_state_query(Art3m1sWindowState);
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
    (void)OnMainSync(^NSInteger {
        [session->view detachSession];
        session->view = nil;
        return 0;
    });
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
