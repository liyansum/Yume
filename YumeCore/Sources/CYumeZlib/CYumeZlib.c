#include "CYumeZlib.h"

#include <iconv.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <zlib.h>

#define YUME_BUFFER_SIZE (64 * 1024)

int32_t yume_zip_extract_entry(
    const char *input_path,
    uint64_t data_offset,
    uint64_t compressed_size,
    uint16_t compression_method,
    const char *output_path,
    uint64_t expected_size,
    uint32_t expected_crc32
) {
    if (compression_method != 0 && compression_method != 8) {
        return YUME_ZIP_UNSUPPORTED_METHOD;
    }

    FILE *input = fopen(input_path, "rb");
    if (input == NULL) return YUME_ZIP_INPUT_OPEN_FAILED;
    FILE *output = fopen(output_path, "wb");
    if (output == NULL) {
        fclose(input);
        return YUME_ZIP_OUTPUT_OPEN_FAILED;
    }
    if (fseeko(input, (off_t)data_offset, SEEK_SET) != 0) {
        fclose(input);
        fclose(output);
        return YUME_ZIP_SEEK_FAILED;
    }

    unsigned char input_buffer[YUME_BUFFER_SIZE];
    unsigned char output_buffer[YUME_BUFFER_SIZE];
    uint64_t remaining = compressed_size;
    uint64_t written = 0;
    uLong crc = crc32(0L, Z_NULL, 0);
    int32_t result = YUME_ZIP_OK;

    if (compression_method == 0) {
        while (remaining > 0) {
            size_t requested = remaining > YUME_BUFFER_SIZE ? YUME_BUFFER_SIZE : (size_t)remaining;
            size_t read_count = fread(input_buffer, 1, requested, input);
            if (read_count != requested) {
                result = YUME_ZIP_READ_FAILED;
                break;
            }
            if (fwrite(input_buffer, 1, read_count, output) != read_count) {
                result = YUME_ZIP_WRITE_FAILED;
                break;
            }
            crc = crc32(crc, input_buffer, (uInt)read_count);
            written += read_count;
            remaining -= read_count;
        }
    } else {
        z_stream stream;
        memset(&stream, 0, sizeof(stream));
        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
            result = YUME_ZIP_INFLATE_FAILED;
        } else {
            int z_result = Z_OK;
            while (result == YUME_ZIP_OK && z_result != Z_STREAM_END) {
                if (stream.avail_in == 0 && remaining > 0) {
                    size_t requested = remaining > YUME_BUFFER_SIZE ? YUME_BUFFER_SIZE : (size_t)remaining;
                    size_t read_count = fread(input_buffer, 1, requested, input);
                    if (read_count != requested) {
                        result = YUME_ZIP_READ_FAILED;
                        break;
                    }
                    stream.next_in = input_buffer;
                    stream.avail_in = (uInt)read_count;
                    remaining -= read_count;
                }

                stream.next_out = output_buffer;
                stream.avail_out = YUME_BUFFER_SIZE;
                z_result = inflate(&stream, Z_NO_FLUSH);
                if (z_result != Z_OK && z_result != Z_STREAM_END) {
                    result = YUME_ZIP_INFLATE_FAILED;
                    break;
                }
                size_t produced = YUME_BUFFER_SIZE - stream.avail_out;
                if (produced > 0) {
                    if (written > expected_size || produced > expected_size - written) {
                        result = YUME_ZIP_SIZE_MISMATCH;
                        break;
                    }
                    if (fwrite(output_buffer, 1, produced, output) != produced) {
                        result = YUME_ZIP_WRITE_FAILED;
                        break;
                    }
                    crc = crc32(crc, output_buffer, (uInt)produced);
                    written += produced;
                }
                if (stream.avail_in == 0 && remaining == 0 && z_result != Z_STREAM_END) {
                    result = YUME_ZIP_INFLATE_FAILED;
                    break;
                }
            }
            inflateEnd(&stream);
            if (result == YUME_ZIP_OK && remaining != 0) result = YUME_ZIP_SIZE_MISMATCH;
        }
    }

    if (fclose(input) != 0 && result == YUME_ZIP_OK) result = YUME_ZIP_READ_FAILED;
    if (fclose(output) != 0 && result == YUME_ZIP_OK) result = YUME_ZIP_WRITE_FAILED;
    if (result == YUME_ZIP_OK && written != expected_size) result = YUME_ZIP_SIZE_MISMATCH;
    if (result == YUME_ZIP_OK && (uint32_t)crc != expected_crc32) result = YUME_ZIP_CRC_MISMATCH;
    return result;
}

int32_t yume_zlib_inflate_to_file(
    const char *input_path,
    uint64_t data_offset,
    uint64_t compressed_size,
    const char *output_path,
    uint64_t expected_size
) {
    FILE *input = fopen(input_path, "rb");
    if (input == NULL) return YUME_ZIP_INPUT_OPEN_FAILED;
    FILE *output = fopen(output_path, "wb");
    if (output == NULL) {
        fclose(input);
        return YUME_ZIP_OUTPUT_OPEN_FAILED;
    }
    if (fseeko(input, (off_t)data_offset, SEEK_SET) != 0) {
        fclose(input);
        fclose(output);
        return YUME_ZIP_SEEK_FAILED;
    }

    unsigned char input_buffer[YUME_BUFFER_SIZE];
    unsigned char output_buffer[YUME_BUFFER_SIZE];
    uint64_t remaining = compressed_size;
    uint64_t written = 0;
    int32_t result = YUME_ZIP_OK;

    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit(&stream) != Z_OK) {
        result = YUME_ZIP_INFLATE_FAILED;
    } else {
        int z_result = Z_OK;
        while (result == YUME_ZIP_OK && z_result != Z_STREAM_END) {
            if (stream.avail_in == 0 && remaining > 0) {
                size_t requested = remaining > YUME_BUFFER_SIZE ? YUME_BUFFER_SIZE : (size_t)remaining;
                size_t read_count = fread(input_buffer, 1, requested, input);
                if (read_count == 0) {
                    result = YUME_ZIP_READ_FAILED;
                    break;
                }
                stream.next_in = input_buffer;
                stream.avail_in = (uInt)read_count;
                remaining -= read_count;
            }

            stream.next_out = output_buffer;
            stream.avail_out = YUME_BUFFER_SIZE;
            z_result = inflate(&stream, Z_NO_FLUSH);
            if (z_result != Z_OK && z_result != Z_STREAM_END) {
                result = YUME_ZIP_INFLATE_FAILED;
                break;
            }
            size_t produced = YUME_BUFFER_SIZE - stream.avail_out;
            if (produced > 0) {
                if (written > expected_size || produced > expected_size - written) {
                    result = YUME_ZIP_SIZE_MISMATCH;
                    break;
                }
                if (fwrite(output_buffer, 1, produced, output) != produced) {
                    result = YUME_ZIP_WRITE_FAILED;
                    break;
                }
                written += produced;
            }
            if (stream.avail_in == 0 && remaining == 0 && z_result != Z_STREAM_END) {
                result = YUME_ZIP_INFLATE_FAILED;
                break;
            }
        }
        inflateEnd(&stream);

        if (result == YUME_ZIP_OK && written != expected_size) result = YUME_ZIP_SIZE_MISMATCH;

        if (result == YUME_ZIP_OK && remaining != 0) result = YUME_ZIP_SIZE_MISMATCH;
    }

    if (fclose(input) != 0 && result == YUME_ZIP_OK) result = YUME_ZIP_READ_FAILED;
    if (fclose(output) != 0 && result == YUME_ZIP_OK) result = YUME_ZIP_WRITE_FAILED;
    return result;
}

int32_t yume_deflate_raw_to_file(
    const char *input_path,
    uint64_t data_offset,
    uint64_t compressed_size,
    const char *output_path,
    uint64_t expected_size
) {
    FILE *input = fopen(input_path, "rb");
    if (input == NULL) return YUME_ZIP_INPUT_OPEN_FAILED;
    FILE *output = fopen(output_path, "wb");
    if (output == NULL) {
        fclose(input);
        return YUME_ZIP_OUTPUT_OPEN_FAILED;
    }
    if (fseeko(input, (off_t)data_offset, SEEK_SET) != 0) {
        fclose(input);
        fclose(output);
        return YUME_ZIP_SEEK_FAILED;
    }

    unsigned char input_buffer[YUME_BUFFER_SIZE];
    unsigned char output_buffer[YUME_BUFFER_SIZE];
    uint64_t remaining = compressed_size;
    uint64_t written = 0;
    int32_t result = YUME_ZIP_OK;

    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
        result = YUME_ZIP_INFLATE_FAILED;
    } else {
        int z_result = Z_OK;
        while (result == YUME_ZIP_OK && z_result != Z_STREAM_END) {
            if (stream.avail_in == 0 && remaining > 0) {
                size_t requested = remaining > YUME_BUFFER_SIZE ? YUME_BUFFER_SIZE : (size_t)remaining;
                size_t read_count = fread(input_buffer, 1, requested, input);
                if (read_count == 0) {
                    result = YUME_ZIP_READ_FAILED;
                    break;
                }
                stream.next_in = input_buffer;
                stream.avail_in = (uInt)read_count;
                remaining -= read_count;
            }

            stream.next_out = output_buffer;
            stream.avail_out = YUME_BUFFER_SIZE;
            z_result = inflate(&stream, Z_NO_FLUSH);
            if (z_result != Z_OK && z_result != Z_STREAM_END) {
                result = YUME_ZIP_INFLATE_FAILED;
                break;
            }
            size_t produced = YUME_BUFFER_SIZE - stream.avail_out;
            if (produced > 0) {
                if (written > expected_size || produced > expected_size - written) {
                    result = YUME_ZIP_SIZE_MISMATCH;
                    break;
                }
                if (fwrite(output_buffer, 1, produced, output) != produced) {
                    result = YUME_ZIP_WRITE_FAILED;
                    break;
                }
                written += produced;
            }
            if (stream.avail_in == 0 && remaining == 0 && z_result != Z_STREAM_END) {
                result = YUME_ZIP_INFLATE_FAILED;
                break;
            }
        }
        inflateEnd(&stream);

        if (result == YUME_ZIP_OK && remaining != 0) result = YUME_ZIP_SIZE_MISMATCH;
    }

    if (fclose(input) != 0 && result == YUME_ZIP_OK) result = YUME_ZIP_READ_FAILED;
    if (fclose(output) != 0 && result == YUME_ZIP_OK) result = YUME_ZIP_WRITE_FAILED;
    if (result == YUME_ZIP_OK && written != expected_size) result = YUME_ZIP_SIZE_MISMATCH;
    return result;
}

int32_t yume_zlib_inflate_mem(
    const unsigned char *input_buffer,
    uint64_t compressed_size,
    unsigned char *output_buffer,
    uint64_t output_capacity,
    uint64_t *written_byte_count
) {
    if (input_buffer == NULL || output_buffer == NULL || written_byte_count == NULL) {
        return YUME_ZIP_OUTPUT_OPEN_FAILED;
    }
    *written_byte_count = 0;

    uint64_t written = 0;
    int32_t result = YUME_ZIP_OK;

    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit(&stream) != Z_OK) {
        return YUME_ZIP_INFLATE_FAILED;
    }

    if (compressed_size > UINT_MAX) {
        inflateEnd(&stream);
        return YUME_ZIP_SIZE_MISMATCH;
    }
    stream.next_in = (Bytef *)input_buffer;
    stream.avail_in = (uInt)compressed_size;

    int z_result = Z_OK;
    while (z_result != Z_STREAM_END) {
        uint64_t capacity_left = written < output_capacity ? output_capacity - written : 0;
        if (capacity_left == 0) {
            result = YUME_ZIP_SIZE_MISMATCH;
            break;
        }
        uInt output_chunk = capacity_left > YUME_BUFFER_SIZE
            ? YUME_BUFFER_SIZE
            : (uInt)capacity_left;
        stream.next_out = output_buffer + written;
        stream.avail_out = output_chunk;
        z_result = inflate(&stream, Z_NO_FLUSH);
        if (z_result != Z_OK && z_result != Z_STREAM_END) {
            result = YUME_ZIP_INFLATE_FAILED;
            break;
        }
        size_t produced = output_chunk - stream.avail_out;
        written += produced;
    }
    uInt unread_input = stream.avail_in;
    inflateEnd(&stream);

    if (result == YUME_ZIP_OK && written > output_capacity) result = YUME_ZIP_SIZE_MISMATCH;
    if (result == YUME_ZIP_OK && unread_input != 0) result = YUME_ZIP_SIZE_MISMATCH;

    if (result == YUME_ZIP_OK) *written_byte_count = written;
    return result;
}

int32_t yume_decode_archive_filename(
    const unsigned char *bytes,
    uint32_t byte_count,
    char *utf8_out,
    uint32_t utf8_capacity,
    uint32_t *utf8_length
) {
    if (bytes == NULL || utf8_out == NULL || utf8_length == NULL || utf8_capacity < 2) {
        return -1;
    }

    static const char *encodings[] = {
        "UTF-8",
        "CP932",
        "SHIFT_JIS",
        "GBK",
        "GB18030",
        "BIG5",
        "EUC-KR",
        "CP437",
        NULL
    };

    for (int index = 0; encodings[index] != NULL; ++index) {
        iconv_t converter = iconv_open("UTF-8", encodings[index]);
        if (converter == (iconv_t)-1) continue;

        char *input = (char *)bytes;
        size_t input_remaining = byte_count;
        char *output = utf8_out;
        size_t output_remaining = utf8_capacity - 1;
        size_t converted = iconv(
            converter,
            &input,
            &input_remaining,
            &output,
            &output_remaining
        );
        iconv_close(converter);
        if (converted == (size_t)-1 || input_remaining != 0) continue;

        *output = '\0';
        *utf8_length = (uint32_t)((utf8_capacity - 1) - output_remaining);
        return 0;
    }
    return -1;
}
