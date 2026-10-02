#include "include/local_inference_runtime.hpp"

#include "ggml-cpu.h"
#include "llama.h"
#include "hilog/log.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <limits>
#include <memory>
#include <thread>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3304
#define LOG_TAG "HiSH_LocalAI"

namespace {

using SteadyClock = std::chrono::steady_clock;

constexpr uint32_t LOCAL_CONTEXT_SIZE = 2048;
constexpr uint32_t LOCAL_BATCH_SIZE = 512;
constexpr uint32_t LOCAL_UBATCH_SIZE = 128;
constexpr int32_t LOCAL_MAX_TOKENS = 128;
constexpr int32_t LOCAL_MAX_THREADS = 4;

int64_t elapsedMilliseconds(const SteadyClock::time_point &start)
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        SteadyClock::now() - start).count();
}

int64_t elapsedMicroseconds(const SteadyClock::time_point &start)
{
    return std::chrono::duration_cast<std::chrono::microseconds>(
        SteadyClock::now() - start).count();
}

size_t utf8CharacterCount(const std::string &value)
{
    size_t count = 0;
    for (const unsigned char byte : value) {
        if ((byte & 0xC0U) != 0x80U) {
            count++;
        }
    }
    return count;
}

int32_t localThreadCount()
{
    const unsigned int detected = std::thread::hardware_concurrency();
    if (detected == 0) {
        return LOCAL_MAX_THREADS;
    }
    return static_cast<int32_t>(std::min<unsigned int>(detected, LOCAL_MAX_THREADS));
}

bool formatPrompt(
    llama_model *model, const std::string &userPrompt,
    std::string &formatted, std::string &errorCode, std::string &error)
{
    const llama_chat_message message = {"user", userPrompt.c_str()};
    const char *chatTemplate = llama_model_chat_template(model, nullptr);
    const int32_t required = llama_chat_apply_template(
        chatTemplate, &message, 1, true, nullptr, 0);
    if (required <= 0) {
        errorCode = "CHAT_TEMPLATE_FAILED";
        error = "Unable to apply the model chat template";
        return false;
    }

    std::vector<char> buffer(static_cast<size_t>(required));
    const int32_t written = llama_chat_apply_template(
        chatTemplate, &message, 1, true, buffer.data(), required);
    if (written < 0 || written > required) {
        errorCode = "CHAT_TEMPLATE_FAILED";
        error = "Unable to format the local model prompt";
        return false;
    }
    formatted.assign(buffer.data(), static_cast<size_t>(written));
    return true;
}

bool tokenizePrompt(
    const llama_vocab *vocab, const std::string &prompt,
    std::vector<llama_token> &tokens, std::string &errorCode, std::string &error)
{
    if (prompt.size() > static_cast<size_t>(std::numeric_limits<int32_t>::max())) {
        errorCode = "PROMPT_TOO_LARGE";
        error = "Prompt exceeds the supported input size";
        return false;
    }

    const int32_t required = llama_tokenize(
        vocab, prompt.data(), static_cast<int32_t>(prompt.size()),
        nullptr, 0, true, true);
    if (required == std::numeric_limits<int32_t>::min()) {
        errorCode = "TOKENIZE_FAILED";
        error = "Prompt token count overflow";
        return false;
    }

    const int32_t tokenCount = required < 0 ? -required : required;
    if (tokenCount <= 0) {
        errorCode = "TOKENIZE_FAILED";
        error = "Prompt produced no tokens";
        return false;
    }

    tokens.resize(static_cast<size_t>(tokenCount));
    const int32_t actual = llama_tokenize(
        vocab, prompt.data(), static_cast<int32_t>(prompt.size()),
        tokens.data(), tokenCount, true, true);
    if (actual < 0) {
        errorCode = "TOKENIZE_FAILED";
        error = "llama.cpp could not tokenize the prompt";
        return false;
    }
    tokens.resize(static_cast<size_t>(actual));
    return true;
}

bool appendTokenPiece(
    const llama_vocab *vocab, llama_token token, std::string &output,
    std::string &errorCode, std::string &error)
{
    char stackBuffer[256];
    int32_t length = llama_token_to_piece(
        vocab, token, stackBuffer, sizeof(stackBuffer), 0, false);
    if (length >= 0) {
        output.append(stackBuffer, static_cast<size_t>(length));
        return true;
    }

    const int32_t required = -length;
    if (required <= 0) {
        errorCode = "DETOKENIZE_FAILED";
        error = "Generated token could not be converted to text";
        return false;
    }
    std::vector<char> dynamicBuffer(static_cast<size_t>(required));
    length = llama_token_to_piece(
        vocab, token, dynamicBuffer.data(), required, 0, false);
    if (length < 0) {
        errorCode = "DETOKENIZE_FAILED";
        error = "Generated token could not be converted to text";
        return false;
    }
    output.append(dynamicBuffer.data(), static_cast<size_t>(length));
    return true;
}

} // namespace

namespace hish::ai {

LocalInferenceRuntime &LocalInferenceRuntime::instance()
{
    static LocalInferenceRuntime runtime;
    return runtime;
}

LocalInferenceRuntime::~LocalInferenceRuntime()
{
    unload();
}

bool LocalInferenceRuntime::abortGeneration(void *data)
{
    auto *runtime = static_cast<LocalInferenceRuntime *>(data);
    if (runtime == nullptr || !runtime->stopRequested_.load()) {
        return false;
    }
    if (!runtime->stopObserved_.exchange(true)) {
        OH_LOG_INFO(LOG_APP, "stop observed by llama abort_callback");
    }
    return true;
}

bool LocalInferenceRuntime::loadModel(
    const std::string &path, std::string &errorCode, std::string &error)
{
    std::lock_guard<std::mutex> guard(mutex_);
    unloadLocked();
    const SteadyClock::time_point loadStart = SteadyClock::now();
    OH_LOG_INFO(LOG_APP, "loadModel start path=%{public}s", path.c_str());

    if (path.empty() || !std::ifstream(path, std::ios::binary).good()) {
        errorCode = "MODEL_NOT_FOUND";
        error = "Model file was not found at the requested path";
        return false;
    }

    if (!backendInitialized_) {
        llama_backend_init();
        backendInitialized_ = true;
        OH_LOG_INFO(
            LOG_APP,
            "CPU backend features neon=%{public}d arm_fma=%{public}d fp16_va=%{public}d "
            "dotprod=%{public}d i8mm=%{public}d sve=%{public}d system=%{public}s",
            ggml_cpu_has_neon(), ggml_cpu_has_arm_fma(), ggml_cpu_has_fp16_va(),
            ggml_cpu_has_dotprod(), ggml_cpu_has_matmul_int8(), ggml_cpu_has_sve(),
            llama_print_system_info());
    }

    llama_model_params params = llama_model_default_params();
    params.n_gpu_layers = 0;
    model_ = llama_model_load_from_file(path.c_str(), params);
    if (model_ == nullptr) {
        errorCode = "MODEL_LOAD_FAILED";
        error = "llama.cpp could not load the GGUF model";
        unloadLocked();
        return false;
    }
    OH_LOG_INFO(
        LOG_APP, "loadModel model loaded elapsed_ms=%{public}lld",
        static_cast<long long>(elapsedMilliseconds(loadStart)));

    llama_context_params contextParams = llama_context_default_params();
    contextParams.n_ctx = LOCAL_CONTEXT_SIZE;
    contextParams.n_batch = LOCAL_BATCH_SIZE;
    contextParams.n_ubatch = LOCAL_UBATCH_SIZE;
    contextParams.n_seq_max = 1;
    contextParams.n_threads = localThreadCount();
    contextParams.n_threads_batch = localThreadCount();
    contextParams.offload_kqv = false;
    contextParams.op_offload = false;
    contextParams.no_perf = true;
    contextParams.abort_callback = LocalInferenceRuntime::abortGeneration;
    contextParams.abort_callback_data = this;

    context_ = llama_init_from_model(model_, contextParams);
    if (context_ == nullptr) {
        errorCode = "MODEL_LOAD_FAILED";
        error = "The model loaded, but its CPU inference context could not be created";
        unloadLocked();
        return false;
    }

    stopRequested_.store(false);
    stopObserved_.store(false);
    OH_LOG_INFO(
        LOG_APP,
        "loadModel context created n_ctx=%{public}u n_batch=%{public}u n_ubatch=%{public}u "
        "n_threads=%{public}d n_threads_batch=%{public}d n_gpu_layers=%{public}d "
        "total_ms=%{public}lld",
        llama_n_ctx(context_), LOCAL_BATCH_SIZE, LOCAL_UBATCH_SIZE,
        llama_n_threads(context_), llama_n_threads_batch(context_), params.n_gpu_layers,
        static_cast<long long>(elapsedMilliseconds(loadStart)));
    return true;
}

bool LocalInferenceRuntime::generate(
    const std::string &prompt, std::string &output,
    std::string &errorCode, std::string &error)
{
    std::lock_guard<std::mutex> guard(mutex_);
    output.clear();
    const SteadyClock::time_point generateStart = SteadyClock::now();
    OH_LOG_INFO(
        LOG_APP, "generate start input_chars=%{public}zu input_bytes=%{public}zu",
        utf8CharacterCount(prompt), prompt.size());

    if (model_ == nullptr || context_ == nullptr) {
        errorCode = "MODEL_NOT_LOADED";
        error = "No local model is loaded";
        return false;
    }
    if (prompt.empty()) {
        errorCode = "INVALID_PROMPT";
        error = "Prompt must not be empty";
        return false;
    }
    if (stopRequested_.exchange(false)) {
        stopObserved_.store(false);
        errorCode = "GENERATION_STOPPED";
        error = "Generation was stopped";
        return false;
    }
    stopObserved_.store(false);

    llama_memory_clear(llama_get_memory(context_), true);

    std::string formattedPrompt;
    const SteadyClock::time_point templateStart = SteadyClock::now();
    if (!formatPrompt(model_, prompt, formattedPrompt, errorCode, error)) {
        return false;
    }
    OH_LOG_INFO(
        LOG_APP,
        "chat template complete final_prompt_chars=%{public}zu final_prompt_bytes=%{public}zu "
        "template_ms=%{public}lld",
        utf8CharacterCount(formattedPrompt), formattedPrompt.size(),
        static_cast<long long>(elapsedMilliseconds(templateStart)));

    const llama_vocab *vocab = llama_model_get_vocab(model_);
    if (vocab == nullptr) {
        errorCode = "MODEL_LOAD_FAILED";
        error = "The loaded model does not expose a vocabulary";
        return false;
    }

    std::vector<llama_token> promptTokens;
    const SteadyClock::time_point tokenizeStart = SteadyClock::now();
    if (!tokenizePrompt(vocab, formattedPrompt, promptTokens, errorCode, error)) {
        return false;
    }
    OH_LOG_INFO(
        LOG_APP, "tokenize complete prompt_tokens=%{public}zu tokenize_ms=%{public}lld",
        promptTokens.size(), static_cast<long long>(elapsedMilliseconds(tokenizeStart)));

    const uint32_t contextSize = llama_n_ctx(context_);
    if (promptTokens.size() + LOCAL_MAX_TOKENS > contextSize) {
        errorCode = "CONTEXT_LIMIT_EXCEEDED";
        error = "Prompt is too long for the 2048-token local context";
        return false;
    }

    size_t offset = 0;
    const SteadyClock::time_point promptDecodeStart = SteadyClock::now();
    OH_LOG_INFO(
        LOG_APP,
        "prompt decode start prompt_tokens=%{public}zu n_ctx=%{public}u n_batch=%{public}u "
        "n_ubatch=%{public}u n_threads=%{public}d n_threads_batch=%{public}d n_gpu_layers=0",
        promptTokens.size(), contextSize, LOCAL_BATCH_SIZE, LOCAL_UBATCH_SIZE,
        llama_n_threads(context_), llama_n_threads_batch(context_));
    while (offset < promptTokens.size()) {
        if (stopRequested_.load()) {
            OH_LOG_INFO(LOG_APP, "stop observed by prompt loop before llama_decode");
            stopRequested_.store(false);
            errorCode = "GENERATION_STOPPED";
            error = "Generation was stopped";
            return false;
        }
        const size_t remaining = promptTokens.size() - offset;
        const int32_t count = static_cast<int32_t>(
            std::min<size_t>(remaining, LOCAL_BATCH_SIZE));
        llama_batch batch = llama_batch_get_one(promptTokens.data() + offset, count);
        const int32_t decodeResult = llama_decode(context_, batch);
        if (decodeResult != 0) {
            if (decodeResult == 2 || stopRequested_.load()) {
                stopRequested_.store(false);
                errorCode = "GENERATION_STOPPED";
                error = "Generation was stopped";
            } else {
                errorCode = "DECODE_FAILED";
                error = "llama.cpp failed while decoding the prompt";
            }
            return false;
        }
        offset += static_cast<size_t>(count);
    }
    OH_LOG_INFO(
        LOG_APP, "prompt decode finish prompt_decode_ms=%{public}lld",
        static_cast<long long>(elapsedMilliseconds(promptDecodeStart)));

    llama_sampler_chain_params samplerParams = llama_sampler_chain_default_params();
    samplerParams.no_perf = true;
    std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(
        llama_sampler_chain_init(samplerParams), llama_sampler_free);
    if (!sampler) {
        errorCode = "SAMPLER_INIT_FAILED";
        error = "Unable to create the local sampling chain";
        return false;
    }
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_k(40));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    const SteadyClock::time_point generationLoopStart = SteadyClock::now();
    int32_t generatedCount = 0;
    int64_t samplingUs = 0;
    int64_t tokenToPieceUs = 0;
    int64_t generationDecodeUs = 0;
    OH_LOG_INFO(
        LOG_APP,
        "generation loop start max_tokens=%{public}d top_k=40 top_p=0.9 temperature=0.7",
        LOCAL_MAX_TOKENS);
    for (int32_t generated = 0; generated < LOCAL_MAX_TOKENS; generated++) {
        if (stopRequested_.load()) {
            OH_LOG_INFO(LOG_APP, "stop observed by generation loop before sampling");
            stopRequested_.store(false);
            errorCode = "GENERATION_STOPPED";
            error = "Generation was stopped";
            return false;
        }

        const SteadyClock::time_point sampleStart = SteadyClock::now();
        llama_token token = llama_sampler_sample(sampler.get(), context_, -1);
        samplingUs += elapsedMicroseconds(sampleStart);
        if (generatedCount == 0) {
            OH_LOG_INFO(
                LOG_APP, "first token sampled token_id=%{public}d latency_ms=%{public}lld",
                token, static_cast<long long>(elapsedMilliseconds(generateStart)));
        }
        if (llama_vocab_is_eog(vocab, token)) {
            OH_LOG_INFO(LOG_APP, "generation reached EOG after_tokens=%{public}d", generatedCount);
            break;
        }
        const SteadyClock::time_point pieceStart = SteadyClock::now();
        if (!appendTokenPiece(vocab, token, output, errorCode, error)) {
            return false;
        }
        tokenToPieceUs += elapsedMicroseconds(pieceStart);
        if (generatedCount == 0) {
            OH_LOG_INFO(
                LOG_APP, "first token produced latency_ms=%{public}lld",
                static_cast<long long>(elapsedMilliseconds(generateStart)));
        }

        llama_batch batch = llama_batch_get_one(&token, 1);
        const SteadyClock::time_point tokenDecodeStart = SteadyClock::now();
        const int32_t decodeResult = llama_decode(context_, batch);
        generationDecodeUs += elapsedMicroseconds(tokenDecodeStart);
        if (decodeResult != 0) {
            if (decodeResult == 2 || stopRequested_.load()) {
                stopRequested_.store(false);
                errorCode = "GENERATION_STOPPED";
                error = "Generation was stopped";
            } else {
                errorCode = "DECODE_FAILED";
                error = "llama.cpp failed while decoding a generated token";
            }
            return false;
        }
        generatedCount++;
        if (generatedCount % 10 == 0) {
            OH_LOG_INFO(
                LOG_APP, "generation progress tokens=%{public}d elapsed_ms=%{public}lld",
                generatedCount, static_cast<long long>(elapsedMilliseconds(generationLoopStart)));
        }
    }

    stopRequested_.store(false);
    const int64_t totalGenerationMs = elapsedMilliseconds(generateStart);
    const int64_t loopMs = elapsedMilliseconds(generationLoopStart);
    const double tokensPerSecond = loopMs > 0
        ? static_cast<double>(generatedCount) * 1000.0 / static_cast<double>(loopMs)
        : 0.0;
    OH_LOG_INFO(
        LOG_APP,
        "generate complete generated_tokens=%{public}d total_ms=%{public}lld generation_loop_ms=%{public}lld "
        "tokens_per_second=%{public}f sampling_us=%{public}lld token_to_piece_us=%{public}lld "
        "token_decode_us=%{public}lld",
        generatedCount, static_cast<long long>(totalGenerationMs), static_cast<long long>(loopMs),
        tokensPerSecond, static_cast<long long>(samplingUs), static_cast<long long>(tokenToPieceUs),
        static_cast<long long>(generationDecodeUs));
    return true;
}

void LocalInferenceRuntime::stop()
{
    OH_LOG_INFO(LOG_APP, "stop request received");
    stopObserved_.store(false);
    stopRequested_.store(true);
}

void LocalInferenceRuntime::unload()
{
    std::lock_guard<std::mutex> guard(mutex_);
    unloadLocked();
}

void LocalInferenceRuntime::unloadLocked()
{
    stopRequested_.store(true);
    stopObserved_.store(false);
    if (context_ != nullptr) {
        llama_free(context_);
        context_ = nullptr;
    }
    if (model_ != nullptr) {
        llama_model_free(model_);
        model_ = nullptr;
    }
    if (backendInitialized_) {
        llama_backend_free();
        backendInitialized_ = false;
    }
}

} // namespace hish::ai
