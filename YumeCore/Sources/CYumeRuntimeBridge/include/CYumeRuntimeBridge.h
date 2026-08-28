#ifndef C_YUME_RUNTIME_BRIDGE_H
#define C_YUME_RUNTIME_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define YUME_RUNTIME_ABI_VERSION 1u

typedef struct YumeRuntimeSession YumeRuntimeSession;

typedef enum YumeRuntimeEventKind {
    YUME_RUNTIME_EVENT_STARTED = 1,
    YUME_RUNTIME_EVENT_FIRST_FRAME = 2,
    YUME_RUNTIME_EVENT_PAUSED = 3,
    YUME_RUNTIME_EVENT_RESUMED = 4,
    YUME_RUNTIME_EVENT_STOPPED = 5,
    YUME_RUNTIME_EVENT_WARNING = 6,
    YUME_RUNTIME_EVENT_FAILED = 7
} YumeRuntimeEventKind;

typedef enum YumeRuntimeInputAction {
    YUME_RUNTIME_INPUT_UP = 1,
    YUME_RUNTIME_INPUT_DOWN = 2,
    YUME_RUNTIME_INPUT_LEFT = 3,
    YUME_RUNTIME_INPUT_RIGHT = 4,
    YUME_RUNTIME_INPUT_CONFIRM = 5,
    YUME_RUNTIME_INPUT_CANCEL = 6,
    YUME_RUNTIME_INPUT_MENU = 7,
    YUME_RUNTIME_INPUT_PAGE_UP = 8,
    YUME_RUNTIME_INPUT_PAGE_DOWN = 9,
    YUME_RUNTIME_INPUT_POINTER_PRIMARY = 10,
    YUME_RUNTIME_INPUT_FAST_FORWARD = 11,
    YUME_RUNTIME_INPUT_AUTO_MODE = 12,
    YUME_RUNTIME_INPUT_HISTORY = 13
} YumeRuntimeInputAction;

typedef struct YumeRuntimeConfiguration {
    uint32_t abi_version;
    const char *content_root;
    const char *save_root;
    const char *derived_root;
    const char *log_root;
    const char *locale_identifier;
    const char *const *rtp_roots;
    size_t rtp_root_count;
    int32_t networking_allowed;
} YumeRuntimeConfiguration;

typedef void (*YumeRuntimeEventCallback)(
    YumeRuntimeEventKind kind,
    const char *code,
    void *context
);

/// Provider ABI implemented by each statically linked upstream adapter.
/// Every path must be copied during create; the host's UTF-8 buffers are
/// intentionally valid only for the duration of that call.
typedef struct YumeRuntimeProviderAPI {
    uint32_t abi_version;
    const char *identifier;
    int32_t (*create)(
        const YumeRuntimeConfiguration *configuration,
        YumeRuntimeEventCallback callback,
        void *callback_context,
        void **provider_session
    );
    int32_t (*start)(void *provider_session);
    int32_t (*pause)(void *provider_session);
    int32_t (*resume)(void *provider_session);
    int32_t (*send_button)(void *provider_session, YumeRuntimeInputAction action, int32_t pressed);
    int32_t (*send_pointer)(void *provider_session, double x, double y, int32_t pressed);
    int32_t (*send_text)(void *provider_session, const char *utf8_text);
    int32_t (*stop)(void *provider_session);
    void *(*native_view)(void *provider_session);
    void (*destroy)(void *provider_session);
} YumeRuntimeProviderAPI;

int32_t yume_runtime_is_available(const char *runtime_identifier);
YumeRuntimeSession *yume_runtime_session_create(
    const char *runtime_identifier,
    const YumeRuntimeConfiguration *configuration,
    YumeRuntimeEventCallback callback,
    void *callback_context,
    int32_t *error_code
);
int32_t yume_runtime_session_start(YumeRuntimeSession *session);
int32_t yume_runtime_session_pause(YumeRuntimeSession *session);
int32_t yume_runtime_session_resume(YumeRuntimeSession *session);
int32_t yume_runtime_session_send_button(
    YumeRuntimeSession *session,
    YumeRuntimeInputAction action,
    int32_t pressed
);
int32_t yume_runtime_session_send_pointer(
    YumeRuntimeSession *session,
    double x,
    double y,
    int32_t pressed
);
int32_t yume_runtime_session_send_text(YumeRuntimeSession *session, const char *utf8_text);
int32_t yume_runtime_session_stop(YumeRuntimeSession *session);
void *yume_runtime_session_native_view(YumeRuntimeSession *session);
void yume_runtime_session_destroy(YumeRuntimeSession **session);

#ifdef __cplusplus
}
#endif

#endif
