import { IDEAIProvider, IDEAIProviderInfo } from '../model/IDEAIContracts'

/** Shared registry permits cloud and local providers to coexist. */
export class IDEAIProviderRegistry {
  private providers: IDEAIProvider[] = []

  register(provider: IDEAIProvider): boolean {
    const info = provider.getInfo()
    if (!info.id || this.find(info.id)) {
      return false
    }
    this.providers.push(provider)
    return true
  }

  unregister(id: string): boolean {
    for (let index = 0; index < this.providers.length; index++) {
      if (this.providers[index].getInfo().id === id) {
        this.providers.splice(index, 1)
        return true
      }
    }
    return false
  }

  find(id: string): IDEAIProvider | null {
    for (const provider of this.providers) {
      if (provider.getInfo().id === id) {
        return provider
      }
    }
    return null
  }

  list(): IDEAIProviderInfo[] {
    const result: IDEAIProviderInfo[] = []
    for (const provider of this.providers) {
      const info = provider.getInfo()
      result.push(new IDEAIProviderInfo(info.id, info.name, info.kind, info.available))
    }
    return result
  }
}

export const ideAIProviderRegistry: IDEAIProviderRegistry = new IDEAIProviderRegistry()
