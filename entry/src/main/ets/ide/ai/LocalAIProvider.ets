import { common } from '@kit.AbilityKit'
import LocalInferenceRuntime from './LocalInferenceRuntime'
import {
  IDEAIConversationTurn,
  IDEAIContext,
  IDEAIProvider,
  IDEAIProviderInfo,
  IDEAIProviderKind,
  IDEAIRequest,
  IDEAIResponse
} from '../model/IDEAIContracts'

export const HISH_LOCAL_PROVIDER_ID: string = 'local-qwen2.5-0.5b-q4-k-m'

const LOCAL_CONTEXT_TOKEN_LIMIT: number = 2048
const LOCAL_GENERATION_TOKEN_RESERVE: number = 128
const LOCAL_CHAT_TEMPLATE_TOKEN_RESERVE: number = 128
const LOCAL_PROMPT_TOKEN_BUDGET: number = LOCAL_CONTEXT_TOKEN_LIMIT -
  LOCAL_GENERATION_TOKEN_RESERVE - LOCAL_CHAT_TEMPLATE_TOKEN_RESERVE

const LOCAL_SYSTEM_INSTRUCTION: string =
  'You are the offline HiSH coding assistant. Answer with text only. ' +
  'The current editor context is read-only and may include unsaved code. ' +
  'You may explain code, generate code text, and suggest changes, but you cannot modify files, ' +
  'save files, run terminal commands, call tools, or claim that you performed actions.'

/**
 * Read-only local text provider. It receives an immutable IDE context snapshot
 * and exposes no file, terminal, QGA, tool-calling, or agent capability.
 */
export class LocalAIProvider implements IDEAIProvider {
  private runtime: LocalInferenceRuntime = new LocalInferenceRuntime()
  private available: boolean = false
  private initialization: Promise<void> | null = null
  private lastError: string = ''
  private preparedModelPath: string = ''

  getInfo(): IDEAIProviderInfo {
    return new IDEAIProviderInfo(
      HISH_LOCAL_PROVIDER_ID,
      'Qwen2.5 0.5B',
      IDEAIProviderKind.LOCAL,
      this.available)
  }

  getLastError(): string {
    return this.lastError
  }

  async initialize(context: common.UIAbilityContext): Promise<void> {
    if (this.available) {
      return
    }
    if (this.initialization !== null) {
      return this.initialization
    }
    this.initialization = this.prepareAndLoad(context)
    try {
      await this.initialization
    } finally {
      this.initialization = null
    }
  }

  private async prepareAndLoad(context: common.UIAbilityContext): Promise<void> {
    this.available = false
    this.lastError = ''
    try {
      const appContext = context.getApplicationContext()
      this.preparedModelPath = await this.runtime.prepareBundledModel(
        context.resourceManager, appContext.filesDir)
      await this.runtime.loadModel(this.preparedModelPath)
      this.available = true
    } catch (error) {
      this.available = false
      this.lastError = (error as Error).message || 'Local model initialization failed'
      throw new Error(this.lastError)
    }
  }

  async generate(request: IDEAIRequest): Promise<IDEAIResponse> {
    if (!this.available) {
      throw new Error(this.lastError || 'Local model is not ready')
    }
    const answer = await this.runtime.generate(this.buildPrompt(request))
    return new IDEAIResponse(answer)
  }

  stop(): void {
    this.runtime.stop()
  }

  unload(): void {
    this.runtime.unload()
    this.available = false
  }

  private buildPrompt(request: IDEAIRequest): string {
    const context = request.context
    const question = request.prompt.trim()
    const systemSection = 'System instruction:\n' + LOCAL_SYSTEM_INSTRUCTION + '\n\n'
    const questionSection = 'Current user message:\n' + question
    const mandatoryCost = this.estimateTokenUpperBound(systemSection + questionSection)
    if (mandatoryCost > LOCAL_PROMPT_TOKEN_BUDGET) {
      throw new Error('CONTEXT_LIMIT_EXCEEDED: Current user message exceeds the local context budget')
    }

    let remaining = LOCAL_PROMPT_TOKEN_BUDGET - mandatoryCost
    const editorSection = this.buildEditorSection(context, remaining)
    remaining = Math.max(0, remaining - this.estimateTokenUpperBound(editorSection))

    const retainedTurns: string[] = []
    for (let index = request.history.length - 1; index >= 0; index--) {
      const turnText = this.formatConversationTurn(request.history[index])
      const turnCost = this.estimateTokenUpperBound(turnText)
      if (turnCost <= remaining) {
        retainedTurns.unshift(turnText)
        remaining -= turnCost
      }
    }

    let historySection = ''
    if (retainedTurns.length > 0) {
      historySection = 'Recent conversation history:\n' + retainedTurns.join('') + '\n'
    }
    return systemSection + editorSection + historySection + questionSection
  }

  private buildEditorSection(context: IDEAIContext, tokenBudget: number): string {
    if (!context.activeFilePath) {
      const noActiveFile = 'Current editor context:\nNo active editor file.\n\n'
      if (this.estimateTokenUpperBound(noActiveFile) > tokenBudget) {
        throw new Error('CONTEXT_LIMIT_EXCEEDED: No room remains for the required editor context')
      }
      return noActiveFile
    }

    const language = context.language || 'plaintext'
    const header = 'Current editor context (read-only):\nPath: ' + context.activeFilePath +
      '\nLanguage: ' + language + '\nCurrent editor buffer:\n```' + language + '\n'
    const footer = '\n```\n\n'
    const marker = '\n[Current file truncated]\n'
    if (this.estimateTokenUpperBound(header + marker + footer) > tokenBudget) {
      throw new Error('CONTEXT_LIMIT_EXCEEDED: No room remains for the required editor context')
    }
    const fullSection = header + context.activeFileContent + footer
    if (this.estimateTokenUpperBound(fullSection) <= tokenBudget) {
      return fullSection
    }

    const contentBudget = Math.max(0, tokenBudget -
      this.estimateTokenUpperBound(header + marker + footer))
    const truncatedContent = this.fitToTokenBudget(context.activeFileContent, contentBudget)
    return header + truncatedContent + marker + footer
  }

  private formatConversationTurn(turn: IDEAIConversationTurn): string {
    return 'User:\n' + turn.user + '\nAssistant:\n' + turn.assistant + '\n'
  }

  /** UTF-8 byte count is a conservative upper bound for tokenizer byte fallback. */
  private estimateTokenUpperBound(value: string): number {
    let bytes = 0
    for (let index = 0; index < value.length; index++) {
      const code = value.charCodeAt(index)
      if (code <= 0x7F) {
        bytes++
      } else if (code <= 0x7FF) {
        bytes += 2
      } else if (code >= 0xD800 && code <= 0xDBFF && index + 1 < value.length) {
        const next = value.charCodeAt(index + 1)
        if (next >= 0xDC00 && next <= 0xDFFF) {
          bytes += 4
          index++
        } else {
          bytes += 3
        }
      } else {
        bytes += 3
      }
    }
    return bytes
  }

  private fitToTokenBudget(value: string, tokenBudget: number): string {
    if (tokenBudget <= 0 || !value) return ''
    if (this.estimateTokenUpperBound(value) <= tokenBudget) return value
    let low = 0
    let high = value.length
    while (low < high) {
      const middle = Math.ceil((low + high) / 2)
      if (this.estimateTokenUpperBound(value.substring(0, middle)) <= tokenBudget) {
        low = middle
      } else {
        high = middle - 1
      }
    }
    return value.substring(0, low)
  }
}

export const localAIProvider: LocalAIProvider = new LocalAIProvider()
