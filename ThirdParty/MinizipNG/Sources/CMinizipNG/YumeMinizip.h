#ifndef YUME_MINIZIP_H
#define YUME_MINIZIP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t yume_minizip_extract_entry(
    const char *archive_path,
    const char *entry_name,
    const char *password,
    const char *output_path,
    uint64_t expected_size
);

#ifdef __cplusplus
}
#endif

#endif
