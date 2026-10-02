import nativeRuntime from 'libentry.so'
import { resourceManager } from '@kit.LocalizationKit'

/** ArkTS boundary for the local llama.cpp lifecycle. */
export default class LocalInferenceRuntime {
  prepareBundledModel(manager: resourceManager.ResourceManager, filesDir: string): Promise<string> {
    return nativeRuntime.prepareBundledModel(manager, filesDir)
  }

  /** Expected path: `${applicationContext.filesDir}/models/qwen2.5-0.5b-instruct-q4_k_m.gguf`. */
  loadModel(path: string): Promise<boolean> {
    return nativeRuntime.loadModel(path)
  }

  generate(prompt: string): Promise<string> {
    return nativeRuntime.generate(prompt)
  }

  stop(): void {
    nativeRuntime.stop()
  }

  unload(): void {
    nativeRuntime.unload()
  }
}
