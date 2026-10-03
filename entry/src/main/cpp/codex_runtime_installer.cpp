#include "include/codex_runtime_installer.hpp"

#include "rawfile/raw_file.h"

extern "C" {
#include "sha256.h"
}

#include <cerrno>
#include <cstdint>
#include <fcntl.h>
#include <iomanip>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {

constexpr const char *CODEX_RAWFILE = "codex/codex-aarch64-unknown-linux-musl";
constexpr int64_t CODEX_SIZE = 248966648;
constexpr const char *CODEX_SHA256 =
    "50b06603bdcdac39b714f5c3e68583c002b8ad8779ebfdaaf4932ff016b379c0";
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

bool isArm64Elf(const unsigned char *header, size_t size)
{
    return size >= 20 && header[0] == 0x7f && header[1] == 0x45 &&
        header[2] == 0x4c && header[3] == 0x46 && header[4] == 0x02 &&
        header[5] == 0x01 && header[18] == 0xb7 && header[19] == 0x00;
}

bool isZip(const unsigned char *header, size_t size)
{
    return size >= 4 && header[0] == 0x50 && header[1] == 0x4b &&
        header[2] == 0x03 && header[3] == 0x04;
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

bool verifyFile(const std::string &path)
{
    struct stat details = {};
    if (stat(path.c_str(), &details) != 0 || !S_ISREG(details.st_mode) ||
        details.st_size != CODEX_SIZE) {
        return false;
    }
    const int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        return false;
    }
    std::vector<unsigned char> buffer(COPY_BUFFER_SIZE);
    sha256_t hash = {};
    sha256_init(&hash);
    int64_t total = 0;
    bool valid = true;
    bool headerChecked = false;
    while (true) {
        const ssize_t readCount = read(fd, buffer.data(), buffer.size());
        if (readCount == 0) {
            break;
        }
        if (readCount < 0) {
            if (errno == EINTR) {
                continue;
            }
            valid = false;
            break;
        }
        if (!headerChecked) {
            valid = isArm64Elf(buffer.data(), static_cast<size_t>(readCount));
            headerChecked = true;
            if (!valid) {
                break;
            }
        }
        sha256_update(&hash, buffer.data(), static_cast<size_t>(readCount));
        total += readCount;
    }
    close(fd);
    unsigned char digest[SHA256_DIGEST_SIZE] = {0};
    sha256_final(&hash, digest);
    return valid && total == CODEX_SIZE && hashToHex(digest) == CODEX_SHA256;
}

} // namespace

namespace hish::codex {

bool prepareBundledRuntime(
    const NativeResourceManager *resourceManager, const std::string &targetPath,
    std::string &errorCode, std::string &error)
{
    if (resourceManager == nullptr || targetPath.empty()) {
        errorCode = "CODEX_RUNTIME_PREPARE_FAILED";
        error = "Application resources or runtime path are unavailable";
        return false;
    }
    if (verifyFile(targetPath)) {
        return true;
    }

    RawFile64 *rawFile = OH_ResourceManager_OpenRawFile64(resourceManager, CODEX_RAWFILE);
    if (rawFile == nullptr) {
        errorCode = "CODEX_RUNTIME_RESOURCE_NOT_FOUND";
        error = "Bundled Codex runtime resource was not found";
        return false;
    }
    const int64_t rawSize = OH_ResourceManager_GetRawFileSize64(rawFile);
    if (rawSize != CODEX_SIZE) {
        OH_ResourceManager_CloseRawFile64(rawFile);
        errorCode = "CODEX_RUNTIME_INVALID_BINARY";
        error = "Bundled Codex runtime size does not match the pinned artifact";
        return false;
    }

    const std::string temporaryPath = targetPath + ".tmp";
    unlink(temporaryPath.c_str());
    const int output = open(temporaryPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0700);
    if (output < 0) {
        OH_ResourceManager_CloseRawFile64(rawFile);
        errorCode = "CODEX_RUNTIME_PREPARE_FAILED";
        error = "Unable to create the temporary Codex runtime";
        return false;
    }

    std::vector<unsigned char> buffer(COPY_BUFFER_SIZE);
    sha256_t hash = {};
    sha256_init(&hash);
    int64_t total = 0;
    bool copied = true;
    bool headerChecked = false;
    while (total < CODEX_SIZE) {
        const int64_t remaining = CODEX_SIZE - total;
        const int64_t requested = remaining < static_cast<int64_t>(buffer.size()) ?
            remaining : static_cast<int64_t>(buffer.size());
        const int64_t readCount = OH_ResourceManager_ReadRawFile64(rawFile, buffer.data(), requested);
        if (readCount <= 0 || readCount > requested) {
            copied = false;
            break;
        }
        if (!headerChecked) {
            if (isZip(buffer.data(), static_cast<size_t>(readCount))) {
                errorCode = "CODEX_RUNTIME_INVALID_ARCHIVE";
                error = "Bundled Codex resource is an archive, not an executable";
                copied = false;
                break;
            }
            if (!isArm64Elf(buffer.data(), static_cast<size_t>(readCount))) {
                errorCode = "CODEX_RUNTIME_INVALID_BINARY";
                error = "Bundled Codex resource is not an ARM64 ELF executable";
                copied = false;
                break;
            }
            headerChecked = true;
        }
        if (!writeAll(output, buffer.data(), static_cast<size_t>(readCount))) {
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

    unsigned char digest[SHA256_DIGEST_SIZE] = {0};
    sha256_final(&hash, digest);
    const bool valid = copied && total == CODEX_SIZE && hashToHex(digest) == CODEX_SHA256;
    if (!valid) {
        unlink(temporaryPath.c_str());
        if (errorCode.empty()) {
            errorCode = "CODEX_RUNTIME_INVALID_BINARY";
            error = copied ? "Bundled Codex runtime SHA-256 verification failed" :
                "Unable to stream the bundled Codex runtime";
        }
        return false;
    }
    if (chmod(temporaryPath.c_str(), 0700) != 0 ||
        rename(temporaryPath.c_str(), targetPath.c_str()) != 0) {
        unlink(temporaryPath.c_str());
        errorCode = "CODEX_RUNTIME_PREPARE_FAILED";
        error = "Unable to publish the verified Codex runtime";
        return false;
    }
    return true;
}

} // namespace hish::codex
