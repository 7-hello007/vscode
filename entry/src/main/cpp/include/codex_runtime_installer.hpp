#ifndef HISH_CODEX_RUNTIME_INSTALLER_HPP
#define HISH_CODEX_RUNTIME_INSTALLER_HPP

#include "rawfile/raw_file_manager.h"

#include <string>

namespace hish::codex {

bool prepareBundledRuntime(
    const NativeResourceManager *resourceManager, const std::string &targetPath,
    std::string &errorCode, std::string &error);

} // namespace hish::codex

#endif // HISH_CODEX_RUNTIME_INSTALLER_HPP
