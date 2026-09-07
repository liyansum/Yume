#include "CYumeRuntimeBridge.h"
#include "CYumeRuntimeProviderStubs.h"
#include <stdlib.h>
#ifdef __APPLE__
#include <pthread.h>
#endif

// Only the test executable links this fault-injection provider.
static int enabled, acknowledge_stop = 1, destroy_count, off_main_count, fail_create;
static YumeRuntimeEventCallback event_callback;
static void *event_context;
static void check_thread(void) {
#ifdef __APPLE__
    if (!pthread_main_np()) ++off_main_count;
#endif
}
void yume_test_provider_enable(int acknowledge) {
    enabled = 1; acknowledge_stop = acknowledge; destroy_count = off_main_count = fail_create = 0;
}
void yume_test_provider_fail_create(void) { fail_create = 1; }
int yume_test_provider_destroy_count(void) { return destroy_count; }
int yume_test_provider_off_main_count(void) { return off_main_count; }
static int32_t create(const YumeRuntimeConfiguration *config,
                      YumeRuntimeEventCallback callback, void *context, void **out) {
    check_thread();
    *out = malloc(1);
    event_callback = callback; event_context = context;
    // Burst before the consumer starts: verifies bounded buffering.
    for (int index = 0; index < 2000; ++index)
        config->log_callback(YUME_RUNTIME_LOG_INFORMATION, "fixture", "bootstrap log", config->log_callback_context);
    return fail_create ? -99 : (*out ? 0 : -1);
}
static int32_t start(void *session) {
    (void)session; check_thread();
    event_callback(YUME_RUNTIME_EVENT_STARTED, "fixture.started", event_context);
    event_callback(YUME_RUNTIME_EVENT_FIRST_FRAME, "fixture.frame", event_context);
    return 0;
}
static int32_t stop(void *session) {
    (void)session; check_thread();
    if (acknowledge_stop) event_callback(YUME_RUNTIME_EVENT_STOPPED, "fixture.stopped", event_context);
    return 0;
}
static void destroy(void *session) {
    check_thread(); ++destroy_count; free(session); event_callback = NULL; event_context = NULL;
}
static const YumeRuntimeProviderAPI api = {
    YUME_RUNTIME_ABI_VERSION, "mkxp-z", create, start, NULL, NULL,
    NULL, NULL, NULL, stop, NULL, destroy
};
const YumeRuntimeProviderAPI *yume_mkxp_runtime_provider(void) { return enabled ? &api : NULL; }
const YumeRuntimeProviderAPI *yume_aetherkiri_onscripter_runtime_provider(void) { return NULL; }
const YumeRuntimeProviderAPI *yume_aetherkiri_kirikiri_runtime_provider(void) { return NULL; }
const YumeRuntimeProviderAPI *yume_renios_runtime_provider(void) { return NULL; }
const YumeRuntimeProviderAPI *yume_art3m1s_runtime_provider(void) { return NULL; }
