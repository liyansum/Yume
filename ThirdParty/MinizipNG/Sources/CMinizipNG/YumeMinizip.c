#include "YumeMinizip.h"

#include "mz.h"
#include "mz_strm.h"
#include "mz_strm_os.h"
#include "mz_zip.h"

#include <stdio.h>

int32_t yume_minizip_extract_entry(
    const char *archive_path,
    const char *entry_name,
    const char *password,
    const char *output_path,
    uint64_t expected_size
) {
    if (!archive_path || !entry_name || !output_path) return MZ_PARAM_ERROR;

    void *stream = mz_stream_os_create();
    void *zip = mz_zip_create();
    FILE *output = NULL;
    int32_t result = MZ_MEM_ERROR;
    uint64_t written = 0;

    if (!stream || !zip) goto cleanup;
    result = mz_stream_os_open(stream, archive_path, MZ_OPEN_MODE_READ | MZ_OPEN_MODE_EXISTING | MZ_OPEN_MODE_NOFOLLOW);
    if (result != MZ_OK) goto cleanup;
    result = mz_zip_open(zip, stream, MZ_OPEN_MODE_READ);
    if (result != MZ_OK) goto cleanup;
    result = mz_zip_locate_entry(zip, entry_name, 0);
    if (result != MZ_OK) goto cleanup;

    mz_zip_file *info = NULL;
    result = mz_zip_entry_get_info(zip, &info);
    if (result != MZ_OK || !info || info->uncompressed_size < 0
        || (uint64_t)info->uncompressed_size != expected_size) {
        result = MZ_FORMAT_ERROR;
        goto cleanup;
    }

    result = mz_zip_entry_read_open(zip, 0, password);
    if (result != MZ_OK) goto cleanup;
    output = fopen(output_path, "wb");
    if (!output) {
        result = MZ_OPEN_ERROR;
        mz_zip_entry_read_close(zip, NULL, NULL, NULL);
        goto cleanup;
    }

    uint8_t buffer[64 * 1024];
    for (;;) {
        int32_t count = mz_zip_entry_read(zip, buffer, (int32_t)sizeof(buffer));
        if (count < 0) {
            result = count;
            break;
        }
        if (count == 0) {
            result = MZ_OK;
            break;
        }
        if (written > expected_size || (uint64_t)count > expected_size - written) {
            result = MZ_FORMAT_ERROR;
            break;
        }
        if (fwrite(buffer, 1, (size_t)count, output) != (size_t)count) {
            result = MZ_WRITE_ERROR;
            break;
        }
        written += (uint64_t)count;
    }

    {
        int32_t close_result = mz_zip_entry_read_close(zip, NULL, NULL, NULL);
        if (result == MZ_OK && close_result != MZ_OK) result = close_result;
    }
    if (result == MZ_OK && written != expected_size) result = MZ_FORMAT_ERROR;

cleanup:
    if (output && fclose(output) != 0 && result == MZ_OK) result = MZ_WRITE_ERROR;
    if (zip) {
        mz_zip_close(zip);
        mz_zip_delete(&zip);
    }
    if (stream) {
        mz_stream_os_close(stream);
        mz_stream_os_delete(&stream);
    }
    if (result != MZ_OK && output_path) remove(output_path);
    return result;
}
