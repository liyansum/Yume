#include "CYumeRuntimeBridge.h"

#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#define YUME_WEAK_IMPORT __attribute__((weak_import))
#elif defined(__GNUC__) || defined(__clang__)
#define YUME_WEAK_IMPORT __attribute__((weak))
#else
#define YUME_WEAK_IMPORT
#endif

extern const YumeRuntimeProviderAPI *yume_mkxp_runtime_provider(void) YUME_WEAK_IMPORT;
extern const YumeRuntimeProviderAPI *yume_aetherkiri_onscripter_runtime_provider(void) YUME_WEAK_IMPORT;
extern const YumeRuntimeProviderAPI *yume_aetherkiri_kirikiri_runtime_provider(void) YUME_WEAK_IMPORT;
extern const YumeRuntimeProviderAPI *yume_renios_runtime_provider(void) YUME_WEAK_IMPORT;
extern const YumeRuntimeProviderAPI *yume_art3m1s_runtime_provider(void) YUME_WEAK_IMPORT;

struct YumeRuntimeSession {
    const YumeRuntimeProviderAPI *api;
    void *provider_session;
    int32_t stopped;
};

static const YumeRuntimeProviderAPI *provider_for_identifier(const char *identifier) {
    if (!identifier) return NULL;
    if (strcmp(identifier, "mkxp-z") == 0 && yume_mkxp_runtime_provider)
        return yume_mkxp_runtime_provider();
    if (strcmp(identifier, "aetherkiri-onscripter") == 0
        && yume_aetherkiri_onscripter_runtime_provider)
        return yume_aetherkiri_onscripter_runtime_provider();
    if (strcmp(identifier, "aetherkiri-kirikiri") == 0
        && yume_aetherkiri_kirikiri_runtime_provider)
        return yume_aetherkiri_kirikiri_runtime_provider();
    if (strcmp(identifier, "renios") == 0 && yume_renios_runtime_provider)
        return yume_renios_runtime_provider();
    if (strcmp(identifier, "art3m1s") == 0 && yume_art3m1s_runtime_provider)
        return yume_art3m1s_runtime_provider();
    return NULL;
}

static int32_t provider_is_valid(const YumeRuntimeProviderAPI *api, const char *identifier) {
    return api && api->abi_version == YUME_RUNTIME_ABI_VERSION && api->identifier
        && strcmp(api->identifier, identifier) == 0 && api->create && api->start
        && api->stop && api->destroy;
}

int32_t yume_runtime_is_available(const char *runtime_identifier) {
    const YumeRuntimeProviderAPI *api = provider_for_identifier(runtime_identifier);
    return provider_is_valid(api, runtime_identifier);
}

YumeRuntimeSession *yume_runtime_session_create(
    const char *runtime_identifier,
    const YumeRuntimeConfiguration *configuration,
    YumeRuntimeEventCallback callback,
    void *callback_context,
    int32_t *error_code
) {
    if (error_code) *error_code = -1;
    if (!configuration || configuration->abi_version != YUME_RUNTIME_ABI_VERSION) return NULL;
    const YumeRuntimeProviderAPI *api = provider_for_identifier(runtime_identifier);
    if (!provider_is_valid(api, runtime_identifier)) {
        if (error_code) *error_code = -2;
        return NULL;
    }
    YumeRuntimeSession *session = (YumeRuntimeSession *)calloc(1, sizeof(*session));
    if (!session) {
        if (error_code) *error_code = -3;
        return NULL;
    }
    session->api = api;
    int32_t result = api->create(configuration, callback, callback_context, &session->provider_session);
    if (result != 0 || !session->provider_session) {
        free(session);
        if (error_code) *error_code = result ? result : -4;
        return NULL;
    }
    if (error_code) *error_code = 0;
    return session;
}

int32_t yume_runtime_session_start(YumeRuntimeSession *session) {
    return session && !session->stopped ? session->api->start(session->provider_session) : -1;
}
int32_t yume_runtime_session_pause(YumeRuntimeSession *session) {
    return session && !session->stopped && session->api->pause
        ? session->api->pause(session->provider_session) : -1;
}
int32_t yume_runtime_session_resume(YumeRuntimeSession *session) {
    return session && !session->stopped && session->api->resume
        ? session->api->resume(session->provider_session) : -1;
}
int32_t yume_runtime_session_send_button(
    YumeRuntimeSession *session,
    YumeRuntimeInputAction action,
    int32_t pressed
) {
    return session && !session->stopped && session->api->send_button
        ? session->api->send_button(session->provider_session, action, pressed) : -1;
}
int32_t yume_runtime_session_send_pointer(
    YumeRuntimeSession *session,
    double x,
    double y,
    int32_t pressed
) {
    return session && !session->stopped && session->api->send_pointer
        ? session->api->send_pointer(session->provider_session, x, y, pressed) : -1;
}
int32_t yume_runtime_session_send_text(YumeRuntimeSession *session, const char *utf8_text) {
    return session && !session->stopped && session->api->send_text
        ? session->api->send_text(session->provider_session, utf8_text) : -1;
}
int32_t yume_runtime_session_stop(YumeRuntimeSession *session) {
    if (!session) return -1;
    if (session->stopped) return 0;
    session->stopped = 1;
    return session->api->stop(session->provider_session);
}
void *yume_runtime_session_native_view(YumeRuntimeSession *session) {
    return session && !session->stopped && session->api->native_view
        ? session->api->native_view(session->provider_session) : NULL;
}
void yume_runtime_session_destroy(YumeRuntimeSession **session_pointer) {
    if (!session_pointer || !*session_pointer) return;
    YumeRuntimeSession *session = *session_pointer;
    yume_runtime_session_stop(session);
    session->api->destroy(session->provider_session);
    session->provider_session = NULL;
    free(session);
    *session_pointer = NULL;
}
