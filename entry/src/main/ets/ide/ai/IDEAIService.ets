import { IDEAIProviderRegistry } from './IDEAIProviderRegistry'
import { IDEAIConversationTurn, IDEAIRequest, IDEAIResponse } from '../model/IDEAIContracts'

export class IDEAIServiceError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'IDEAIServiceError'
  }
}

/** Provider-neutral orchestration boundary used by the Workbench. */
export default class IDEAIService {
  private registry: IDEAIProviderRegistry
  private conversationHistory: IDEAIConversationTurn[] = []

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
    const historySnapshot: IDEAIConversationTurn[] = []
    for (const turn of this.conversationHistory) {
      historySnapshot.push(new IDEAIConversationTurn(turn.user, turn.assistant))
    }
    const response = await provider.generate(
      new IDEAIRequest(request.prompt, request.context, historySnapshot))
    this.conversationHistory.push(new IDEAIConversationTurn(request.prompt, response.content))
    return response
  }

  clearConversation(): void {
    this.conversationHistory = []
  }
}
