# Local AI native dependency

`llama.cpp` is integrated as a Git submodule at:

- upstream: `https://github.com/ggml-org/llama.cpp.git`
- release: `v0.4.1`
- source commit: `b29c606e28a01b1bc8c1351026a0fa6e616bf6c4`
- license: MIT (`llama.cpp/LICENSE`, copyright 2023-2026 The ggml authors)

HiSH builds only the position-independent CPU backend. Tests, examples, tools,
server, app/UI, CUDA, HIP, Vulkan, Metal, OpenCL, SYCL, RPC, BLAS, OpenMP and
runtime-loaded backends are disabled in the parent CMake project. GGUF model
files and generated native artifacts are intentionally not source-controlled.

The parent project also disables `llama` Unity Build and precompiled headers.
This is a build-only HarmonyOS portability adjustment: DevEco's dual-ABI Ninja
pipeline otherwise references an ungenerated PCH from the Unity object rules.

HarmonyOS clang defines `__linux__`, but its musl NDK does not expose the
glibc-specific CPU-affinity API used by ggml's Linux branch. For
`ggml-cpu.c` only, the parent CMake undefines that macro so upstream's existing
portable no-affinity branch is selected. The CPU thread pool and ARM64 kernels
remain enabled.

Phase B uses a 2048-token, CPU-only context with a 512-token prompt batch,
up to four CPU threads and a 128-token response cap. Sampling is top-k 40,
top-p 0.9, temperature 0.7 and a distribution sampler. Model chat-template
metadata formats each standalone user prompt; no conversation state is kept.

## Bundled model manifest

- repository: `Qwen/Qwen2.5-0.5B-Instruct-GGUF`
- repository revision at selection: `9217f5db79a29953eb74d5343926648285ec7e67`
- file: `qwen2.5-0.5b-instruct-q4_k_m.gguf`
- exact size: `491400032` bytes
- SHA-256: `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db`
- license: Apache License 2.0

The GGUF is an ignored deployment input. It is packaged under
`resources/rawfile/models/` for local builds but is never committed to Git.
