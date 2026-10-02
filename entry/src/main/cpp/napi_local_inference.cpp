#include "include/napi_local_inference.hpp"

#include "include/local_inference_runtime.hpp"
#include "include/local_model_installer.hpp"
#include "hilog/log.h"
#include "rawfile/raw_file_manager.h"

#include <chrono>
#include <string>
#include <utility>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3305
#define LOG_TAG "HiSH_LocalAI_NAPI"

namespace {

using SteadyClock = std::chrono::steady_clock;

int64_t elapsedMilliseconds(const SteadyClock::time_point &start)
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        SteadyClock::now() - start).count();
}

struct GenerateWork {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string prompt;
    std::string output;
    std::string errorCode;
    std::string error;
    SteadyClock::time_point queuedAt;
    bool success = false;
};

struct PrepareWork {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    napi_ref resourceManagerRef = nullptr;
    NativeResourceManager *resourceManager = nullptr;
    std::string filesDir;
    std::string modelPath;
    std::string errorCode;
    std::string error;
    bool success = false;
};

struct LoadWork {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string path;
    std::string errorCode;
    std::string error;
    SteadyClock::time_point queuedAt;
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

bool readStringValue(napi_env env, napi_value argument, std::string &value)
{
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, argument, &type) != napi_ok || type != napi_string) {
        return false;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, argument, nullptr, 0, &length) != napi_ok) {
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

bool readStringArgument(napi_env env, napi_callback_info info, std::string &value)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "Exactly one string argument is required");
        return false;
    }

    if (!readStringValue(env, argv[0], value)) {
        napi_throw_type_error(env, nullptr, "Argument must be a string");
        return false;
    }
    return true;
}

void releasePrepareResources(napi_env env, PrepareWork *work)
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
    work->success = hish::ai::prepareBundledModel(
        work->resourceManager, work->filesDir, work->modelPath,
        work->errorCode, work->error);
}

void completePrepare(napi_env env, napi_status status, void *data)
{
    auto *work = static_cast<PrepareWork *>(data);
    releasePrepareResources(env, work);
    if (status == napi_ok && work->success) {
        napi_value result = nullptr;
        napi_create_string_utf8(env, work->modelPath.c_str(), work->modelPath.size(), &result);
        napi_resolve_deferred(env, work->deferred, result);
    } else {
        if (work->errorCode.empty()) {
            work->errorCode = "MODEL_PREPARE_FAILED";
        }
        if (work->error.empty()) {
            work->error = "Bundled local model preparation did not complete";
        }
        napi_reject_deferred(env, work->deferred,
            createError(env, work->errorCode, work->error));
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value prepareBundledModel(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc != 2) {
        napi_throw_type_error(env, nullptr, "ResourceManager and filesDir are required");
        return nullptr;
    }
    napi_valuetype managerType = napi_undefined;
    if (napi_typeof(env, argv[0], &managerType) != napi_ok || managerType != napi_object) {
        napi_throw_type_error(env, nullptr, "ResourceManager must be an object");
        return nullptr;
    }

    auto *work = new PrepareWork();
    work->env = env;
    if (!readStringValue(env, argv[1], work->filesDir) || work->filesDir.empty()) {
        delete work;
        napi_throw_type_error(env, nullptr, "filesDir must be a non-empty string");
        return nullptr;
    }
    work->resourceManager = OH_ResourceManager_InitNativeResourceManager(env, argv[0]);
    if (work->resourceManager == nullptr) {
        delete work;
        napi_throw_error(env, "MODEL_PREPARE_FAILED", "Unable to access application resources");
        return nullptr;
    }
    if (napi_create_reference(env, argv[0], 1, &work->resourceManagerRef) != napi_ok) {
        releasePrepareResources(env, work);
        delete work;
        napi_throw_error(env, "MODEL_PREPARE_FAILED", "Unable to retain application resources");
        return nullptr;
    }

    napi_value promise = nullptr;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        releasePrepareResources(env, work);
        delete work;
        napi_throw_error(env, "MODEL_PREPARE_FAILED", "Unable to create model preparation promise");
        return nullptr;
    }

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "HiSHPrepareBundledModel", NAPI_AUTO_LENGTH, &resourceName);
    const napi_status createStatus = napi_create_async_work(
        env, nullptr, resourceName, executePrepare, completePrepare, work, &work->work);
    if (createStatus != napi_ok) {
        napi_reject_deferred(env, work->deferred,
            createError(env, "MODEL_PREPARE_FAILED", "Unable to create model preparation work"));
        releasePrepareResources(env, work);
        delete work;
        return promise;
    }
    const napi_status queueStatus = napi_queue_async_work(env, work->work);
    if (queueStatus != napi_ok) {
        napi_reject_deferred(env, work->deferred,
            createError(env, "MODEL_PREPARE_FAILED", "Unable to queue model preparation work"));
        napi_delete_async_work(env, work->work);
        releasePrepareResources(env, work);
        delete work;
    }
    return promise;
}

void executeLoad(napi_env env, void *data)
{
    (void) env;
    auto *work = static_cast<LoadWork *>(data);
    OH_LOG_INFO(
        LOG_APP, "load worker start queue_wait_ms=%{public}lld",
        static_cast<long long>(elapsedMilliseconds(work->queuedAt)));
    work->success = hish::ai::LocalInferenceRuntime::instance().loadModel(
        work->path, work->errorCode, work->error);
}

void completeLoad(napi_env env, napi_status status, void *data)
{
    auto *work = static_cast<LoadWork *>(data);
    OH_LOG_INFO(
        LOG_APP, "load worker complete napi_status=%{public}d success=%{public}d total_ms=%{public}lld",
        static_cast<int32_t>(status), work->success ? 1 : 0,
        static_cast<long long>(elapsedMilliseconds(work->queuedAt)));
    if (status == napi_ok && work->success) {
        napi_value result = nullptr;
        napi_get_boolean(env, true, &result);
        napi_resolve_deferred(env, work->deferred, result);
    } else {
        if (work->errorCode.empty()) {
            work->errorCode = "MODEL_LOAD_FAILED";
        }
        if (work->error.empty()) {
            work->error = "Local model loading did not complete";
        }
        napi_reject_deferred(env, work->deferred,
            createError(env, work->errorCode, work->error));
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value loadModel(napi_env env, napi_callback_info info)
{
    std::string path;
    if (!readStringArgument(env, info, path)) {
        return nullptr;
    }

    auto *work = new LoadWork();
    work->env = env;
    work->path = std::move(path);
    work->queuedAt = SteadyClock::now();
    OH_LOG_INFO(LOG_APP, "load work queued");

    napi_value promise = nullptr;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, "MODEL_LOAD_FAILED", "Unable to create model loading promise");
        return nullptr;
    }

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "HiSHLocalModelLoad", NAPI_AUTO_LENGTH, &resourceName);
    const napi_status createStatus = napi_create_async_work(
        env, nullptr, resourceName, executeLoad, completeLoad, work, &work->work);
    if (createStatus != napi_ok) {
        napi_reject_deferred(env, work->deferred,
            createError(env, "MODEL_LOAD_FAILED", "Unable to create model loading work"));
        delete work;
        return promise;
    }
    const napi_status queueStatus = napi_queue_async_work(env, work->work);
    if (queueStatus != napi_ok) {
        napi_reject_deferred(env, work->deferred,
            createError(env, "MODEL_LOAD_FAILED", "Unable to queue model loading work"));
        napi_delete_async_work(env, work->work);
        delete work;
    }
    return promise;
}

void executeGenerate(napi_env env, void *data)
{
    (void) env;
    auto *work = static_cast<GenerateWork *>(data);
    OH_LOG_INFO(
        LOG_APP, "generate worker start queue_wait_ms=%{public}lld",
        static_cast<long long>(elapsedMilliseconds(work->queuedAt)));
    work->success = hish::ai::LocalInferenceRuntime::instance().generate(
        work->prompt, work->output, work->errorCode, work->error);
}

void completeGenerate(napi_env env, napi_status status, void *data)
{
    auto *work = static_cast<GenerateWork *>(data);
    OH_LOG_INFO(
        LOG_APP,
        "generate worker complete napi_status=%{public}d success=%{public}d total_ms=%{public}lld",
        static_cast<int32_t>(status), work->success ? 1 : 0,
        static_cast<long long>(elapsedMilliseconds(work->queuedAt)));
    if (status == napi_ok && work->success) {
        napi_value result = nullptr;
        napi_create_string_utf8(env, work->output.c_str(), work->output.size(), &result);
        napi_resolve_deferred(env, work->deferred, result);
    } else {
        if (work->errorCode.empty()) {
            work->errorCode = "GENERATION_FAILED";
        }
        if (work->error.empty()) {
            work->error = "Local generation did not complete";
        }
        napi_reject_deferred(
            env, work->deferred, createError(env, work->errorCode, work->error));
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value generate(napi_env env, napi_callback_info info)
{
    std::string prompt;
    if (!readStringArgument(env, info, prompt)) {
        return nullptr;
    }

    auto *work = new GenerateWork();
    work->env = env;
    work->prompt = std::move(prompt);
    work->queuedAt = SteadyClock::now();
    OH_LOG_INFO(
        LOG_APP, "generate work queued input_bytes=%{public}zu", work->prompt.size());

    napi_value promise = nullptr;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, "GENERATION_FAILED", "Unable to create generation promise");
        return nullptr;
    }

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "HiSHLocalGenerate", NAPI_AUTO_LENGTH, &resourceName);
    const napi_status createStatus = napi_create_async_work(
        env, nullptr, resourceName, executeGenerate, completeGenerate, work, &work->work);
    if (createStatus != napi_ok) {
        napi_reject_deferred(env, work->deferred,
            createError(env, "GENERATION_FAILED", "Unable to create generation work"));
        delete work;
        return promise;
    }

    const napi_status queueStatus = napi_queue_async_work(env, work->work);
    if (queueStatus != napi_ok) {
        napi_reject_deferred(env, work->deferred,
            createError(env, "GENERATION_FAILED", "Unable to queue generation work"));
        napi_delete_async_work(env, work->work);
        delete work;
    }
    return promise;
}

napi_value stop(napi_env env, napi_callback_info info)
{
    (void) info;
    hish::ai::LocalInferenceRuntime::instance().stop();
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

napi_value unload(napi_env env, napi_callback_info info)
{
    (void) info;
    hish::ai::LocalInferenceRuntime::instance().unload();
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

} // namespace

void registerLocalInferenceFunctions(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"prepareBundledModel", nullptr, prepareBundledModel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"loadModel", nullptr, loadModel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"generate", nullptr, generate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"unload", nullptr, unload, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports,
        sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
}
