#include "CYumeRuntimeBridge.h"

// SwiftPM unit tests exercise the host lifecycle without linking the large
// iOS-only runtime archives. These strong null providers satisfy Mach-O's
// test-bundle linker; the application target links the real implementations.
const YumeRuntimeProviderAPI *yume_mkxp_runtime_provider(void) {
    return NULL;
}

const YumeRuntimeProviderAPI *yume_aetherkiri_onscripter_runtime_provider(void) {
    return NULL;
}

const YumeRuntimeProviderAPI *yume_aetherkiri_kirikiri_runtime_provider(void) {
    return NULL;
}

const YumeRuntimeProviderAPI *yume_renios_runtime_provider(void) {
    return NULL;
}

const YumeRuntimeProviderAPI *yume_art3m1s_runtime_provider(void) {
    return NULL;
}
