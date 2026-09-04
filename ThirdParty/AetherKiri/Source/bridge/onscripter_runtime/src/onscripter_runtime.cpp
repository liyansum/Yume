#include "onscripter_runtime.h"
#include "onscripter_presentation.h"
#include "onscripter_save_storage.h"

#include <SDL.h>
#include <SDL_mixer.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IOS
#include <SDL_main.h>
#endif
#endif
#include <engine_api.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <limits>
#include <mutex>
#include <new>
#include <stdexcept>
#include <string>
#include <sstream>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

#if defined(ANDROID)
#include <android/log.h>
#include <sys/stat.h>
#endif

// The upstream executable does not expose its final composed surface. Access
// is kept in this one translation unit so the rest of AetherKiri depends only
// on the small Runtime interface above.
#define private public
#define protected public
#include "ONScripter.h"
#undef protected
#undef private
#include "gbk2utf16.h"
#include "sjis2utf16.h"

#undef SDL_FreeSurface

namespace fs = std::filesystem;

Coding2UTF16 *coding2utf16 = nullptr;
std::string g_stdoutpath = "stdout.txt";
std::string g_stderrpath = "stderr.txt";

// Upstream built-in layer effects refer to a process-global `ONScripter ons`.
// Keep the ABI-visible storage without registering a global destructor. The
// embedded host mirrors upstream static teardown on the game thread, then can
// placement-construct a fresh object for a later session.
union ONScripterGlobalStorage {
    ONScripter value;

    ONScripterGlobalStorage() {}
    ~ONScripterGlobalStorage() {}
};

ONScripterGlobalStorage ons;

namespace {

std::mutex g_present_surface_mutex;
SDL_Surface *g_present_surface = nullptr;

struct PublishedFrame {
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t stride_bytes = 0;
    uint64_t serial = 0;
    std::vector<uint8_t> rgba;
};

// ONScripter builds accumulation_surface incrementally. SDL_LockSurface only
// controls SDL's pixel access requirements; it is not a cross-thread lock, so
// copying that live surface from Godot can observe a partially cleared or
// partially composed frame. Mirror completed dirty regions into an immutable
// snapshot only at the end of flushDirect, which is the same presentation
// boundary used by upstream's SDL renderer. Updating every completed region
// is important: menus and text can be built through several rapid partial
// flushes and the final flush may happen before the host asks for another
// frame.
std::mutex g_published_frame_mutex;
PublishedFrame g_published_frame;
uint64_t g_published_frame_serial = 0;
std::atomic<bool> g_system_list_scroll_active{false};
std::atomic<uint32_t> g_system_list_scroll_y{0};
std::atomic<uint64_t> g_system_list_view_revision{0};

void ResetPublishedFrame() {
    std::lock_guard<std::mutex> lock(g_published_frame_mutex);
    g_published_frame = {};
}

// SDL owns one process-wide event queue. Godot and the embedded ONS thread can
// both consume it on mobile, so an event pushed by the bridge can be removed
// by Godot before ONS sees it. Keep host input in a private queue and let the
// ONS event loop consume it directly on every embedded platform.
std::mutex g_host_event_mutex;
std::deque<SDL_Event> g_host_events;
constexpr size_t kMaxHostEvents = 256;

bool PopHostEvent(SDL_Event *event) {
    if (event == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(g_host_event_mutex);
    if (g_host_events.empty()) {
        return false;
    }
    *event = g_host_events.front();
    g_host_events.pop_front();
    return true;
}

void ClearHostEvents() {
    std::lock_guard<std::mutex> lock(g_host_event_mutex);
    g_host_events.clear();
}

bool PushRuntimeEvent(const SDL_Event &event) {
    std::lock_guard<std::mutex> lock(g_host_event_mutex);
    // Only the newest cursor position matters until a button/key boundary is
    // reached. Coalescing keeps a fast finger drag from delaying its release.
    if (event.type == SDL_MOUSEMOTION && !g_host_events.empty() &&
        g_host_events.back().type == SDL_MOUSEMOTION) {
        g_host_events.back() = event;
        return true;
    }
    if (g_host_events.size() >= kMaxHostEvents) {
        auto motion = std::find_if(
            g_host_events.begin(), g_host_events.end(),
            [](const SDL_Event &queued) {
                return queued.type == SDL_MOUSEMOTION;
            });
        if (motion != g_host_events.end()) {
            g_host_events.erase(motion);
        } else {
            g_host_events.pop_front();
        }
    }
    g_host_events.push_back(event);
    return true;
}

class EmbeddedMovieHost {
public:
    virtual ~EmbeddedMovieHost() = default;
    virtual int play_video(const char *filename, bool click_to_skip,
                           bool loop) = 0;
    virtual void stop_video() = 0;
    virtual void configure_video(bool has_position, int x, int y, int width,
                                 int height, bool asynchronous) = 0;
};

std::mutex g_movie_host_mutex;
EmbeddedMovieHost *g_movie_host = nullptr;

} // namespace

extern "C" void aetherkiri_onscripter_begin_system_list_scroll() {
    g_system_list_scroll_y.store(0);
    g_system_list_scroll_active.store(true);
    g_system_list_view_revision.fetch_add(1);
}

extern "C" void aetherkiri_onscripter_end_system_list_scroll() {
    g_system_list_scroll_active.store(false);
    g_system_list_scroll_y.store(0);
    g_system_list_view_revision.fetch_add(1);
}

extern "C" int aetherkiri_onscripter_wait_event(SDL_Event *event) {
    while (event != nullptr) {
        // Only Runtime::shutdown injects a quit event into the private queue.
        // SDL's process-wide queue belongs to Godot and can receive lifecycle
        // SDL_QUIT events while the Android activity is being initialized.
        // Passing one of those through would make ONScripter run `end`.
        if (PopHostEvent(event)) {
            if (event->type == SDL_QUIT) {
                aetherkiri_onscripter_host_exit(0, __FILE__, __LINE__);
            }
            return 1;
        }
        if (SDL_WaitEventTimeout(event, 8) == 1) {
            if (event->type == SDL_QUIT) {
                continue;
            }
            return 1;
        }
    }
    return 0;
}

extern "C" void SDLCALL
aetherkiri_onscripter_free_surface(SDL_Surface *surface) {
    std::lock_guard<std::mutex> lock(g_present_surface_mutex);
    if (surface == g_present_surface) {
        g_present_surface = nullptr;
        ResetPublishedFrame();
    }
    SDL_FreeSurface(surface);
}

extern "C" void
aetherkiri_onscripter_publish_frame(SDL_Surface *surface,
                                    const SDL_Rect *dirty_rect) {
    if (surface == nullptr || surface->w <= 0 || surface->h <= 0 ||
        surface->pixels == nullptr || surface->format == nullptr) {
        return;
    }

    const uint32_t width = static_cast<uint32_t>(surface->w);
    const uint32_t height = static_cast<uint32_t>(surface->h);
    if (width > std::numeric_limits<uint32_t>::max() / 4u) {
        return;
    }
    const uint32_t stride = width * 4u;
    if (height > 0 &&
        static_cast<size_t>(stride) >
            std::numeric_limits<size_t>::max() / height) {
        return;
    }

    std::lock_guard<std::mutex> lock(g_published_frame_mutex);
    const bool initialize =
        g_published_frame.width != width ||
        g_published_frame.height != height ||
        g_published_frame.stride_bytes != stride ||
        g_published_frame.rgba.size() !=
            static_cast<size_t>(stride) * height;

    int64_t left = 0;
    int64_t top = 0;
    int64_t right = surface->w;
    int64_t bottom = surface->h;
    if (!initialize && dirty_rect != nullptr) {
        left = std::max<int64_t>(0, dirty_rect->x);
        top = std::max<int64_t>(0, dirty_rect->y);
        right = std::min<int64_t>(
            surface->w,
            static_cast<int64_t>(dirty_rect->x) +
                std::max<int64_t>(0, dirty_rect->w));
        bottom = std::min<int64_t>(
            surface->h,
            static_cast<int64_t>(dirty_rect->y) +
                std::max<int64_t>(0, dirty_rect->h));
        if (right <= left || bottom <= top) {
            return;
        }
    }

    std::vector<uint8_t> initialized_rgba;
    uint8_t *destination = nullptr;
    if (initialize) {
        initialized_rgba.resize(static_cast<size_t>(stride) * height);
        destination = initialized_rgba.data();
    } else {
        destination = g_published_frame.rgba.data() +
            static_cast<size_t>(top) * stride +
            static_cast<size_t>(left) * 4u;
    }

    if (SDL_LockSurface(surface) != 0) {
        return;
    }
    const auto *source = static_cast<const uint8_t *>(surface->pixels) +
        static_cast<size_t>(top) * surface->pitch +
        static_cast<size_t>(left) * surface->format->BytesPerPixel;
    const int convert_result = SDL_ConvertPixels(
        static_cast<int>(right - left), static_cast<int>(bottom - top),
        surface->format->format, source, surface->pitch,
        SDL_PIXELFORMAT_RGBA32, destination,
        static_cast<int>(stride));
    SDL_UnlockSurface(surface);
    if (convert_result != 0) {
        return;
    }

    if (initialize) {
        g_published_frame.width = width;
        g_published_frame.height = height;
        g_published_frame.stride_bytes = stride;
        g_published_frame.rgba = std::move(initialized_rgba);
    }
    g_published_frame.serial = ++g_published_frame_serial;
}

extern "C" int aetherkiri_onscripter_play_video(
    const char *filename, int click_to_skip, int loop) {
    EmbeddedMovieHost *host = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_movie_host_mutex);
        host = g_movie_host;
    }
    return host != nullptr
        ? host->play_video(filename, click_to_skip != 0, loop != 0)
        : 0;
}

extern "C" void aetherkiri_onscripter_stop_video() {
    EmbeddedMovieHost *host = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_movie_host_mutex);
        host = g_movie_host;
    }
    if (host != nullptr) {
        host->stop_video();
    }
}

extern "C" void aetherkiri_onscripter_configure_video(
    int has_position, int x, int y, int width, int height,
    int asynchronous) {
    EmbeddedMovieHost *host = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_movie_host_mutex);
        host = g_movie_host;
    }
    if (host != nullptr) {
        host->configure_video(has_position != 0, x, y, width, height,
                              asynchronous != 0);
    }
}

#if defined(ANDROID)
#undef fopen
#undef mkdir

extern "C" FILE *fopen_ons(const char *path, const char *mode) {
    return std::fopen(path, mode);
}

extern "C" int stat_ons(const char *path, struct stat *stat_buffer) {
    return ::stat(path, stat_buffer);
}

extern "C" int mkdir_ons(const char *path, mode_t mode) {
    return ::mkdir(path, mode);
}
#endif

namespace {

struct HostExit final {
    int code = 0;
};

std::mutex g_current_directory_mutex;

std::string EnsureTrailingSeparator(const std::string &path) {
    if (path.empty()) {
        return path;
    }
    const char last = path.back();
    if (last == '/' || last == '\\') {
        return path;
    }
    return path + fs::path::preferred_separator;
}

std::string StableGameDirectoryName(const fs::path &root) {
    const std::string normalized = root.lexically_normal().generic_string();
    uint64_t hash = 1469598103934665603ull;
    for (const unsigned char value : normalized) {
        hash ^= static_cast<uint64_t>(value);
        hash *= 1099511628211ull;
    }
    std::string name = root.filename().string();
    if (name.empty()) {
        name = "game";
    }
    for (char &value : name) {
        const unsigned char byte = static_cast<unsigned char>(value);
        if (!(std::isalnum(byte) || value == '-' || value == '_')) {
            value = '_';
        }
    }
    char suffix[24] = {};
    std::snprintf(suffix, sizeof(suffix), "-%016llx",
                  static_cast<unsigned long long>(hash));
    return name + suffix;
}

bool HasScriptMarker(const fs::path &root) {
    static constexpr const char *kMarkers[] = {
        "0.txt", "00.txt", "nscr_sec.dat", "nscript.___",
        "nscript.dat", "onscript.nt2", "onscript.nt3",
    };
    std::error_code error;
    for (const fs::directory_entry &entry : fs::directory_iterator(root, error)) {
        if (error) break;
        if (!entry.is_regular_file(error)) {
            error.clear();
            continue;
        }
        std::string name = entry.path().filename().string();
        std::transform(name.begin(), name.end(), name.begin(),
                       [](unsigned char byte) {
                           return static_cast<char>(std::tolower(byte));
                       });
        for (const char *marker : kMarkers) {
            if (name == marker) return true;
        }
    }
    return false;
}

fs::path FindRootFileCaseInsensitive(const fs::path &root,
                                     const std::string &requested_name) {
    std::string requested = requested_name;
    std::transform(requested.begin(), requested.end(), requested.begin(),
                   [](unsigned char byte) {
                       return static_cast<char>(std::tolower(byte));
                   });
    std::error_code error;
    for (const fs::directory_entry &entry : fs::directory_iterator(root, error)) {
        if (error) break;
        if (!entry.is_regular_file(error)) {
            error.clear();
            continue;
        }
        std::string name = entry.path().filename().string();
        std::transform(name.begin(), name.end(), name.begin(),
                       [](unsigned char byte) {
                           return static_cast<char>(std::tolower(byte));
                       });
        if (name == requested) return entry.path();
    }
    return {};
}

fs::path FindONSKeyExecutable(const fs::path &root) {
    struct Candidate {
        fs::path path;
        uintmax_t size = 0;
        bool helper = false;
    };
    std::vector<Candidate> candidates;
    std::error_code error;
    for (const fs::directory_entry &entry : fs::directory_iterator(root, error)) {
        if (error) break;
        if (!entry.is_regular_file(error)) {
            error.clear();
            continue;
        }
        std::string extension = entry.path().extension().string();
        std::transform(extension.begin(), extension.end(), extension.begin(),
                       [](unsigned char byte) {
                           return static_cast<char>(std::tolower(byte));
                       });
        if (extension != ".exe") continue;
        std::string name = entry.path().filename().string();
        std::transform(name.begin(), name.end(), name.begin(),
                       [](unsigned char byte) {
                           return static_cast<char>(std::tolower(byte));
                       });
        const bool helper = name.find("config") != std::string::npos ||
            name.find("setup") != std::string::npos ||
            name.find("unins") != std::string::npos;
        const uintmax_t size = entry.file_size(error);
        if (error) {
            error.clear();
            continue;
        }
        candidates.push_back({entry.path(), size, helper});
    }
    std::sort(candidates.begin(), candidates.end(),
              [](const Candidate &left, const Candidate &right) {
                  if (left.helper != right.helper) return !left.helper;
                  if (left.size != right.size) return left.size > right.size;
                  return left.path.filename().string() < right.path.filename().string();
              });
    return candidates.empty() ? fs::path() : candidates.front().path;
}

fs::path FindScriptForEncodingDetection(const fs::path &root,
                                        int *encryption_mode) {
    struct Marker {
        const char *name;
        int mode;
    };
    static constexpr Marker kMarkers[] = {
        {"0.txt", 0}, {"00.txt", 0}, {"nscr_sec.dat", 2},
        {"nscript.___", 3}, {"nscript.dat", 1},
        {"onscript.nt2", 4}, {"onscript.nt3", 5},
    };
    std::error_code error;
    for (const Marker &marker : kMarkers) {
        for (const fs::directory_entry &entry :
             fs::directory_iterator(root, error)) {
            if (error) break;
            std::string name = entry.path().filename().string();
            std::transform(name.begin(), name.end(), name.begin(),
                           [](unsigned char byte) {
                               return static_cast<char>(std::tolower(byte));
                           });
            if (name == marker.name && entry.is_regular_file(error)) {
                if (encryption_mode != nullptr) {
                    *encryption_mode = marker.mode;
                }
                return entry.path();
            }
            error.clear();
        }
        error.clear();
    }
    return {};
}

bool LoadONSKeyTable(const fs::path &executable,
                     std::array<uint8_t, 256> *key_table) {
    if (executable.empty() || key_table == nullptr) return false;
    std::ifstream stream(executable, std::ios::binary);
    if (!stream) return false;

    // NScripter's key is the first 256-byte window whose values are all
    // unique. The table maps each byte in that permutation back to its
    // position. Keep only the suffix following the most recent duplicate,
    // which is equivalent to upstream's circular-buffer search.
    std::deque<uint8_t> unique_window;
    std::array<bool, 256> present{};
    char raw = 0;
    while (stream.get(raw)) {
        const uint8_t byte = static_cast<uint8_t>(raw);
        if (present[byte]) {
            while (!unique_window.empty()) {
                const uint8_t removed = unique_window.front();
                unique_window.pop_front();
                present[removed] = false;
                if (removed == byte) break;
            }
        }
        unique_window.push_back(byte);
        present[byte] = true;
        if (unique_window.size() == key_table->size()) {
            uint16_t position = 0;
            for (const uint8_t value : unique_window) {
                (*key_table)[value] = static_cast<uint8_t>(position++);
            }
            return true;
        }
    }
    return false;
}

bool IsValidUTF8(const std::vector<uint8_t> &bytes, bool *has_non_ascii) {
    bool non_ascii = false;
    for (size_t index = 0; index < bytes.size();) {
        const uint8_t first = bytes[index++];
        if (first < 0x80) continue;
        non_ascii = true;
        size_t continuation_count = 0;
        uint32_t scalar = 0;
        if ((first & 0xe0) == 0xc0) {
            continuation_count = 1;
            scalar = first & 0x1f;
        } else if ((first & 0xf0) == 0xe0) {
            continuation_count = 2;
            scalar = first & 0x0f;
        } else if ((first & 0xf8) == 0xf0) {
            continuation_count = 3;
            scalar = first & 0x07;
        } else {
            return false;
        }
        if (index + continuation_count > bytes.size()) return false;
        for (size_t offset = 0; offset < continuation_count; ++offset) {
            const uint8_t continuation = bytes[index++];
            if ((continuation & 0xc0) != 0x80) return false;
            scalar = (scalar << 6) | (continuation & 0x3f);
        }
        if ((continuation_count == 1 && scalar < 0x80) ||
            (continuation_count == 2 && scalar < 0x800) ||
            (continuation_count == 3 && scalar < 0x10000) ||
            scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) {
            return false;
        }
    }
    if (has_non_ascii != nullptr) *has_non_ascii = non_ascii;
    return true;
}

std::string DetectScriptEncoding(const fs::path &root) {
    int encryption_mode = 0;
    const fs::path script = FindScriptForEncodingDetection(
        root, &encryption_mode);
    std::ifstream stream(script, std::ios::binary);
    if (script.empty() || !stream) return "gbk";

    std::array<uint8_t, 256> key_table{};
    if (encryption_mode == 3 &&
        !LoadONSKeyTable(FindONSKeyExecutable(root), &key_table)) {
        // nscript.___ is most commonly produced by the original Japanese
        // NScripter toolchain. If its EXE/key cannot be inspected, SJIS is a
        // safer fallback than interpreting undeciphered bytes as GBK.
        return "sjis";
    }

    uint32_t nt3_key = 0;
    uint64_t nt3_payload_size = 0;
    if (encryption_mode == 5) {
        stream.seekg(0, std::ios::end);
        const std::streamoff total_size = stream.tellg();
        if (total_size <= 0x920) return "gbk";
        stream.seekg(0x91c, std::ios::beg);
        std::array<uint8_t, 4> key_bytes{};
        stream.read(reinterpret_cast<char *>(key_bytes.data()),
                    static_cast<std::streamsize>(key_bytes.size()));
        if (stream.gcount() != static_cast<std::streamsize>(key_bytes.size())) {
            return "gbk";
        }
        nt3_key = static_cast<uint32_t>(key_bytes[0]) |
            (static_cast<uint32_t>(key_bytes[1]) << 8u) |
            (static_cast<uint32_t>(key_bytes[2]) << 16u) |
            (static_cast<uint32_t>(key_bytes[3]) << 24u);
        nt3_payload_size = static_cast<uint64_t>(total_size - 0x920);
        stream.clear();
        stream.seekg(0x920, std::ios::beg);
    }

    constexpr size_t kSampleLimit = 128u * 1024u;
    std::vector<uint8_t> bytes;
    bytes.reserve(kSampleLimit);
    char value = 0;
    size_t index = 0;
    static constexpr uint8_t kSecureMagic[] = {
        0x79, 0x57, 0x0d, 0x80, 0x04,
    };
    while (bytes.size() < kSampleLimit && stream.get(value)) {
        uint8_t byte = static_cast<uint8_t>(value);
        if (encryption_mode == 1) {
            byte ^= 0x84;
        } else if (encryption_mode == 2) {
            byte ^= kSecureMagic[index % 5u];
        } else if (encryption_mode == 3) {
            byte = static_cast<uint8_t>(key_table[byte] ^ 0x84u);
        } else if (encryption_mode == 4) {
            byte ^= (0x85 & 0x97);
            byte = static_cast<uint8_t>(byte - 1u);
        } else if (encryption_mode == 5) {
            const uint64_t position = index + 1u;
            const uint8_t encrypted = byte;
            nt3_key ^= encrypted;
            nt3_key += static_cast<uint32_t>(
                static_cast<uint64_t>(encrypted) *
                    (nt3_payload_size + 1u - position) +
                0x5d588b65u);
            byte = static_cast<uint8_t>(encrypted ^ nt3_key);
        }
        bytes.push_back(byte);
        ++index;
    }
    if (bytes.size() >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
        return "utf8";
    }
    bool has_non_ascii = false;
    if (IsValidUTF8(bytes, &has_non_ascii) && has_non_ascii) return "utf8";

    size_t sjis_evidence = 0;
    size_t gbk_evidence = 0;
    size_t half_width_run = 0;
    for (size_t offset = 0; offset < bytes.size();) {
        const uint8_t first = bytes[offset];
        if (first < 0x80) {
            half_width_run = 0;
            ++offset;
            continue;
        }
        if (((first >= 0x81 && first <= 0x9f) ||
             (first >= 0xe0 && first <= 0xef)) &&
            offset + 1 < bytes.size()) {
            const uint8_t second = bytes[offset + 1];
            if ((second >= 0x40 && second <= 0x7e) ||
                (second >= 0x80 && second <= 0xfc)) {
                sjis_evidence += first == 0x82 ? 5u :
                    (first == 0x83 ? 4u : 2u);
            }
        }
        if (first >= 0xa1 && first <= 0xdf) {
            ++half_width_run;
        } else {
            half_width_run = 0;
        }
        if (half_width_run > 2) gbk_evidence += 2;

        if (first >= 0x81 && first <= 0xfe &&
            offset + 1 < bytes.size()) {
            const uint8_t second = bytes[offset + 1];
            if ((second >= 0x40 && second <= 0x7e) ||
                (second >= 0x80 && second <= 0xfe)) {
                if (first >= 0xa1) gbk_evidence += 3;
                offset += 2;
                continue;
            }
        }
        ++offset;
    }
    return sjis_evidence > gbk_evidence ? "sjis" : "gbk";
}

struct PresentationAspectRatio {
    uint32_t width = 0;
    uint32_t height = 0;
};

uint32_t ReadPositiveSetting(const std::string &line,
                             const char *setting_name) {
    const std::string prefix = std::string(setting_name) + "=";
    if (line.rfind(prefix, 0) != 0) {
        return 0;
    }
    try {
        const unsigned long value = std::stoul(line.substr(prefix.size()));
        return value > 0 &&
                value <= std::numeric_limits<uint32_t>::max()
            ? static_cast<uint32_t>(value) : 0;
    } catch (...) {
        return 0;
    }
}

PresentationAspectRatio ReadPresentationAspectRatio(const fs::path &root) {
    std::error_code error;
    if (!fs::is_regular_file(root / "ons.wide", error)) {
        return {};
    }

    // This marker is produced by Android ONS packages whose wrapper defaults
    // to a 16:9 view over a 4:3 NScripter canvas. Respect an accompanying
    // app_settings.ini override when present.
    PresentationAspectRatio result{16, 9};
    std::ifstream settings(root / "app_settings.ini");
    if (!settings) {
        return result;
    }
    uint32_t configured_width = 0;
    uint32_t configured_height = 0;
    std::string line;
    while (std::getline(settings, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (configured_width == 0) {
            configured_width = ReadPositiveSetting(line, "VideoXRatio");
        }
        if (configured_height == 0) {
            configured_height = ReadPositiveSetting(line, "VideoYRatio");
        }
    }
    if (configured_width > 0 && configured_height > 0) {
        result.width = configured_width;
        result.height = configured_height;
    }
    return result;
}

fs::path NormalizeGameRoot(const std::string &path) {
    fs::path root = fs::u8path(path);
    std::error_code error;
    if (fs::is_regular_file(root, error)) {
        root = root.parent_path();
    }
    return fs::absolute(root, error).lexically_normal();
}

SDL_Keycode WindowsVirtualKeyToSdl(int key_code) {
    if (key_code >= 0x30 && key_code <= 0x39) {
        return static_cast<SDL_Keycode>(SDLK_0 + key_code - 0x30);
    }
    if (key_code >= 0x41 && key_code <= 0x5a) {
        return static_cast<SDL_Keycode>(SDLK_a + key_code - 0x41);
    }
    if (key_code >= 0x70 && key_code <= 0x7b) {
        return static_cast<SDL_Keycode>(SDLK_F1 + key_code - 0x70);
    }
    switch (key_code) {
    case 0x08: return SDLK_BACKSPACE;
    case 0x09: return SDLK_TAB;
    case 0x0d: return SDLK_RETURN;
    case 0x10: return SDLK_LSHIFT;
    case 0x11: return SDLK_LCTRL;
    case 0x12: return SDLK_LALT;
    case 0x13: return SDLK_PAUSE;
    case 0x14: return SDLK_CAPSLOCK;
    case 0x1b: return SDLK_ESCAPE;
    case 0x20: return SDLK_SPACE;
    case 0x21: return SDLK_PAGEUP;
    case 0x22: return SDLK_PAGEDOWN;
    case 0x23: return SDLK_END;
    case 0x24: return SDLK_HOME;
    case 0x25: return SDLK_LEFT;
    case 0x26: return SDLK_UP;
    case 0x27: return SDLK_RIGHT;
    case 0x28: return SDLK_DOWN;
    case 0x2c: return SDLK_PRINTSCREEN;
    case 0x2d: return SDLK_INSERT;
    case 0x2e: return SDLK_DELETE;
    default:
        return key_code >= 0x20 && key_code <= 0x7e
            ? static_cast<SDL_Keycode>(key_code)
            : SDLK_UNKNOWN;
    }
}

SDL_Keymod EngineModifiersToSdl(int modifiers) {
    int result = KMOD_NONE;
    if ((modifiers & 0x01) != 0) result |= KMOD_SHIFT;
    if ((modifiers & 0x02) != 0) result |= KMOD_ALT;
    if ((modifiers & 0x04) != 0) result |= KMOD_CTRL;
    return static_cast<SDL_Keymod>(result);
}

std::string Utf8FromCodepoint(uint32_t codepoint) {
    std::string output;
    if (codepoint <= 0x7f) {
        output.push_back(static_cast<char>(codepoint));
    } else if (codepoint <= 0x7ff) {
        output.push_back(static_cast<char>(0xc0u | (codepoint >> 6u)));
        output.push_back(static_cast<char>(0x80u | (codepoint & 0x3fu)));
    } else if (codepoint <= 0xffff) {
        output.push_back(static_cast<char>(0xe0u | (codepoint >> 12u)));
        output.push_back(static_cast<char>(0x80u | ((codepoint >> 6u) & 0x3fu)));
        output.push_back(static_cast<char>(0x80u | (codepoint & 0x3fu)));
    } else if (codepoint <= 0x10ffff) {
        output.push_back(static_cast<char>(0xf0u | (codepoint >> 18u)));
        output.push_back(static_cast<char>(0x80u | ((codepoint >> 12u) & 0x3fu)));
        output.push_back(static_cast<char>(0x80u | ((codepoint >> 6u) & 0x3fu)));
        output.push_back(static_cast<char>(0x80u | (codepoint & 0x3fu)));
    }
    return output;
}

} // namespace

extern "C" [[noreturn]] void aetherkiri_onscripter_host_exit(
    int code, const char *source_file, int source_line) {
#if defined(ANDROID)
    __android_log_print(ANDROID_LOG_INFO, "AetherKiriONS",
                        "embedded exit code=%d source=%s:%d", code,
                        source_file != nullptr ? source_file : "unknown",
                        source_line);
#else
    (void)source_file;
    (void)source_line;
#endif
    throw HostExit{code};
}

namespace aetherkiri::onscripter {

namespace {

void LogRuntimeEvent(const std::string &message) {
#if defined(ANDROID)
    __android_log_write(ANDROID_LOG_INFO, "AetherKiriONS", message.c_str());
#else
    (void)message;
#endif
}

} // namespace

struct Runtime::Impl final : EmbeddedMovieHost {
    struct MovieConfiguration {
        bool has_position = false;
        bool asynchronous = false;
        int x = 0;
        int y = 0;
        int width = 0;
        int height = 0;
    };

    mutable std::mutex mutex;
    mutable std::mutex media_mutex;
    std::thread game_thread;
    std::atomic<StartupState> startup{StartupState::Idle};
    std::atomic<bool> initialized{false};
    std::atomic<bool> game_open{false};
    std::atomic<bool> ended{false};
    std::atomic<bool> stop_requested{false};
    std::atomic<double> input_device_scale_x{1.0};
    std::atomic<double> input_device_scale_y{1.0};
    std::atomic<int> input_device_offset_x{0};
    std::atomic<int> input_device_offset_y{0};
    std::atomic<uint32_t> presentation_source_width{0};
    std::atomic<uint32_t> presentation_source_height{0};
    std::atomic<uint32_t> presentation_x{0};
    std::atomic<uint32_t> presentation_y{0};
    std::atomic<uint32_t> presentation_width{0};
    std::atomic<uint32_t> presentation_height{0};
    std::atomic<int> system_list_touch_pointer{-1};
    std::atomic<bool> system_list_touch_scrolled{false};
    ONScripter *ons = nullptr;
    std::string writable_path;
    std::string cache_path;
    std::string game_root;
    std::string default_font;
    std::string encoding = "gbk";
    std::string configured_encoding;
    std::string error;
    std::deque<std::string> logs;
    engine_handle_t media_engine = nullptr;
    engine_media_handle_t media = nullptr;
    MediaState latest_media_state;
    std::vector<uint8_t> media_rgba;
    bool media_is_script_movie = false;
    bool media_overlay_active = false;
    bool media_loop = false;
    bool media_click_to_skip = false;
    std::atomic<bool> media_skip_requested{false};
    MovieConfiguration next_movie_configuration;
    MovieConfiguration active_movie_configuration;

    void append_log(std::string message) {
        LogRuntimeEvent(message);
        std::lock_guard<std::mutex> lock(mutex);
        logs.emplace_back(std::move(message));
        while (logs.size() > 256) {
            logs.pop_front();
        }
    }

    void set_error(std::string message) {
        LogRuntimeEvent("[ONScripter Yuri] " + message);
        {
            std::lock_guard<std::mutex> lock(mutex);
            error = std::move(message);
            logs.emplace_back("[ONScripter Yuri] " + error);
        }
        startup.store(StartupState::Failed);
        game_open.store(false);
    }

    void set_media_error(std::string message) {
        LogRuntimeEvent("[ONScripter Yuri media] " + message);
        std::lock_guard<std::mutex> lock(mutex);
        error = std::move(message);
        logs.emplace_back("[ONScripter Yuri media] " + error);
    }

    std::string engine_media_error(const std::string &fallback) const {
        if (media_engine == nullptr) {
            return fallback;
        }
        const char *message = engine_get_last_error(media_engine);
        return message != nullptr && *message != '\0'
            ? std::string(message)
            : fallback;
    }

    bool initialize_media_engine() {
        if (media_engine != nullptr) {
            return true;
        }
        engine_create_desc_t description{};
        description.struct_size = sizeof(description);
        description.api_version = ENGINE_API_VERSION;
        description.writable_path_utf8 = writable_path.c_str();
        description.cache_path_utf8 = cache_path.c_str();
        const engine_result_t result =
            engine_create(&description, &media_engine);
        if (result != ENGINE_RESULT_OK || media_engine == nullptr) {
            media_engine = nullptr;
            set_media_error(
                "failed to initialize the FFmpeg media host");
            return false;
        }
        return true;
    }

    void close_media_locked() {
        if (media != nullptr) {
            engine_media_destroy(media);
            media = nullptr;
        }
        latest_media_state = {};
        media_rgba.clear();
        media_overlay_active = false;
        media_is_script_movie = false;
        media_loop = false;
        media_click_to_skip = false;
        media_skip_requested.store(false);
    }

    void close_media() {
        std::lock_guard<std::mutex> media_lock(media_mutex);
        close_media_locked();
    }

    bool open_media_locked(const fs::path &path, bool script_movie) {
        close_media_locked();
        if (media_engine == nullptr && !initialize_media_engine()) {
            return false;
        }
        const std::string media_path = path.u8string();
        const engine_result_t result =
            engine_media_open(media_engine, media_path.c_str(), &media);
        if (result != ENGINE_RESULT_OK || media == nullptr) {
            media = nullptr;
            set_media_error(engine_media_error(
                "FFmpeg could not open the media file: " + media_path));
            return false;
        }
        media_is_script_movie = script_movie;
        return true;
    }

    fs::path resolve_script_media(const char *filename) {
        if (filename == nullptr || *filename == '\0') {
            return {};
        }
        const fs::path requested = fs::u8path(filename);
        std::error_code error_code;
        if (requested.is_absolute() &&
            fs::is_regular_file(requested, error_code)) {
            return requested;
        }
        error_code.clear();
        const fs::path direct = fs::u8path(game_root) / requested;
        if (fs::is_regular_file(direct, error_code)) {
            return direct;
        }
        if (ons == nullptr || ons->script_h.cBR == nullptr) {
            return {};
        }

        const size_t length = ons->script_h.cBR->getFileLength(filename);
        if (length == 0) {
            return {};
        }
        std::string extension = requested.extension().string();
        if (extension.size() > 16 ||
            !std::all_of(extension.begin(), extension.end(),
                         [](unsigned char value) {
                             return std::isalnum(value) || value == '.';
                         })) {
            extension = ".media";
        }
        const fs::path media_cache =
            fs::u8path(cache_path.empty() ? writable_path : cache_path) /
            "onscripter_media";
        fs::create_directories(media_cache, error_code);
        if (error_code) {
            set_media_error(
                "failed to create the ONScripter media cache");
            return {};
        }
        const std::string cache_key =
            StableGameDirectoryName(fs::u8path(game_root) / requested);
        const fs::path extracted = media_cache / (cache_key + extension);
        error_code.clear();
        if (fs::is_regular_file(extracted, error_code) &&
            fs::file_size(extracted, error_code) == length && !error_code) {
            return extracted;
        }

        std::vector<unsigned char> bytes(length);
        if (ons->script_h.cBR->getFile(filename, bytes.data()) != length) {
            set_media_error(
                "failed to extract archived movie: " +
                std::string(filename));
            return {};
        }
        std::ofstream output(extracted, std::ios::binary | std::ios::trunc);
        output.write(reinterpret_cast<const char *>(bytes.data()),
                     static_cast<std::streamsize>(bytes.size()));
        if (!output.good()) {
            set_media_error(
                "failed to write the extracted movie cache");
            return {};
        }
        return extracted;
    }

    bool update_media_locked(bool allow_loop_restart) {
        if (media == nullptr) {
            return false;
        }
        engine_media_state_t state{};
        state.struct_size = sizeof(state);
        engine_result_t result = engine_media_get_state(media, &state);
        if (result != ENGINE_RESULT_OK) {
            set_media_error(engine_media_error(
                "failed to query FFmpeg media state"));
            return false;
        }
        if (state.status == ENGINE_MEDIA_STATUS_ENDED && media_loop &&
            allow_loop_restart) {
            if (engine_media_seek(media, 0) == ENGINE_RESULT_OK &&
                engine_media_play(media) == ENGINE_RESULT_OK) {
                state.status = ENGINE_MEDIA_STATUS_PLAYING;
                state.position_ms = 0;
            }
        }

        const size_t byte_count =
            static_cast<size_t>(state.width) *
            static_cast<size_t>(state.height) * 4u;
        const bool frame_changed =
            state.frame_ready != 0 && byte_count > 0 &&
            (media_rgba.size() != byte_count ||
             latest_media_state.frame_serial != state.frame_serial);

        latest_media_state.status = static_cast<int>(state.status);
        latest_media_state.position_ms = state.position_ms;
        latest_media_state.duration_ms = state.duration_ms;
        latest_media_state.playback_rate = state.playback_rate;
        latest_media_state.width = state.width;
        latest_media_state.height = state.height;
        latest_media_state.frame_serial = state.frame_serial;
        latest_media_state.frame_ready = state.frame_ready != 0;
        latest_media_state.seekable = state.seekable != 0;
        latest_media_state.has_audio = state.has_audio != 0;
        latest_media_state.has_video = state.has_video != 0;

        if (frame_changed) {
            media_rgba.resize(byte_count);
            engine_frame_desc_t frame{};
            frame.struct_size = sizeof(frame);
            result = engine_media_read_frame_rgba(
                media, media_rgba.data(), media_rgba.size(), &frame);
            if (result == ENGINE_RESULT_OK) {
                latest_media_state.width = frame.width;
                latest_media_state.height = frame.height;
                latest_media_state.frame_serial = frame.frame_serial;
                latest_media_state.frame_ready = true;
            }
        }
        if (media_is_script_movie &&
            state.status == ENGINE_MEDIA_STATUS_ENDED && !media_loop) {
            media_overlay_active = false;
        }
        return true;
    }

    bool poll_movie_events(bool click_to_skip) {
        const auto handle_event = [this, click_to_skip](
                                      const SDL_Event &event) {
            if (event.type == SDL_QUIT) {
                return true;
            }
            if (!click_to_skip) {
                return false;
            }
            if (event.type == SDL_MOUSEBUTTONUP) {
                media_skip_requested.store(true);
            } else if (event.type == SDL_KEYUP) {
                const SDL_Keycode key = event.key.keysym.sym;
                if (key == SDLK_RETURN || key == SDLK_SPACE ||
                    key == SDLK_ESCAPE) {
                    media_skip_requested.store(true);
                }
            }
            return false;
        };
        SDL_Event event{};
        while (PopHostEvent(&event)) {
            // A private SDL_QUIT is Runtime::shutdown waking an active movie.
            if (event.type == SDL_QUIT) {
                aetherkiri_onscripter_host_exit(0, __FILE__, __LINE__);
            }
            if (handle_event(event)) {
                return true;
            }
        }
        while (SDL_PollEvent(&event)) {
            // Godot owns SDL's global Android activity events. In particular,
            // never let a transient SDL_QUIT terminate a script movie/game.
            if (event.type == SDL_QUIT) {
                continue;
            }
            if (handle_event(event)) {
                return true;
            }
        }
        return false;
    }

    int play_video(const char *filename, bool click_to_skip,
                   bool loop) override {
        const fs::path path = resolve_script_media(filename);
        if (path.empty()) {
            set_media_error(
                "movie file is unavailable: " +
                std::string(filename != nullptr ? filename : ""));
            next_movie_configuration = {};
            return 0;
        }

        MovieConfiguration configuration = next_movie_configuration;
        next_movie_configuration = {};
        {
            std::lock_guard<std::mutex> media_lock(media_mutex);
            if (!open_media_locked(path, true)) {
                return 0;
            }
            active_movie_configuration = configuration;
            media_overlay_active = true;
            media_loop = loop;
            media_click_to_skip = click_to_skip;
            media_skip_requested.store(false);
            if (engine_media_play(media) != ENGINE_RESULT_OK) {
                set_media_error(engine_media_error(
                    "FFmpeg could not start movie playback"));
                close_media_locked();
                return 0;
            }
        }
        append_log("[ONScripter Yuri media] playing: " +
                   path.u8string());
        if (configuration.asynchronous) {
            return 0;
        }

        while (!stop_requested.load()) {
            if (poll_movie_events(click_to_skip)) {
                stop_requested.store(true);
                close_media();
                return 1;
            }
            if (click_to_skip && media_skip_requested.load()) {
                close_media();
                return 0;
            }
            bool ended_now = false;
            {
                std::lock_guard<std::mutex> media_lock(media_mutex);
                if (media == nullptr) {
                    return 0;
                }
                if (!update_media_locked(true)) {
                    close_media_locked();
                    return 0;
                }
                ended_now =
                    latest_media_state.status == ENGINE_MEDIA_STATUS_ENDED &&
                    !media_loop;
            }
            if (ended_now) {
                close_media();
                return 0;
            }
            SDL_Delay(5);
        }
        close_media();
        return 1;
    }

    void stop_video() override {
        bool stopped = false;
        {
            std::lock_guard<std::mutex> media_lock(media_mutex);
            stopped = media != nullptr;
            close_media_locked();
        }
        if (stopped) {
            append_log("[ONScripter Yuri media] movie stop");
        }
    }

    void configure_video(bool has_position, int x, int y, int width,
                         int height, bool asynchronous) override {
        next_movie_configuration.has_position = has_position;
        next_movie_configuration.asynchronous = asynchronous;
        next_movie_configuration.x = x;
        next_movie_configuration.y = y;
        next_movie_configuration.width = width;
        next_movie_configuration.height = height;
    }

    void overlay_movie(Frame &frame) {
        std::lock_guard<std::mutex> media_lock(media_mutex);
        if (!media_overlay_active || !latest_media_state.frame_ready ||
            media_rgba.empty() || latest_media_state.width == 0 ||
            latest_media_state.height == 0 || frame.rgba.empty()) {
            return;
        }

        int target_x = 0;
        int target_y = 0;
        int target_width = static_cast<int>(frame.width);
        int target_height = static_cast<int>(frame.height);
        if (active_movie_configuration.has_position) {
            target_x = active_movie_configuration.x;
            target_y = active_movie_configuration.y;
            target_width = active_movie_configuration.width;
            target_height = active_movie_configuration.height;
        }
        if (target_width <= 0 || target_height <= 0) {
            return;
        }

        const int clipped_left = std::max(0, target_x);
        const int clipped_top = std::max(0, target_y);
        const int clipped_right = std::min(
            static_cast<int>(frame.width), target_x + target_width);
        const int clipped_bottom = std::min(
            static_cast<int>(frame.height), target_y + target_height);
        if (clipped_left >= clipped_right || clipped_top >= clipped_bottom) {
            return;
        }

        const size_t source_width = latest_media_state.width;
        const size_t source_height = latest_media_state.height;
        for (int destination_y = clipped_top;
             destination_y < clipped_bottom; ++destination_y) {
            const size_t source_y = std::min(
                source_height - 1,
                static_cast<size_t>(
                    (destination_y - target_y) *
                    static_cast<int64_t>(source_height) / target_height));
            for (int destination_x = clipped_left;
                 destination_x < clipped_right; ++destination_x) {
                const size_t source_x = std::min(
                    source_width - 1,
                    static_cast<size_t>(
                        (destination_x - target_x) *
                        static_cast<int64_t>(source_width) / target_width));
                const size_t source_offset =
                    (source_y * source_width + source_x) * 4u;
                const size_t destination_offset =
                    static_cast<size_t>(destination_y) *
                        frame.stride_bytes +
                    static_cast<size_t>(destination_x) * 4u;
                std::memcpy(frame.rgba.data() + destination_offset,
                            media_rgba.data() + source_offset, 4u);
            }
        }
        // A movie can advance while the ONS base frame remains unchanged.
        // Include its serial so frame enhancement never reuses a cached
        // result from the previous movie image.
        const uint64_t mixed_serial = frame.serial ^
            (latest_media_state.frame_serial + 0x9e3779b97f4a7c15ull +
             (frame.serial << 6u) + (frame.serial >> 2u));
        frame.serial = mixed_serial &
            static_cast<uint64_t>(std::numeric_limits<int64_t>::max());
        if (frame.serial == 0) {
            frame.serial = 1;
        }
    }

    void configure_encoding() {
        // ONScripter Yuri uses one process-wide converter. Replace it before
        // each embedded session so a later game may choose another encoding.
        if (coding2utf16 != nullptr) {
            delete coding2utf16;
            coding2utf16 = nullptr;
        }
        if (encoding == "sjis" || encoding == "shift-jis" ||
            encoding == "shift_jis") {
            coding2utf16 = new SJIS2UTF16();
        } else {
            auto *converter = new GBK2UTF16();
            converter->force_utf8 = encoding == "utf8" || encoding == "utf-8";
            coding2utf16 = converter;
        }
    }

    void load_game_options(const fs::path &root) {
        encoding = configured_encoding.empty()
            ? DetectScriptEncoding(root) : configured_encoding;
        std::string source = configured_encoding.empty()
            ? "auto" : "host option";
        const fs::path arguments_path = FindRootFileCaseInsensitive(root, "ons_args");
        std::ifstream arguments(arguments_path);
        if (arguments) {
            std::string value;
            while (arguments >> value) {
                if (value == "--enc:sjis") {
                    encoding = "sjis";
                    source = "ons_args";
                } else if (value == "--enc:utf8") {
                    encoding = "utf8";
                    source = "ons_args";
                } else if (value == "--enc:gbk") {
                    encoding = "gbk";
                    source = "ons_args";
                }
            }
        }
        append_log("[ONScripter Yuri] script encoding: " + encoding +
                   " (" + source + ")");
    }

    void run_game(fs::path root) {
        try {
            append_log("[ONScripter Yuri] run_game entered: " +
                       root.u8string());
#if (defined(__APPLE__) && TARGET_OS_IOS) || defined(ANDROID)
            // ONScripter is embedded in Godot, so SDL never owns the host
            // application's entry point that normally marks its main setup
            // as complete. Tell SDL that the existing host has already done
            // so before ONScripter calls SDL_Init from this runtime thread.
            SDL_SetMainReady();
#endif
#if defined(AETHERKIRI_EMBEDDED_HOST)
            // ONScripter is embedded in Godot and has no SDL-owned
            // presentation surface. In particular, never select SDL's
            // Android backend: it expects SDLActivity/JNI state that Godot
            // does not provide and can dereference a null JavaVM.
            SDL_SetHintWithPriority(SDL_HINT_VIDEODRIVER, "dummy",
                                    SDL_HINT_OVERRIDE);
            SDL_SetHintWithPriority(SDL_HINT_RENDER_DRIVER, "software",
                                    SDL_HINT_OVERRIDE);
#endif
#if defined(ANDROID)
            // Godot owns the Android activity, so SDL's Java AudioTrack
            // backend has no SDLActivity JNI bindings. Use SDL's native
            // OpenSL ES backend while retaining the normal ONS mixer path.
            SDL_SetHintWithPriority(SDL_HINT_AUDIODRIVER, "openslES",
                                    SDL_HINT_OVERRIDE);
#endif
            load_game_options(root);
            configure_encoding();
            ons = new (static_cast<void *>(&::ons)) ONScripter();
            ons->setWindowMode();
            ons->setVsyncOff();
            ons->setArchivePath(root.u8string().c_str());

            const SaveStorageResult save_storage = PrepareSaveStorage(
                root, fs::u8path(writable_path));
            if (save_storage.directory.empty()) {
                throw std::runtime_error(
                    "failed to create a writable ONS save directory: " +
                    save_storage.warning);
            }
            append_log(
                "[ONScripter Yuri] save directory: " +
                save_storage.directory.u8string() +
                (save_storage.using_game_directory
                    ? " (game fallback)" : " (host save library)"));
            if (save_storage.migrated_files > 0) {
                append_log(
                    "[ONScripter Yuri] migrated " +
                    std::to_string(save_storage.migrated_files) +
                    " existing save file(s)");
            }
            if (!save_storage.warning.empty()) {
                append_log(
                    "[ONScripter Yuri] save storage warning: " +
                    save_storage.warning);
            }
            ons->setSaveDir(save_storage.directory.u8string().c_str());

            std::error_code error_code;

            fs::path font;
            if (!default_font.empty()) {
                font = fs::u8path(default_font);
            } else {
                // Imported Windows game trees frequently vary the case of
                // the canonical font filename on iOS's case-sensitive volume.
                font = FindRootFileCaseInsensitive(root, "default.ttf");
            }
            if (!font.empty()) {
                ons->setFontFile(font.u8string().c_str());
            }

            if (!FindRootFileCaseInsensitive(root, "nscript.___").empty()) {
                const fs::path key_executable = FindONSKeyExecutable(root);
                if (key_executable.empty()) {
                    throw std::runtime_error(
                        "nscript.___ requires the original Windows executable containing its key table");
                }
                std::array<uint8_t, 256> validated_key_table{};
                if (!LoadONSKeyTable(key_executable, &validated_key_table)) {
                    // Upstream treats an invalid --key-exe as a fatal
                    // process exit. Reject it before openScript() so the
                    // embedded HostExit boundary can report a normal engine
                    // failure without ever relying on that fatal path.
                    throw std::runtime_error(
                        "nscript.___ key executable does not contain a 256-byte permutation table: " +
                        key_executable.filename().u8string());
                }
                ons->setKeyEXE(key_executable.u8string().c_str());
                append_log("[ONScripter Yuri] keyed script executable: " +
                           key_executable.filename().u8string());
            }

            // ScriptHandler opens the initial 0.txt/nscript.dat relative to
            // cwd even when --root is set. Limit that upstream behavior to
            // the synchronous script-read window, then restore Godot's cwd.
            {
                std::lock_guard<std::mutex> cwd_lock(
                    g_current_directory_mutex);
                const fs::path previous = fs::current_path(error_code);
                if (error_code) {
                    throw std::runtime_error(
                        "failed to read the process working directory");
                }
                fs::current_path(root, error_code);
                if (error_code) {
                    throw std::runtime_error(
                        "failed to enter the ONScripter game directory");
                }
                int open_result = -1;
                try {
                    open_result = ons->openScript();
                } catch (...) {
                    // openScript() converts upstream exit() calls into
                    // HostExit. Restore the process-wide cwd before allowing
                    // that exception to reach the runtime boundary; otherwise
                    // every later native session resolves relative paths from
                    // this game's read-only content directory.
                    std::error_code restore_error;
                    fs::current_path(previous, restore_error);
                    if (restore_error) {
                        append_log(
                            "[ONScripter Yuri] failed to restore working directory after script error: " +
                            restore_error.message());
                    }
                    throw;
                }
                std::error_code restore_error;
                fs::current_path(previous, restore_error);
                if (open_result != 0) {
                    throw std::runtime_error(
                        "ONScripter Yuri could not open the game script");
                }
                if (restore_error) {
                    throw std::runtime_error(
                        "failed to restore the process working directory");
                }
            }
            append_log("[ONScripter Yuri] script opened");

            const int init_result = ons->init();
            append_log("[ONScripter Yuri] init returned: " +
                       std::to_string(init_result));
            if (init_result != 0) {
                throw std::runtime_error(
                    "ONScripter Yuri initialization failed; check default.ttf and game assets");
            }

            // Godot sends coordinates in the final script surface. Upstream
            // SDL events instead expect dummy-window/device coordinates and
            // maps those back through screen_scale_ratio in its event loop.
            // Store the inverse transform so games whose script and dummy
            // window sizes differ still receive accurate button hits.
            input_device_scale_x.store(
                ons->screen_scale_ratio1 != 0.0f
                    ? 1.0 / ons->screen_scale_ratio1
                    : 1.0);
            input_device_scale_y.store(
                ons->screen_scale_ratio2 != 0.0f
                    ? 1.0 / ons->screen_scale_ratio2
                    : 1.0);
            input_device_offset_x.store(ons->render_view_rect.x);
            input_device_offset_y.store(ons->render_view_rect.y);

            const uint32_t source_width =
                static_cast<uint32_t>(ons->accumulation_surface->w);
            const uint32_t source_height =
                static_cast<uint32_t>(ons->accumulation_surface->h);
            const PresentationAspectRatio presentation_aspect =
                ReadPresentationAspectRatio(root);
            const PresentationViewport presentation =
                ResolvePresentationViewport(
                    source_width, source_height,
                    presentation_aspect.width, presentation_aspect.height);
            presentation_source_width.store(source_width);
            presentation_source_height.store(source_height);
            presentation_x.store(presentation.x);
            presentation_y.store(presentation.y);
            presentation_width.store(presentation.width);
            presentation_height.store(presentation.height);
            if (presentation.width != source_width ||
                presentation.height != source_height) {
                append_log(
                    "[ONScripter Yuri] presentation viewport: " +
                    std::to_string(presentation.width) + "x" +
                    std::to_string(presentation.height) + " from " +
                    std::to_string(source_width) + "x" +
                    std::to_string(source_height));
            }

            {
                std::lock_guard<std::mutex> surface_lock(
                    g_present_surface_mutex);
                g_present_surface = ons->accumulation_surface;
            }
            // Initialization may have published before the presentation
            // viewport was resolved. Force one current complete snapshot so
            // the first Godot frame never falls back to live surface memory.
            aetherkiri_onscripter_publish_frame(
                ons->accumulation_surface, nullptr);
            startup.store(StartupState::Succeeded);
            game_open.store(true);
            append_log("[ONScripter Yuri] startup succeeded: " +
                       root.u8string());
            append_log("[ONScripter Yuri] executeLabel entered");
            ons->executeLabel();
            append_log("[ONScripter Yuri] executeLabel returned");
            ended.store(true);
            game_open.store(false);
        } catch (const HostExit &host_exit) {
            append_log("[ONScripter Yuri] HostExit code=" +
                       std::to_string(host_exit.code) +
                       " stop_requested=" +
                       std::to_string(stop_requested.load() ? 1 : 0));
            ended.store(true);
            game_open.store(false);
            if (host_exit.code == 0 || stop_requested.load()) {
                append_log("[ONScripter Yuri] runtime requested termination");
            } else {
                set_error("runtime terminated with exit code " +
                          std::to_string(host_exit.code));
            }
        } catch (const std::exception &exception) {
            set_error(exception.what());
        } catch (...) {
            set_error("unknown ONScripter Yuri runtime failure");
        }

        // Upstream terminates the process after `end`, which runs the global
        // ONScripter destructor through C++ static teardown. The embedded host
        // converts that exit into HostExit, so mirror the missing teardown
        // explicitly before another object is placement-constructed in the
        // same ABI-visible storage.
        if (ons != nullptr) {
            ons->~ONScripter();
            ons = nullptr;
        }
    }
};

Runtime::Runtime() : impl_(std::make_unique<Impl>()) {}

Runtime::~Runtime() {
    shutdown();
}

bool Runtime::initialize(const std::string &writable_path,
                         const std::string &cache_path) {
    if (impl_->initialized.load()) {
        return true;
    }
    if (writable_path.empty()) {
        impl_->set_error("writable path is empty");
        return false;
    }
    impl_->writable_path = writable_path;
    impl_->cache_path = cache_path;
    impl_->startup.store(StartupState::Idle);
    if (!impl_->initialize_media_engine()) {
        return false;
    }
    {
        std::lock_guard<std::mutex> host_lock(g_movie_host_mutex);
        g_movie_host = impl_.get();
    }
    impl_->initialized.store(true);
    impl_->append_log("[ONScripter Yuri] host initialized");
    return true;
}

void Runtime::shutdown() {
    if (!impl_) {
        return;
    }
    aetherkiri_onscripter_end_system_list_scroll();
    impl_->stop_requested.store(true);
    impl_->append_log("[ONScripter Yuri] shutdown requested, game_thread=" +
                      std::to_string(impl_->game_thread.joinable() ? 1 : 0));
    if (impl_->game_thread.joinable()) {
        SDL_Event event{};
        event.type = SDL_QUIT;
        PushRuntimeEvent(event);
        impl_->game_thread.join();
    }
    ClearHostEvents();
    // Also covers initialization failures which leave the upstream global
    // worker pool alive without reaching ONScripter::quit().
    aetherkiri_onscripter_shutdown_parallel();
    {
        std::lock_guard<std::mutex> host_lock(g_movie_host_mutex);
        if (g_movie_host == impl_.get()) {
            g_movie_host = nullptr;
        }
    }
    impl_->close_media();
    if (impl_->media_engine != nullptr) {
        engine_destroy(impl_->media_engine);
        impl_->media_engine = nullptr;
    }
    // `run_game` mirrors upstream process teardown and destroys the placement
    // object on its owning thread before another ONS session can start.
    impl_->ons = nullptr;
    impl_->game_open.store(false);
    impl_->initialized.store(false);
}

bool Runtime::set_option(const std::string &key, const std::string &value) {
    if (key == "default_font") {
        impl_->default_font = value;
    } else if (key == "onscripter_encoding" || key == "script_encoding") {
        std::string normalized = value;
        std::transform(normalized.begin(), normalized.end(), normalized.begin(),
                       [](unsigned char byte) {
                           return static_cast<char>(std::tolower(byte));
                       });
        if (normalized != "sjis" && normalized != "shift-jis" &&
            normalized != "shift_jis" && normalized != "utf8" &&
            normalized != "utf-8" && normalized != "gbk") {
            impl_->set_error("unsupported ONScripter script encoding: " + value);
            return false;
        }
        impl_->configured_encoding = normalized;
    }
    return true;
}

bool Runtime::open_game(const std::string &game_root_path) {
    if (!impl_->initialized.load()) {
        impl_->set_error("runtime is not initialized");
        return false;
    }
    if (impl_->game_thread.joinable()) {
        impl_->set_error(
            "the previous ONScripter Yuri session has not finished shutting down");
        return false;
    }

    const fs::path root = NormalizeGameRoot(game_root_path);
    if (root.empty() || !HasScriptMarker(root)) {
        impl_->set_error(
            "no ONScripter script found (expected 0/00.txt, nscr_sec.dat, nscript.*, or onscript.nt2/nt3)");
        return false;
    }

    impl_->game_root = root.u8string();
    impl_->append_log("[ONScripter Yuri] open_game queued: " +
                      impl_->game_root);
    aetherkiri_onscripter_end_system_list_scroll();
    impl_->system_list_touch_pointer.store(-1);
    impl_->system_list_touch_scrolled.store(false);
    impl_->startup.store(StartupState::Running);
    impl_->ended.store(false);
    impl_->stop_requested.store(false);
    impl_->presentation_source_width.store(0);
    impl_->presentation_source_height.store(0);
    impl_->presentation_x.store(0);
    impl_->presentation_y.store(0);
    impl_->presentation_width.store(0);
    impl_->presentation_height.store(0);
    {
        std::lock_guard<std::mutex> surface_lock(g_present_surface_mutex);
        g_present_surface = nullptr;
    }
    ResetPublishedFrame();
    ClearHostEvents();
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->error.clear();
    }
    impl_->game_thread =
        std::thread([this, root]() { impl_->run_game(root); });
    return true;
}

bool Runtime::tick() {
    if (!impl_->initialized.load()) {
        return false;
    }
    {
        std::lock_guard<std::mutex> media_lock(impl_->media_mutex);
        if (impl_->media != nullptr) {
            impl_->update_media_locked(true);
        }
    }
    return !impl_->ended.load() &&
           impl_->startup.load() != StartupState::Failed;
}

bool Runtime::pause() {
    if (!impl_->game_open.load()) {
        return false;
    }
    Mix_Pause(-1);
    Mix_PauseMusic();
    {
        std::lock_guard<std::mutex> media_lock(impl_->media_mutex);
        if (impl_->media != nullptr) {
            engine_media_pause(impl_->media);
        }
    }
    return true;
}

bool Runtime::resume() {
    if (!impl_->game_open.load()) {
        return false;
    }
    Mix_ResumeMusic();
    Mix_Resume(-1);
    {
        std::lock_guard<std::mutex> media_lock(impl_->media_mutex);
        if (impl_->media != nullptr) {
            engine_media_play(impl_->media);
        }
    }
    return true;
}

bool Runtime::send_pointer_event(int type, int pointer_id, double x, double y,
                                 double delta_x, double delta_y, int button,
                                 int modifiers) {
    if (!impl_->game_open.load()) {
        return false;
    }
    const auto system_list_max_scroll = [this]() -> uint32_t {
        if (!g_system_list_scroll_active.load()) {
            return 0;
        }
        const uint32_t source_height =
            impl_->presentation_source_height.load();
        const uint32_t viewport_y = impl_->presentation_y.load();
        const uint32_t viewport_height =
            impl_->presentation_height.load();
        if (source_height == 0 || viewport_height == 0 ||
            viewport_y >= source_height ||
            viewport_height > source_height - viewport_y) {
            return 0;
        }
        return source_height - viewport_y - viewport_height;
    };
    const auto adjust_system_list_scroll =
        [this, &system_list_max_scroll](int32_t delta) -> bool {
        const uint32_t max_scroll = system_list_max_scroll();
        if (max_scroll == 0) {
            return false;
        }
        uint32_t current = g_system_list_scroll_y.load();
        while (true) {
            const uint32_t next = ResolvePresentationScroll(
                impl_->presentation_source_height.load(),
                impl_->presentation_y.load(),
                impl_->presentation_height.load(), current, delta);
            if (next == current) {
                return true;
            }
            if (g_system_list_scroll_y.compare_exchange_weak(
                    current, next)) {
                g_system_list_view_revision.fetch_add(1);
                return true;
            }
        }
    };
    constexpr int kTouchPointerIdBase = 100000;
    const bool is_touch_pointer = pointer_id >= kTouchPointerIdBase;

    if (type == 1 && is_touch_pointer &&
        g_system_list_scroll_active.load()) {
        impl_->system_list_touch_pointer.store(pointer_id);
        impl_->system_list_touch_scrolled.store(false);
    }
    if (type == 2 && is_touch_pointer &&
        impl_->system_list_touch_pointer.load() == pointer_id &&
        g_system_list_scroll_active.load() &&
        std::abs(delta_y) > std::numeric_limits<double>::epsilon()) {
        int32_t scroll_delta = static_cast<int32_t>(std::lround(-delta_y));
        if (scroll_delta == 0) {
            scroll_delta = delta_y < 0.0 ? 1 : -1;
        }
        if (adjust_system_list_scroll(scroll_delta)) {
            impl_->system_list_touch_scrolled.store(true);
        }
    }
    if (type == 3 && is_touch_pointer &&
        impl_->system_list_touch_pointer.load() == pointer_id) {
        impl_->system_list_touch_pointer.store(-1);
        if (impl_->system_list_touch_scrolled.exchange(false) &&
            g_system_list_scroll_active.load()) {
            // A drag scrolls the list; swallowing its release prevents the
            // slot now underneath the finger from being loaded accidentally.
            return true;
        }
    }
    if (type == 3) {
        std::lock_guard<std::mutex> media_lock(impl_->media_mutex);
        if (impl_->media_is_script_movie &&
            impl_->media_click_to_skip) {
            impl_->media_skip_requested.store(true);
        }
    }
    if (type == 4) {
        int32_t scroll_delta = static_cast<int32_t>(
            std::lround(delta_y * 40.0));
        if (scroll_delta == 0 &&
            std::abs(delta_y) > std::numeric_limits<double>::epsilon()) {
            scroll_delta = delta_y > 0.0 ? 40 : -40;
        }
        if (adjust_system_list_scroll(scroll_delta)) {
            return true;
        }
        SDL_Event event{};
        event.type = SDL_MOUSEWHEEL;
        event.wheel.x = static_cast<int>(std::lround(delta_x));
        event.wheel.y = static_cast<int>(std::lround(-delta_y));
        event.wheel.direction = SDL_MOUSEWHEEL_NORMAL;
        return PushRuntimeEvent(event);
    }

    if (type == 2) {
        const double device_scale_x =
            impl_->input_device_scale_x.load();
        const double device_scale_y =
            impl_->input_device_scale_y.load();
        const double script_x = x + impl_->presentation_x.load();
        const double script_y = y + impl_->presentation_y.load() +
            (g_system_list_scroll_active.load()
                ? g_system_list_scroll_y.load() : 0);
        SDL_Event event{};
        event.type = SDL_MOUSEMOTION;
        event.motion.x = static_cast<int>(std::lround(
            script_x * device_scale_x +
            impl_->input_device_offset_x.load()));
        event.motion.y = static_cast<int>(std::lround(
            script_y * device_scale_y +
            impl_->input_device_offset_y.load()));
        event.motion.xrel = static_cast<int>(std::lround(
            delta_x * device_scale_x));
        event.motion.yrel = static_cast<int>(std::lround(
            delta_y * device_scale_y));
        event.motion.state = 0;
        if ((modifiers & 0x08) != 0) event.motion.state |= SDL_BUTTON_LMASK;
        if ((modifiers & 0x10) != 0) event.motion.state |= SDL_BUTTON_RMASK;
        if ((modifiers & 0x20) != 0) event.motion.state |= SDL_BUTTON_MMASK;
        return PushRuntimeEvent(event);
    }

    if (type == 1 || type == 3) {
        const double script_x = x + impl_->presentation_x.load();
        const double script_y = y + impl_->presentation_y.load() +
            (g_system_list_scroll_active.load()
                ? g_system_list_scroll_y.load() : 0);
        const int device_x = static_cast<int>(std::lround(
            script_x * impl_->input_device_scale_x.load() +
            impl_->input_device_offset_x.load()));
        const int device_y = static_cast<int>(std::lround(
            script_y * impl_->input_device_scale_y.load() +
            impl_->input_device_offset_y.load()));
        // ONScripter resolves a button press through `current_over_button`,
        // which is refreshed by SDL_MOUSEMOTION rather than by the button
        // event's coordinates. Godot can legitimately deliver a click
        // without a preceding motion event (for example when a new menu
        // appears beneath a stationary cursor), so make every press
        // self-contained.
        if (type == 1) {
            SDL_Event motion{};
            motion.type = SDL_MOUSEMOTION;
            motion.motion.x = device_x;
            motion.motion.y = device_y;
            motion.motion.state = 0;
            if (!PushRuntimeEvent(motion)) {
                return false;
            }
        }
        SDL_Event event{};
        event.type = type == 1 ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
        event.button.state = type == 1 ? SDL_PRESSED : SDL_RELEASED;
        event.button.x = device_x;
        event.button.y = device_y;
        if (button == 2 || (modifiers & 0x10) != 0) {
            event.button.button = SDL_BUTTON_RIGHT;
        } else if (button == 3 || (modifiers & 0x20) != 0) {
            event.button.button = SDL_BUTTON_MIDDLE;
        } else {
            event.button.button = SDL_BUTTON_LEFT;
        }
        event.button.clicks = 1;
        return PushRuntimeEvent(event);
    }
    return false;
}

bool Runtime::send_key_event(bool pressed, int key_code, int modifiers,
                             int unicode_codepoint) {
    if (!impl_->game_open.load()) {
        return false;
    }
    if (!pressed &&
        (key_code == 0x0d || key_code == 0x1b || key_code == 0x20)) {
        std::lock_guard<std::mutex> media_lock(impl_->media_mutex);
        if (impl_->media_is_script_movie &&
            impl_->media_click_to_skip) {
            impl_->media_skip_requested.store(true);
        }
    }
    const SDL_Keycode mapped = WindowsVirtualKeyToSdl(key_code);
    bool sent = true;
    if (mapped != SDLK_UNKNOWN) {
        SDL_Event event{};
        event.type = pressed ? SDL_KEYDOWN : SDL_KEYUP;
        event.key.state = pressed ? SDL_PRESSED : SDL_RELEASED;
        event.key.repeat = (modifiers & 0x80) != 0 ? 1 : 0;
        event.key.keysym.sym = mapped;
        event.key.keysym.scancode = SDL_GetScancodeFromKey(mapped);
        event.key.keysym.mod = EngineModifiersToSdl(modifiers);
        sent = PushRuntimeEvent(event);
    }
    if (pressed && unicode_codepoint > 0) {
        const std::string text =
            Utf8FromCodepoint(static_cast<uint32_t>(unicode_codepoint));
        if (!text.empty() && text.size() < SDL_TEXTINPUTEVENT_TEXT_SIZE) {
            SDL_Event event{};
            event.type = SDL_TEXTINPUT;
            std::memcpy(event.text.text, text.data(), text.size());
            sent = PushRuntimeEvent(event) && sent;
        }
    }
    return sent;
}

bool Runtime::is_initialized() const {
    return impl_->initialized.load();
}

bool Runtime::is_game_open() const {
    return impl_->game_open.load();
}

bool Runtime::has_ended() const {
    return impl_->ended.load();
}

StartupState Runtime::startup_state() const {
    return impl_->startup.load();
}

std::string Runtime::last_error() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->error;
}

std::string Runtime::drain_logs() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    std::string output;
    while (!impl_->logs.empty()) {
        if (!output.empty()) {
            output.push_back('\n');
        }
        output += impl_->logs.front();
        impl_->logs.pop_front();
    }
    return output;
}

std::string Runtime::renderer_info() const {
    std::ostringstream output;
    output << "backend=onscripter_yuri host=godot frame=rgba8 "
              "transport=engine_runtime_provider media=ffmpeg commands=full "
              "input_scale="
           << impl_->input_device_scale_x.load() << "x"
           << impl_->input_device_scale_y.load()
           << " input_offset="
           << impl_->input_device_offset_x.load() << ","
           << impl_->input_device_offset_y.load()
           << " source="
           << impl_->presentation_source_width.load() << "x"
           << impl_->presentation_source_height.load()
           << " viewport="
           << impl_->presentation_width.load() << "x"
           << impl_->presentation_height.load()
           << "+" << impl_->presentation_x.load()
           << "+" << (impl_->presentation_y.load() +
                (g_system_list_scroll_active.load()
                    ? g_system_list_scroll_y.load() : 0));
    return output.str();
}

bool Runtime::read_frame(Frame &frame) {
    if (!impl_->game_open.load() || impl_->ons == nullptr) {
        return false;
    }
    // Present the latest immutable snapshot assembled from completed ONS
    // flushes. The ONS thread updates only committed dirty regions, so this
    // can neither observe an in-progress composition nor miss the tail of a
    // rapid sequence of menu/text flushes.
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t stride = 0;
    uint64_t serial = 0;
    std::vector<uint8_t> rgba;
    {
        std::lock_guard<std::mutex> frame_guard(g_published_frame_mutex);
        if (g_published_frame.width == 0 ||
            g_published_frame.height == 0 ||
            g_published_frame.rgba.empty()) {
            return false;
        }

        const uint32_t source_width = g_published_frame.width;
        const uint32_t source_height = g_published_frame.height;
        uint32_t crop_x = impl_->presentation_x.load();
        uint32_t crop_y = impl_->presentation_y.load() +
            (g_system_list_scroll_active.load()
                ? g_system_list_scroll_y.load() : 0);
        width = impl_->presentation_width.load();
        height = impl_->presentation_height.load();
        const bool crop_is_valid =
            impl_->presentation_source_width.load() == source_width &&
            impl_->presentation_source_height.load() == source_height &&
            width > 0 && height > 0 &&
            crop_x < source_width && crop_y < source_height &&
            width <= source_width - crop_x &&
            height <= source_height - crop_y;
        if (!crop_is_valid) {
            crop_x = 0;
            crop_y = 0;
            width = source_width;
            height = source_height;
        }
        stride = width * 4u;
        rgba.resize(static_cast<size_t>(stride) * height);
        for (uint32_t row = 0; row < height; ++row) {
            const size_t source_offset =
                static_cast<size_t>(crop_y + row) *
                    g_published_frame.stride_bytes +
                static_cast<size_t>(crop_x) * 4u;
            const size_t destination_offset =
                static_cast<size_t>(row) * stride;
            std::memcpy(rgba.data() + destination_offset,
                        g_published_frame.rgba.data() + source_offset,
                        stride);
        }
        serial = g_published_frame.serial;
        const uint64_t view_revision =
            g_system_list_view_revision.load();
        if (view_revision != 0) {
            serial ^= view_revision + 0x9e3779b97f4a7c15ull +
                (serial << 6u) + (serial >> 2u);
            if (serial == 0) {
                serial = 1;
            }
        }
    }

    frame.width = width;
    frame.height = height;
    frame.stride_bytes = stride;
    frame.serial = serial;
    frame.rgba = std::move(rgba);
    impl_->overlay_movie(frame);
    return true;
}

bool Runtime::media_open(const std::string &path) {
    if (!impl_->initialized.load() || path.empty()) {
        return false;
    }
    std::error_code error_code;
    const fs::path normalized =
        fs::absolute(fs::u8path(path), error_code).lexically_normal();
    if (!fs::is_regular_file(normalized, error_code)) {
        impl_->set_media_error("media file does not exist: " + path);
        return false;
    }
    std::lock_guard<std::mutex> media_lock(impl_->media_mutex);
    return impl_->open_media_locked(normalized, false);
}

void Runtime::media_close() {
    impl_->close_media();
}

bool Runtime::media_play() {
    std::lock_guard<std::mutex> media_lock(impl_->media_mutex);
    if (impl_->media == nullptr) {
        return false;
    }
    return engine_media_play(impl_->media) == ENGINE_RESULT_OK;
}

bool Runtime::media_pause() {
    std::lock_guard<std::mutex> media_lock(impl_->media_mutex);
    if (impl_->media == nullptr) {
        return false;
    }
    return engine_media_pause(impl_->media) == ENGINE_RESULT_OK;
}

bool Runtime::media_seek(int64_t position_ms) {
    std::lock_guard<std::mutex> media_lock(impl_->media_mutex);
    if (impl_->media == nullptr || position_ms < 0) {
        return false;
    }
    return engine_media_seek(impl_->media, position_ms) == ENGINE_RESULT_OK;
}

bool Runtime::media_set_rate(double playback_rate) {
    std::lock_guard<std::mutex> media_lock(impl_->media_mutex);
    if (impl_->media == nullptr || !std::isfinite(playback_rate) ||
        playback_rate <= 0.0) {
        return false;
    }
    return engine_media_set_rate(
               impl_->media, playback_rate) == ENGINE_RESULT_OK;
}

MediaState Runtime::media_state() {
    std::lock_guard<std::mutex> media_lock(impl_->media_mutex);
    if (impl_->media != nullptr) {
        impl_->update_media_locked(true);
    }
    return impl_->latest_media_state;
}

bool Runtime::read_media_frame(Frame &frame) {
    std::lock_guard<std::mutex> media_lock(impl_->media_mutex);
    if (impl_->media != nullptr) {
        impl_->update_media_locked(true);
    }
    if (!impl_->latest_media_state.frame_ready ||
        impl_->media_rgba.empty()) {
        return false;
    }
    frame.width = impl_->latest_media_state.width;
    frame.height = impl_->latest_media_state.height;
    frame.stride_bytes = frame.width * 4u;
    frame.serial = impl_->latest_media_state.frame_serial;
    frame.rgba = impl_->media_rgba;
    return true;
}

std::string Runtime::media_subtitle_tracks_json() {
    std::lock_guard<std::mutex> media_lock(impl_->media_mutex);
    if (impl_->media == nullptr) {
        return "[]";
    }
    std::vector<char> buffer(64u * 1024u);
    uint32_t bytes_written = 0;
    if (engine_media_get_subtitle_tracks_json(
            impl_->media, buffer.data(),
            static_cast<uint32_t>(buffer.size()),
            &bytes_written) != ENGINE_RESULT_OK) {
        return "[]";
    }
    return std::string(buffer.data(), bytes_written);
}

bool Runtime::media_extract_subtitle(
    int stream_index, const std::string &output_path) {
    std::lock_guard<std::mutex> media_lock(impl_->media_mutex);
    if (impl_->media == nullptr || stream_index < 0 ||
        output_path.empty()) {
        return false;
    }
    return engine_media_extract_subtitle(
               impl_->media, stream_index,
               output_path.c_str()) == ENGINE_RESULT_OK;
}

bool Runtime::looks_like_game(const std::string &path) {
    return HasScriptMarker(NormalizeGameRoot(path));
}

} // namespace aetherkiri::onscripter
