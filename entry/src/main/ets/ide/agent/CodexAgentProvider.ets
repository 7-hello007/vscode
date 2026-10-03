import {
  CodingAgentApprovalRequest,
  CodingAgentListener,
  CodingAgentMessage,
  CodingAgentMessageRole,
  CodingAgentProvider,
  CodingAgentProviderInfo,
  CodingAgentSnapshot,
  CodingAgentStartResult,
  CodingAgentState,
  CodingAgentTask,
  CodingAgentToolActivity,
  CodingAgentToolActivityStatus,
  CodingAgentToolCall,
  CodingAgentToolName
} from './CodingAgentContracts'
import { common } from '@kit.AbilityKit'
import TrustedBackendTransport, {
  CodexAgentConnectionConfig,
  CodexAgentEvent,
  CodexAgentSessionSnapshot,
  ICodexAgentTransport
} from './CodexAgentTransport'
import CodexAppServerTransport from './CodexAppServerTransport'
import { chatGPTOAuthService, ChatGPTAuthState } from './ChatGPTOAuthService'
import HiSHAgentToolBridge from './HiSHAgentToolBridge'

export const CODEX_AGENT_PROVIDER_ID = 'hish.agent.codex'

class CodingAgentSubscription {
  id: string
  listener: CodingAgentListener

  constructor(id: string, listener: CodingAgentListener) {
    this.id = id
    this.listener = listener
  }
}

/** Durable Codex session controller; UI/provider switching does not recreate it. */
export default class CodexAgentProvider implements CodingAgentProvider {
  private transport: ICodexAgentTransport | null = null
  private trustedBackend: TrustedBackendTransport = new TrustedBackendTransport()
  private appServerTransport: CodexAppServerTransport | null = null
  private initialized: boolean = false
  private toolBridge: HiSHAgentToolBridge | null = null
  private state: CodingAgentState = CodingAgentState.IDLE
  private sessionId: string = ''
  private cursor: string = ''
  private messages: CodingAgentMessage[] = []
  private activities: CodingAgentToolActivity[] = []
  private pendingApproval: CodingAgentApprovalRequest | null = null
  private pendingToolCall: CodingAgentToolCall | null = null
  private handledCallIds: string[] = []
  private subscriptions: CodingAgentSubscription[] = []
  private error: string = ''
  private messageSequence: number = 0
  private activitySequence: number = 0
  private loopRevision: number = 0
  private loopRunning: boolean = false
  private assistantMessageId: string = ''

  async initialize(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return
    await chatGPTOAuthService.initialize(context)
    this.appServerTransport = new CodexAppServerTransport(context, chatGPTOAuthService)
    this.transport = this.appServerTransport
    this.initialized = true
    chatGPTOAuthService.subscribe((state: ChatGPTAuthState, message: string): void => {
      if (state === ChatGPTAuthState.ERROR && message) this.error = message
      this.notify()
    })
    this.notify()
  }

  async signInWithChatGPT(): Promise<void> {
    if (!this.initialized || !this.appServerTransport) throw new Error('CODEX_PROVIDER_NOT_INITIALIZED')
    this.error = ''
    this.notify()
    try {
      await chatGPTOAuthService.signIn()
      this.transport = this.appServerTransport
      this.state = CodingAgentState.IDLE
      this.notify()
    } catch (error) {
      this.state = CodingAgentState.FAILED
      this.error = this.errorMessage(error, 'OAUTH_SIGN_IN_FAILED')
      this.notify()
    }
  }

  async logoutChatGPT(): Promise<void> {
    this.loopRevision++
    if (this.appServerTransport) await this.appServerTransport.shutdown()
    await chatGPTOAuthService.logout()
    this.sessionId = ''
    this.cursor = ''
    this.state = CodingAgentState.IDLE
    this.error = ''
    this.clearPendingApproval()
    this.notify()
  }

  configure(config: CodexAgentConnectionConfig): void {
    this.trustedBackend.configure(config)
    this.transport = this.trustedBackend
    this.error = ''
    this.notify()
  }

  attachToolBridge(toolBridge: HiSHAgentToolBridge): void {
    this.toolBridge = toolBridge
    this.notify()
  }

  clearCredentials(): void {
    this.trustedBackend.clearCredentials()
    this.transport = this.appServerTransport
    this.loopRevision++
    this.state = CodingAgentState.IDLE
    this.error = 'NOT_CONFIGURED'
    this.notify()
  }

  getInfo(): CodingAgentProviderInfo {
    if (this.transport && this.transport.isConfigured()) {
      return new CodingAgentProviderInfo(CODEX_AGENT_PROVIDER_ID, 'Codex', true)
    }
    return new CodingAgentProviderInfo(CODEX_AGENT_PROVIDER_ID, 'Codex', false,
      'NOT_CONFIGURED：请使用 ChatGPT 账号登录。')
  }

  getState(): CodingAgentState {
    return this.state
  }

  getSnapshot(): CodingAgentSnapshot {
    return new CodingAgentSnapshot(this.state, this.sessionId, this.messages.slice(),
      this.activities.slice(), this.pendingApproval, this.error,
      this.transport !== null && this.transport.isConfigured(), chatGPTOAuthService.getState())
  }

  subscribe(id: string, listener: CodingAgentListener): void {
    this.unsubscribe(id)
    this.subscriptions.push(new CodingAgentSubscription(id, listener))
    listener(this.getSnapshot())
  }

  unsubscribe(id: string): void {
    const remaining: CodingAgentSubscription[] = []
    for (const subscription of this.subscriptions) {
      if (subscription.id !== id) remaining.push(subscription)
    }
    this.subscriptions = remaining
  }

  async start(task: CodingAgentTask): Promise<CodingAgentStartResult> {
    if (!this.transport || !this.transport.isConfigured()) {
      this.state = CodingAgentState.FAILED
      this.error = 'NOT_CONFIGURED'
      this.notify()
      return new CodingAgentStartResult('', this.state, this.error)
    }
    if (!this.toolBridge) {
      this.state = CodingAgentState.FAILED
      this.error = 'CODEX_TOOL_BRIDGE_NOT_READY'
      this.notify()
      return new CodingAgentStartResult('', this.state, this.error)
    }
    if (this.pendingApproval || this.state === CodingAgentState.THINKING ||
      this.state === CodingAgentState.READING || this.state === CodingAgentState.RUNNING_COMMAND) {
      return new CodingAgentStartResult(this.sessionId, this.state, 'CODEX_AGENT_BUSY')
    }

    const userPrompt = task.prompt.trim()
    if (!userPrompt) return new CodingAgentStartResult(this.sessionId, this.state, 'EMPTY_PROMPT')
    this.error = ''
    this.state = CodingAgentState.THINKING
    this.appendMessage(CodingAgentMessageRole.USER, userPrompt)
    this.notify()
    try {
      const input = this.buildAuthorizedPrompt(task)
      if (!this.sessionId) {
        const result = await this.requireTransport().createSession(input, task.context.projectRoot)
        this.sessionId = result.id
        this.cursor = result.cursor
      } else {
        await this.requireTransport().sendMessage(this.sessionId, input)
      }
      this.startEventLoop()
      return new CodingAgentStartResult(this.sessionId, this.state, 'in_progress')
    } catch (error) {
      this.state = CodingAgentState.FAILED
      this.error = this.errorMessage(error, 'CODEX_SESSION_FAILED')
      this.appendMessage(CodingAgentMessageRole.SYSTEM, this.error)
      this.notify()
      return new CodingAgentStartResult(this.sessionId, this.state, this.error)
    }
  }

  async approve(requestId: string): Promise<void> {
    if (!this.pendingApproval || !this.pendingToolCall || this.pendingApproval.id !== requestId ||
      !this.toolBridge || !this.sessionId) return
    const approval = this.pendingApproval
    const call = this.pendingToolCall
    this.state = approval.kind === 'COMMAND' ? CodingAgentState.RUNNING_COMMAND : CodingAgentState.EDITING
    this.updateActivity(call.callId, CodingAgentToolActivityStatus.RUNNING, '用户已批准，正在执行')
    this.notify()
    try {
      const output = await this.toolBridge.applyApproved(approval)
      await this.requireTransport().submitToolResult(this.sessionId, call, true, output, '')
      this.handledCallIds.push(call.callId)
      this.updateActivity(call.callId, CodingAgentToolActivityStatus.SUCCEEDED, '已批准并完成')
      this.clearPendingApproval()
      this.state = CodingAgentState.THINKING
      this.notify()
      this.startEventLoop()
    } catch (error) {
      const message = this.errorMessage(error, 'AGENT_APPROVED_TOOL_FAILED')
      await this.submitToolFailure(call, message)
      this.updateActivity(call.callId, CodingAgentToolActivityStatus.FAILED, message)
      this.clearPendingApproval()
      this.state = CodingAgentState.THINKING
      this.notify()
      this.startEventLoop()
    }
  }

  async reject(requestId: string): Promise<void> {
    if (!this.pendingApproval || !this.pendingToolCall || this.pendingApproval.id !== requestId ||
      !this.sessionId) return
    const call = this.pendingToolCall
    await this.requireTransport().submitToolResult(this.sessionId, call, false, '', 'USER_REJECTED')
    this.handledCallIds.push(call.callId)
    this.updateActivity(call.callId, CodingAgentToolActivityStatus.REJECTED, '用户拒绝')
    this.clearPendingApproval()
    this.state = CodingAgentState.THINKING
    this.notify()
    this.startEventLoop()
  }

  stop(): void {
    this.loopRevision++
    this.state = CodingAgentState.STOPPED
    this.clearPendingApproval()
    this.notify()
    if (this.sessionId && this.transport && this.transport.isConfigured()) {
      void this.cancelRemoteSession(this.sessionId)
    }
  }

  private startEventLoop(): void {
    if (this.loopRunning || !this.sessionId || this.pendingApproval) return
    this.loopRunning = true
    const revision = ++this.loopRevision
    void this.consumeEvents(revision)
  }

  private async consumeEvents(revision: number): Promise<void> {
    let failures = 0
    try {
      while (revision === this.loopRevision && this.sessionId && !this.pendingApproval) {
        try {
          const batch = await this.requireTransport().pollEvents(this.sessionId, this.cursor)
          failures = 0
          this.cursor = batch.nextCursor
          for (const event of batch.events) {
            if (revision !== this.loopRevision) return
            await this.handleEvent(event)
            if (this.pendingApproval || this.isTerminalState()) return
          }
        } catch (error) {
          failures++
          if (failures < 3) {
            await this.delay(failures * 1000)
            continue
          }
          const recovered = await this.recoverSession()
          if (!recovered) {
            this.state = CodingAgentState.FAILED
            this.error = this.errorMessage(error, 'CODEX_EVENT_STREAM_DISCONNECTED')
            this.notify()
            return
          }
          failures = 0
          if (this.pendingApproval || this.isTerminalState()) return
        }
      }
    } finally {
      this.loopRunning = false
    }
  }

  private async handleEvent(event: CodexAgentEvent): Promise<void> {
    if (event.cursor) this.cursor = event.cursor
    if (event.type === 'assistant.delta') {
      this.appendAssistantDelta(event.messageId, event.content)
    } else if (event.type === 'assistant.completed') {
      this.completeAssistantMessage(event.messageId, event.content)
    } else if ((event.type === 'tool.call' || event.type === 'session.requires_action') && event.toolCall) {
      await this.handleToolCall(event.toolCall)
    } else if (event.type === 'session.completed' || event.type === 'session.idle') {
      this.state = CodingAgentState.DONE
      this.assistantMessageId = ''
      this.notify()
    } else if (event.type === 'session.failed') {
      this.state = CodingAgentState.FAILED
      this.error = event.error || 'CODEX_SESSION_FAILED'
      this.notify()
    } else if (event.type === 'session.cancelled') {
      this.state = CodingAgentState.STOPPED
      this.notify()
    }
  }

  private async handleToolCall(call: CodingAgentToolCall): Promise<void> {
    if (this.handledCallIds.indexOf(call.callId) !== -1 ||
      (this.pendingToolCall && this.pendingToolCall.callId === call.callId)) return
    const readOnly = call.name === CodingAgentToolName.READ_FILE ||
      call.name === CodingAgentToolName.LIST_DIRECTORY || call.name === CodingAgentToolName.SEARCH_FILES
    this.addActivity(call, readOnly ? CodingAgentToolActivityStatus.RUNNING :
      CodingAgentToolActivityStatus.WAITING_APPROVAL, readOnly ? '正在读取' : '等待用户批准')
    if (!this.toolBridge || !this.sessionId) throw new Error('CODEX_TOOL_BRIDGE_NOT_READY')
    if (readOnly) {
      this.state = CodingAgentState.READING
      this.notify()
      try {
        const output = await this.toolBridge.executeReadTool(call)
        await this.requireTransport().submitToolResult(this.sessionId, call, true, output, '')
        this.handledCallIds.push(call.callId)
        this.updateActivity(call.callId, CodingAgentToolActivityStatus.SUCCEEDED, '读取完成')
      } catch (error) {
        const message = this.errorMessage(error, 'AGENT_READ_TOOL_FAILED')
        await this.submitToolFailure(call, message)
        this.updateActivity(call.callId, CodingAgentToolActivityStatus.FAILED, message)
      }
      this.state = CodingAgentState.THINKING
      this.notify()
      return
    }
    try {
      this.pendingApproval = await this.toolBridge.prepareApprovalForToolCall(call)
      this.pendingToolCall = call
      this.state = CodingAgentState.WAITING_APPROVAL
      this.notify()
    } catch (error) {
      const message = this.errorMessage(error, 'AGENT_TOOL_PREPARATION_FAILED')
      await this.submitToolFailure(call, message)
      this.updateActivity(call.callId, CodingAgentToolActivityStatus.FAILED, message)
      this.state = CodingAgentState.THINKING
      this.notify()
    }
  }

  private async recoverSession(): Promise<boolean> {
    if (!this.sessionId) return false
    try {
      const snapshot = await this.requireTransport().retrieveSession(this.sessionId)
      this.cursor = snapshot.cursor || this.cursor
      this.applyRemoteStatus(snapshot)
      if (snapshot.requiredActions.length > 0 && !this.pendingApproval) {
        await this.handleToolCall(snapshot.requiredActions[0])
      }
      return true
    } catch (error) {
      return false
    }
  }

  private applyRemoteStatus(snapshot: CodexAgentSessionSnapshot): void {
    if (snapshot.status === 'failed') {
      this.state = CodingAgentState.FAILED
      this.error = snapshot.error || 'CODEX_SESSION_FAILED'
    } else if (snapshot.status === 'cancelled') {
      this.state = CodingAgentState.STOPPED
    } else if (snapshot.status === 'idle' || snapshot.status === 'completed') {
      this.state = CodingAgentState.DONE
    } else if (snapshot.status === 'requires_action') {
      this.state = CodingAgentState.WAITING_APPROVAL
    } else {
      this.state = CodingAgentState.THINKING
    }
    this.notify()
  }

  private async submitToolFailure(call: CodingAgentToolCall, message: string): Promise<void> {
    if (!this.sessionId) return
    await this.requireTransport().submitToolResult(this.sessionId, call, false, '', message)
    this.handledCallIds.push(call.callId)
  }

  private async cancelRemoteSession(sessionId: string): Promise<void> {
    try {
      await this.requireTransport().cancel(sessionId)
    } catch (error) {
      this.error = this.errorMessage(error, 'CODEX_CANCEL_FAILED')
      this.notify()
    }
  }

  private buildAuthorizedPrompt(task: CodingAgentTask): string {
    const context = task.context
    let prompt = task.prompt.trim() + '\n\nAuthorized project root: ' + context.projectRoot
    if (context.activeFilePath) {
      prompt += '\nActive file: ' + context.activeFilePath
      prompt += '\nActive editor buffer supplied explicitly by the user (read-only context):\n' +
        context.activeEditorBuffer
    }
    prompt += '\n\nUse only registered HiSH tools. Never access paths outside the authorized root. ' +
      'Read calls may run automatically. File writes and commands require explicit user approval.'
    return prompt
  }

  private appendMessage(role: CodingAgentMessageRole, content: string): string {
    this.messageSequence++
    const id = 'codex-message-' + this.messageSequence
    this.messages.push(new CodingAgentMessage(id, role, content))
    return id
  }

  private appendAssistantDelta(messageId: string, delta: string): void {
    if (!this.assistantMessageId) {
      this.assistantMessageId = messageId || this.appendMessage(CodingAgentMessageRole.ASSISTANT, '')
      if (messageId) this.messages.push(new CodingAgentMessage(messageId, CodingAgentMessageRole.ASSISTANT, ''))
    }
    for (const message of this.messages) {
      if (message.id === this.assistantMessageId) message.content += delta
    }
    this.notify()
  }

  private completeAssistantMessage(messageId: string, content: string): void {
    const targetId = this.assistantMessageId || messageId
    let found = false
    for (const message of this.messages) {
      if (message.id === targetId) {
        if (content) message.content = content
        found = true
      }
    }
    if (!found && content) this.appendMessage(CodingAgentMessageRole.ASSISTANT, content)
    this.assistantMessageId = ''
    this.notify()
  }

  private addActivity(call: CodingAgentToolCall, status: CodingAgentToolActivityStatus, summary: string): void {
    this.activitySequence++
    this.activities.push(new CodingAgentToolActivity(call.callId || 'activity-' + this.activitySequence,
      call.name, summary, status))
    if (this.activities.length > 30) this.activities.shift()
  }

  private updateActivity(callId: string, status: CodingAgentToolActivityStatus, summary: string): void {
    for (const activity of this.activities) {
      if (activity.id === callId) {
        activity.status = status
        activity.summary = summary
      }
    }
  }

  private clearPendingApproval(): void {
    this.pendingApproval = null
    this.pendingToolCall = null
  }

  private notify(): void {
    const snapshot = this.getSnapshot()
    const listeners = this.subscriptions.slice()
    for (const subscription of listeners) {
      try {
        subscription.listener(snapshot)
      } catch (error) {
        console.error('Coding Agent listener failed')
      }
    }
  }

  private isTerminalState(): boolean {
    return this.state === CodingAgentState.DONE || this.state === CodingAgentState.FAILED ||
      this.state === CodingAgentState.STOPPED
  }

  private errorMessage(error: Object, fallback: string): string {
    return error instanceof Error ? error.message : fallback
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve): void => {
      setTimeout(resolve, ms)
    })
  }

  private requireTransport(): ICodexAgentTransport {
    if (!this.transport) throw new Error('CODEX_PROVIDER_NOT_INITIALIZED')
    return this.transport
  }
}

export const codexAgentProvider: CodexAgentProvider = new CodexAgentProvider()
