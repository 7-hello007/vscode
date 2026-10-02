#include "include/local_model_installer.hpp"

#include "rawfile/raw_file.h"
#include "rawfile/raw_file_manager.h"

extern "C" {
#include "sha256.h"
}

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <iomanip>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {

constexpr const char *MODEL_FILENAME = "qwen2.5-0.5b-instruct-q4_k_m.gguf";
constexpr const char *MODEL_RAWFILE = "models/qwen2.5-0.5b-instruct-q4_k_m.gguf";
constexpr int64_t MODEL_SIZE = 491400032;
constexpr const char *MODEL_SHA256 =
    "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db";
constexpr size_t COPY_BUFFER_SIZE = 1024 * 1024;

std::string hashToHex(const unsigned char *digest)
{
    std::ostringstream stream;
    stream << std::hex << std::setfill('0');
    for (size_t index = 0; index < SHA256_DIGEST_SIZE; index++) {
        stream << std::setw(2) << static_cast<unsigned int>(digest[index]);
    }
    return stream.str();
}

bool finishHash(sha256_t &hash, std::string &actual)
{
    unsigned char digest[SHA256_DIGEST_SIZE] = {0};
    sha256_final(&hash, digest);
    actual = hashToHex(digest);
    return actual == MODEL_SHA256;
}

bool verifyFile(const std::string &path)
{
    struct stat details = {};
    if (stat(path.c_str(), &details) != 0 || !S_ISREG(details.st_mode) ||
        details.st_size != MODEL_SIZE) {
        return false;
    }

    const int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        return false;
    }

    // FFRT async workers have a substantially smaller stack than a normal
    // application thread. Keep the 1 MiB copy chunk on the heap.
    std::vector<unsigned char> buffer(COPY_BUFFER_SIZE);
    sha256_t hash = {};
    sha256_init(&hash);
    int64_t total = 0;
    bool success = true;
    while (true) {
        const ssize_t readCount = read(fd, buffer.data(), buffer.size());
        if (readCount == 0) {
            break;
        }
        if (readCount < 0) {
            if (errno == EINTR) {
                continue;
            }
            success = false;
            break;
        }
        sha256_update(&hash, buffer.data(), static_cast<size_t>(readCount));
        total += readCount;
    }
    close(fd);

    std::string actualHash;
    return success && total == MODEL_SIZE && finishHash(hash, actualHash);
}

bool writeAll(int fd, const unsigned char *buffer, size_t size)
{
    size_t offset = 0;
    while (offset < size) {
        const ssize_t written = write(fd, buffer + offset, size - offset);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        if (written == 0) {
            return false;
        }
        offset += static_cast<size_t>(written);
    }
    return true;
}

bool ensureModelsDirectory(
    const std::string &path, std::string &errorCode, std::string &error)
{
    if (mkdir(path.c_str(), 0700) == 0 || errno == EEXIST) {
        struct stat details = {};
        if (stat(path.c_str(), &details) == 0 && S_ISDIR(details.st_mode)) {
            return true;
        }
    }
    errorCode = "MODEL_PREPARE_FAILED";
    error = "Unable to create the local model sandbox directory";
    return false;
}

} // namespace

namespace hish::ai {

bool prepareBundledModel(
    const NativeResourceManager *resourceManager, const std::string &filesDir,
    std::string &modelPath, std::string &errorCode, std::string &error)
{
    if (resourceManager == nullptr || filesDir.empty()) {
        errorCode = "MODEL_PREPARE_FAILED";
        error = "Application resources or files directory are unavailable";
        return false;
    }

    const std::string modelsDir = filesDir + "/models";
    modelPath = modelsDir + "/" + MODEL_FILENAME;
    const std::string temporaryPath = modelPath + ".tmp";
    if (!ensureModelsDirectory(modelsDir, errorCode, error)) {
        return false;
    }
    if (verifyFile(modelPath)) {
        return true;
    }

    RawFile64 *rawFile = OH_ResourceManager_OpenRawFile64(resourceManager, MODEL_RAWFILE);
    if (rawFile == nullptr) {
        errorCode = "MODEL_RESOURCE_NOT_FOUND";
        error = "Bundled local model resource was not found";
        return false;
    }
    const int64_t rawSize = OH_ResourceManager_GetRawFileSize64(rawFile);
    if (rawSize != MODEL_SIZE) {
        OH_ResourceManager_CloseRawFile64(rawFile);
        errorCode = "MODEL_RESOURCE_INVALID";
        error = "Bundled local model size does not match the pinned artifact";
        return false;
    }

    const int output = open(temporaryPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (output < 0) {
        OH_ResourceManager_CloseRawFile64(rawFile);
        errorCode = "MODEL_PREPARE_FAILED";
        error = "Unable to create the temporary local model file";
        return false;
    }

    // Do not place the copy chunk on the NativeAsyncWork/FFRT worker stack.
    std::vector<unsigned char> buffer(COPY_BUFFER_SIZE);
    sha256_t hash = {};
    sha256_init(&hash);
    int64_t total = 0;
    bool copied = true;
    while (total < MODEL_SIZE) {
        const int64_t remaining = MODEL_SIZE - total;
        const int64_t requested = remaining < static_cast<int64_t>(buffer.size()) ?
            remaining : static_cast<int64_t>(buffer.size());
        const int64_t readCount = OH_ResourceManager_ReadRawFile64(rawFile, buffer.data(), requested);
        if (readCount <= 0 || readCount > requested ||
            !writeAll(output, buffer.data(), static_cast<size_t>(readCount))) {
            copied = false;
            break;
        }
        sha256_update(&hash, buffer.data(), static_cast<size_t>(readCount));
        total += readCount;
    }

    OH_ResourceManager_CloseRawFile64(rawFile);
    if (copied && fsync(output) != 0) {
        copied = false;
    }
    if (close(output) != 0) {
        copied = false;
    }

    std::string actualHash;
    const bool valid = copied && total == MODEL_SIZE && finishHash(hash, actualHash);
    if (!valid) {
        unlink(temporaryPath.c_str());
        errorCode = copied ? "MODEL_RESOURCE_INVALID" : "MODEL_PREPARE_FAILED";
        error = copied ? "Bundled local model SHA-256 verification failed" :
            "Unable to copy the bundled local model into the application sandbox";
        return false;
    }

    if (rename(temporaryPath.c_str(), modelPath.c_str()) != 0) {
        unlink(temporaryPath.c_str());
        errorCode = "MODEL_PREPARE_FAILED";
        error = "Unable to atomically publish the verified local model";
        return false;
    }
    return true;
}

} // namespace hish::ai
