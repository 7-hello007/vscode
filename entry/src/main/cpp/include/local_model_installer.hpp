#ifndef HISH_LOCAL_MODEL_INSTALLER_HPP
#define HISH_LOCAL_MODEL_INSTALLER_HPP

#include <string>

struct NativeResourceManager;

namespace hish::ai {

/**
 * Streams the bundled GGUF rawfile into the application sandbox, verifies its
 * pinned size and SHA-256, and atomically publishes it at the final path.
 */
bool prepareBundledModel(
    const NativeResourceManager *resourceManager, const std::string &filesDir,
    std::string &modelPath, std::string &errorCode, std::string &error);

} // namespace hish::ai

#endif // HISH_LOCAL_MODEL_INSTALLER_HPP
