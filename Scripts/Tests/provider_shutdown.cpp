#include "engine_api.h"
#include "engine_runtime_provider.h"
#include <atomic>
#include <cassert>
#include <chrono>
#include <thread>

static std::atomic<bool> may_finish{false};
static std::atomic<bool> destroyed{false};
static const std::thread::id owner = std::this_thread::get_id();
static int32_t probe(void *, const char *) { return 100; }
static engine_result_t create(void *, const engine_runtime_host_v1_t *, const engine_create_desc_t *, void **out) {
    *out = new int(1); return ENGINE_RESULT_OK;
}
static void destroy(void *runtime) {
    assert(std::this_thread::get_id() != owner);
    while (!may_finish.load()) std::this_thread::yield();
    delete static_cast<int *>(runtime); destroyed.store(true);
}
static engine_result_t open_game(void *, const char *, const char *) { return ENGINE_RESULT_OK; }
static engine_result_t tick(void *, uint32_t) { return ENGINE_RESULT_OK; }
int main() {
    engine_runtime_provider_v1_t provider{};
    provider.struct_size = sizeof(provider);
    provider.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
    provider.runtime_id_utf8 = "shutdown-fixture";
    provider.display_name_utf8 = "Shutdown fixture";
    provider.probe = probe; provider.create = create; provider.destroy = destroy;
    provider.open_game = open_game; provider.tick = tick;
    assert(engine_register_runtime_provider(&provider) == ENGINE_RESULT_OK);
    engine_create_desc_t config{};
    config.struct_size = sizeof(config); config.api_version = ENGINE_API_VERSION;
    engine_handle_t engine = nullptr;
    assert(engine_create(&config, &engine) == ENGINE_RESULT_OK);
    assert(engine_open_game_async(engine, "/fixture", nullptr) == ENGINE_RESULT_OK);
    const auto begin = std::chrono::steady_clock::now();
    assert(engine_begin_shutdown(engine) == ENGINE_RESULT_OK);
    assert(engine_begin_shutdown(engine) == ENGINE_RESULT_OK);
    uint32_t complete = 99;
    assert(engine_poll_shutdown(engine, &complete) == ENGINE_RESULT_OK && complete == 0);
    assert(!destroyed.load());
    assert(engine_tick(engine, 16) == ENGINE_RESULT_INVALID_STATE);
    assert(engine_destroy(engine) == ENGINE_RESULT_INVALID_STATE);
    assert(std::chrono::steady_clock::now() - begin < std::chrono::seconds(1));
    may_finish.store(true);
    for (int i = 0; i < 1000 && !complete; ++i) {
        assert(engine_poll_shutdown(engine, &complete) == ENGINE_RESULT_OK);
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    assert(complete && destroyed.load());
    assert(engine_destroy(engine) == ENGINE_RESULT_OK);
    assert(engine_destroy(nullptr) == ENGINE_RESULT_OK);
}
