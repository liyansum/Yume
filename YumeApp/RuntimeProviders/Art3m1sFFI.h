#ifndef YUME_ART3M1S_FFI_H
#define YUME_ART3M1S_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*Art3m1sLogCallback)(const char *level, const char *message);
typedef int32_t (*Art3m1sFileReader)(const char *path, uint8_t *buffer,
                                    int32_t bufferSize, int64_t offset);
typedef int32_t (*Art3m1sFileWriter)(const char *path, const uint8_t *buffer,
                                    int32_t length);
typedef int32_t (*Art3m1sFileDelete)(const char *path);
typedef int32_t (*Art3m1sFileStat)(const char *path, int64_t *components,
                                  int32_t componentCount);

void art3m1s_register_log_callback(Art3m1sLogCallback callback);
void art3m1s_register_file_reader(Art3m1sFileReader callback);
void art3m1s_register_file_writer(Art3m1sFileWriter callback);
void art3m1s_register_file_delete(Art3m1sFileDelete callback);
void art3m1s_register_file_stat(Art3m1sFileStat callback);
void art3m1s_set_save_dir(const char *directory);
void art3m1s_set_angle_path(const char *directory);

void *art3m1s_runtime_create(uint32_t width, uint32_t height, int32_t backend);
int32_t art3m1s_runtime_load_project_bytes(void *runtime,
                                           const uint8_t *iniContent,
                                           size_t iniLength,
                                           const char *platform);
void art3m1s_runtime_feed_mouse(void *runtime, int32_t x, int32_t y);
void art3m1s_runtime_feed_click(void *runtime);
void art3m1s_runtime_feed_mouse_button(void *runtime, uint32_t button,
                                      int32_t pressed);
void art3m1s_runtime_feed_touch(void *runtime, uint32_t identifier,
                               uint8_t phase, int32_t x, int32_t y);
void art3m1s_runtime_feed_key(void *runtime, uint32_t virtualKey,
                             int32_t pressed);
void art3m1s_runtime_destroy(void *runtime);
uint32_t art3m1s_runtime_stage_width(const void *runtime);
uint32_t art3m1s_runtime_stage_height(const void *runtime);
uint32_t art3m1s_runtime_pixel_buffer_size(const void *runtime);
uint32_t art3m1s_runtime_advance_and_render(void *runtime, uint32_t deltaMs,
                                           uint8_t *pixels,
                                           uint32_t capacity);
int32_t art3m1s_runtime_is_exit_requested(const void *runtime);
void art3m1s_runtime_notify_lifecycle(void *runtime, int32_t state);

#ifdef __cplusplus
}
#endif

#endif
