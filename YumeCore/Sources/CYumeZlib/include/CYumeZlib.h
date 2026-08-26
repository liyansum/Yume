#ifndef CYUME_ZLIB_H
#define CYUME_ZLIB_H

#include <stdint.h>

enum {
    YUME_ZIP_OK = 0,
    YUME_ZIP_INPUT_OPEN_FAILED = 1,
    YUME_ZIP_OUTPUT_OPEN_FAILED = 2,
    YUME_ZIP_SEEK_FAILED = 3,
    YUME_ZIP_READ_FAILED = 4,
    YUME_ZIP_WRITE_FAILED = 5,
    YUME_ZIP_INFLATE_FAILED = 6,
    YUME_ZIP_SIZE_MISMATCH = 7,
    YUME_ZIP_CRC_MISMATCH = 8,
    YUME_ZIP_UNSUPPORTED_METHOD = 9
};

int32_t yume_zip_extract_entry(
    const char *input_path,
    uint64_t data_offset,
    uint64_t compressed_size,
    uint16_t compression_method,
    const char *output_path,
    uint64_t expected_size,
    uint32_t expected_crc32
);

int32_t yume_zlib_inflate_to_file(
    const char *input_path,
    uint64_t data_offset,
    uint64_t compressed_size,
    const char *output_path,
    uint64_t expected_size
);

int32_t yume_zlib_inflate_mem(
    const unsigned char *input_buffer,
    uint64_t compressed_size,
    unsigned char *output_buffer,
    uint64_t output_capacity,
    uint64_t *written_byte_count
);

#endif
