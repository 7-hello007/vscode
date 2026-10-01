import { IDEAIProviderRegistry } from './IDEAIProviderRegistry'
import { IDEAIRequest, IDEAIResponse } from '../model/IDEAIContracts'

export class IDEAIServiceError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'IDEAIServiceError'
  }
}

/** Provider-neutral orchestration boundary used by the Workbench. */
export default class IDEAIService {
  private registry: IDEAIProviderRegistry

  constructor(registry: IDEAIProviderRegistry) {
    this.registry = registry
  }

  async send(providerId: string, request: IDEAIRequest): Promise<IDEAIResponse> {
    const provider = this.registry.find(providerId)
    if (!provider) {
      throw new IDEAIServiceError('AI provider is not registered')
    }
    if (!provider.getInfo().available) {
      throw new IDEAIServiceError('AI provider is not available')
    }
    return provider.generate(request)
  }
}
