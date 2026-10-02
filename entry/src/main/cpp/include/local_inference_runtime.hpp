#ifndef HISH_LOCAL_INFERENCE_RUNTIME_HPP
#define HISH_LOCAL_INFERENCE_RUNTIME_HPP

#include <atomic>
#include <mutex>
#include <string>

struct llama_model;
struct llama_context;

namespace hish::ai {

/** Minimal lifecycle boundary around the pinned llama.cpp runtime. */
class LocalInferenceRuntime final {
public:
    static LocalInferenceRuntime &instance();

    LocalInferenceRuntime(const LocalInferenceRuntime &) = delete;
    LocalInferenceRuntime &operator=(const LocalInferenceRuntime &) = delete;

    bool loadModel(
        const std::string &path, std::string &errorCode, std::string &error);
    bool generate(
        const std::string &prompt, std::string &output,
        std::string &errorCode, std::string &error);
    void stop();
    void unload();

private:
    LocalInferenceRuntime() = default;
    ~LocalInferenceRuntime();

    static bool abortGeneration(void *data);
    void unloadLocked();

    std::mutex mutex_;
    std::atomic<bool> stopRequested_{false};
    std::atomic<bool> stopObserved_{false};
    llama_model *model_ = nullptr;
    llama_context *context_ = nullptr;
    bool backendInitialized_ = false;
};

} // namespace hish::ai

#endif // HISH_LOCAL_INFERENCE_RUNTIME_HPP
