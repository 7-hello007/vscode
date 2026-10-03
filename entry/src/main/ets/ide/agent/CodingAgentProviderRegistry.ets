import { CodingAgentProvider, CodingAgentProviderInfo } from './CodingAgentContracts'
import { codexAgentProvider } from './CodexAgentProvider'

/** Provider-neutral registry kept separate from Local AI and Web AI registries. */
export default class CodingAgentProviderRegistry {
  private providers: Map<string, CodingAgentProvider> = new Map<string, CodingAgentProvider>()

  register(provider: CodingAgentProvider): void {
    this.providers.set(provider.getInfo().id, provider)
  }

  find(id: string): CodingAgentProvider | undefined {
    return this.providers.get(id)
  }

  list(): CodingAgentProviderInfo[] {
    const result: CodingAgentProviderInfo[] = []
    this.providers.forEach((provider: CodingAgentProvider): void => {
      result.push(provider.getInfo())
    })
    return result
  }
}

export const codingAgentProviderRegistry: CodingAgentProviderRegistry = new CodingAgentProviderRegistry()
codingAgentProviderRegistry.register(codexAgentProvider)

