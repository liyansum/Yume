#pragma once

#include <cstdint>
#include <filesystem>
#include <string>

namespace aetherkiri::onscripter {

struct SaveStorageResult {
    std::filesystem::path directory;
    bool using_game_directory = false;
    uint32_t migrated_files = 0;
    std::string warning;
};

bool IsOnsSaveFileName(const std::filesystem::path &path);

// Prefer the host-owned per-game save directory. Older builds wrote beside
// the imported game, so those files are migration sources and a last-resort
// fallback only. Existing files never overwrite the canonical destination.
SaveStorageResult PrepareSaveStorage(
    const std::filesystem::path &game_root,
    const std::filesystem::path &host_directory);

} // namespace aetherkiri::onscripter
