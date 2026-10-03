#include "include/napi_codex_runtime.hpp"

#include "include/codex_runtime_installer.hpp"
#include "rawfile/raw_file_manager.h"

#include <string>

namespace {

struct PrepareWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    napi_ref resourceManagerRef = nullptr;
    NativeResourceManager *resourceManager = nullptr;
    std::string targetPath;
    std::string errorCode;
    std::string error;
    bool success = false;
};

napi_value createError(napi_env env, const std::string &code, const std::string &message)
{
    napi_value codeValue = nullptr;
    napi_value messageValue = nullptr;
    napi_value errorValue = nullptr;
    napi_create_string_utf8(env, code.c_str(), code.size(), &codeValue);
    const std::string detailedMessage = code + ": " + message;
    napi_create_string_utf8(env, detailedMessage.c_str(), detailedMessage.size(), &messageValue);
    napi_create_error(env, codeValue, messageValue, &errorValue);
    return errorValue;
}

bool readString(napi_env env, napi_value argument, std::string &value)
{
    napi_valuetype type = napi_undefined;
    size_t length = 0;
    if (napi_typeof(env, argument, &type) != napi_ok || type != napi_string ||
        napi_get_value_string_utf8(env, argument, nullptr, 0, &length) != napi_ok) {
        return false;
    }
    value.resize(length + 1);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, argument, value.data(), length + 1, &copied) != napi_ok) {
        return false;
    }
    value.resize(copied);
    return true;
}

void releaseResources(napi_env env, PrepareWork *work)
{
    if (work->resourceManager != nullptr) {
        OH_ResourceManager_ReleaseNativeResourceManager(work->resourceManager);
        work->resourceManager = nullptr;
    }
    if (work->resourceManagerRef != nullptr) {
        napi_delete_reference(env, work->resourceManagerRef);
        work->resourceManagerRef = nullptr;
    }
}

void executePrepare(napi_env env, void *data)
{
    (void) env;
    auto *work = static_cast<PrepareWork *>(data);
    work->success = hish::codex::prepareBundledRuntime(
        work->resourceManager, work->targetPath, work->errorCode, work->error);
}

void completePrepare(napi_env env, napi_status status, void *data)
{
    auto *work = static_cast<PrepareWork *>(data);
    releaseResources(env, work);
    if (status == napi_ok && work->success) {
        napi_value result = nullptr;
        napi_create_string_utf8(env, work->targetPath.c_str(), work->targetPath.size(), &result);
        napi_resolve_deferred(env, work->deferred, result);
    } else {
        if (work->errorCode.empty()) {
            work->errorCode = "CODEX_RUNTIME_PREPARE_FAILED";
        }
        if (work->error.empty()) {
            work->error = "Bundled Codex runtime preparation did not complete";
        }
        napi_reject_deferred(env, work->deferred,
            createError(env, work->errorCode, work->error));
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value prepareBundledCodex(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc != 2) {
        napi_throw_type_error(env, nullptr, "ResourceManager and targetPath are required");
        return nullptr;
    }
    napi_valuetype managerType = napi_undefined;
    if (napi_typeof(env, argv[0], &managerType) != napi_ok || managerType != napi_object) {
        napi_throw_type_error(env, nullptr, "ResourceManager must be an object");
        return nullptr;
    }

    auto *work = new PrepareWork();
    if (!readString(env, argv[1], work->targetPath) || work->targetPath.empty()) {
        delete work;
        napi_throw_type_error(env, nullptr, "targetPath must be a non-empty string");
        return nullptr;
    }
    work->resourceManager = OH_ResourceManager_InitNativeResourceManager(env, argv[0]);
    if (work->resourceManager == nullptr ||
        napi_create_reference(env, argv[0], 1, &work->resourceManagerRef) != napi_ok) {
        releaseResources(env, work);
        delete work;
        napi_throw_error(env, "CODEX_RUNTIME_PREPARE_FAILED", "Unable to retain application resources");
        return nullptr;
    }

    napi_value promise = nullptr;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        releaseResources(env, work);
        delete work;
        napi_throw_error(env, "CODEX_RUNTIME_PREPARE_FAILED", "Unable to create runtime promise");
        return nullptr;
    }
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "HiSHPrepareBundledCodex", NAPI_AUTO_LENGTH, &resourceName);
    if (napi_create_async_work(
            env, nullptr, resourceName, executePrepare, completePrepare, work, &work->work) != napi_ok) {
        napi_reject_deferred(env, work->deferred,
            createError(env, "CODEX_RUNTIME_PREPARE_FAILED", "Unable to create runtime work"));
        releaseResources(env, work);
        delete work;
        return promise;
    }
    if (napi_queue_async_work(env, work->work) != napi_ok) {
        napi_reject_deferred(env, work->deferred,
            createError(env, "CODEX_RUNTIME_PREPARE_FAILED", "Unable to queue runtime work"));
        napi_delete_async_work(env, work->work);
        releaseResources(env, work);
        delete work;
    }
    return promise;
}

} // namespace

void registerCodexRuntimeFunctions(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"prepareBundledCodex", nullptr, prepareBundledCodex, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports,
        sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
}
