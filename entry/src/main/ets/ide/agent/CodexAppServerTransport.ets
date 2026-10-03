import { common } from '@kit.AbilityKit'
import { CodingAgentToolCall } from './CodingAgentContracts'
import ChatGPTOAuthService, { ChatGPTAccessToken } from './ChatGPTOAuthService'
import CodexGuestRuntimeManager from './CodexGuestRuntimeManager'
import CodexJsonlIpc from './CodexJsonlIpc'
import {
  CodexAgentEvent,
  CodexAgentEventBatch,
  CodexAgentSessionResult,
  CodexAgentSessionSnapshot,
  ICodexAgentTransport
} from './CodexAgentTransport'

interface AppServerResult {
  thread?: AppServerThread
  turn?: AppServerTurn
}

interface AppServerThread { id?: string }
interface AppServerTurn { id?: string, status?: string }

interface DynamicToolSpec {
  name: string
  description: string
  inputSchema: Object
}

interface JsonSchemaProperty { type: string }
interface JsonSchemaObject {
  type: string
  properties: Record<string, JsonSchemaProperty>
  required: string[]
  additionalProperties: boolean
}
interface ThreadStartParams {
  cwd: string
  modelProvider: string
  approvalPolicy: string
  sandbox: string
  developerInstructions: string
  dynamicTools: DynamicToolSpec[]
}
interface ToolContentItem { type: string, text: string }
interface ToolResultValue { contentItems: ToolContentItem[], success: boolean }
interface TurnInterruptParams { threadId: string, turnId: string }
interface ClientInfo { name: string, title: string, version: string }
interface ClientCapabilities { experimentalApi: boolean }
interface InitializeParams { clientInfo: ClientInfo, capabilities: ClientCapabilities }
interface ThreadResumeParams { threadId: string }
interface TurnTextInput { type: string, text: string }
interface TurnStartParams { threadId: string, input: TurnTextInput[] }
interface ApprovalDecision { decision: string }

class EventWaiter {
  resolve: (batch: CodexAgentEventBatch) => void
  timeoutId: number

  constructor(resolve: (batch: CodexAgentEventBatch) => void, timeoutId: number) {
    this.resolve = resolve
    this.timeoutId = timeoutId
  }
}

/** Official Codex 0.160 app-server JSONL transport. It deliberately exposes
 * only HiSH dynamic tools and keeps app-server's native sandbox read-only. */
export default class CodexAppServerTransport implements ICodexAgentTransport {
  private context: common.UIAbilityContext
  private auth: ChatGPTOAuthService
  private runtime: CodexGuestRuntimeManager
  private ipc: CodexJsonlIpc | null = null
  private threadId: string = ''
  private turnId: string = ''
  private status: string = 'idle'
  private lastError: string = ''
  private activeAccessToken: string = ''
  private events: CodexAgentEvent[] = []
  private cursor: number = 0
  private waiter: EventWaiter | null = null
  private toolRequestIds: Map<string, number> = new Map<string, number>()
  private connectInFlight: Promise<void> | null = null

  constructor(context: common.UIAbilityContext, auth: ChatGPTOAuthService) {
    this.context = context
    this.auth = auth
    this.runtime = new CodexGuestRuntimeManager(context)
  }

  isConfigured(): boolean {
    return this.auth.isSignedIn()
  }

  async createSession(prompt: string, projectRoot: string): Promise<CodexAgentSessionResult> {
    await this.ensureServer(false)
    const params: ThreadStartParams = {
      cwd: projectRoot,
      modelProvider: 'openai_chatgpt_plan',
      approvalPolicy: 'never',
      sandbox: 'read-only',
      developerInstructions: 'Use only the registered HiSH tools. Never access project files or run commands directly. ' +
        'All writes and commands require the host approval flow.',
      dynamicTools: this.dynamicTools()
    }
    const result = await this.requireIpc().request('thread/start', params) as AppServerResult
    this.threadId = result.thread && result.thread.id ? result.thread.id : ''
    if (!this.threadId) throw new Error('CODEX_THREAD_START_INVALID_RESPONSE')
    this.status = 'in_progress'
    await this.startTurn(prompt)
    return new CodexAgentSessionResult(this.threadId, this.status, this.cursor.toString())
  }

  async sendMessage(sessionId: string, prompt: string): Promise<void> {
    this.requireSession(sessionId)
    await this.ensureServer(true)
    await this.startTurn(prompt)
  }

  async pollEvents(sessionId: string, cursor: string): Promise<CodexAgentEventBatch> {
    this.requireSession(sessionId)
    const requested = parseInt(cursor || '0') || 0
    if (this.events.length > 0 && this.cursor > requested) return this.drainEvents()
    return new Promise<CodexAgentEventBatch>((resolve): void => {
      if (this.waiter) {
        clearTimeout(this.waiter.timeoutId)
        this.waiter.resolve(new CodexAgentEventBatch([], this.cursor.toString()))
      }
      const timeoutId = setTimeout((): void => {
        this.waiter = null
        resolve(new CodexAgentEventBatch([], this.cursor.toString()))
      }, 25000)
      this.waiter = new EventWaiter(resolve, timeoutId)
    })
  }

  async retrieveSession(sessionId: string): Promise<CodexAgentSessionSnapshot> {
    this.requireSession(sessionId)
    if (!this.ipc || !this.ipc.isConnected()) {
      try { await this.ensureServer(true) } catch (error) {
        return new CodexAgentSessionSnapshot(sessionId, 'failed', this.cursor.toString(),
          this.errorMessage(error, 'CODEX_RECONNECT_FAILED'), [])
      }
    }
    return new CodexAgentSessionSnapshot(sessionId, this.status, this.cursor.toString(), this.lastError, [])
  }

  async submitToolResult(sessionId: string, call: CodingAgentToolCall,
    success: boolean, output: string, error: string): Promise<void> {
    this.requireSession(sessionId)
    await this.ensureServer(true)
    const requestId = this.toolRequestIds.get(call.callId)
    if (requestId === undefined) throw new Error('CODEX_TOOL_REQUEST_NOT_FOUND')
    this.toolRequestIds.delete(call.callId)
    const text = success ? output : (error || 'Tool call failed')
    const contentItem: ToolContentItem = { type: 'inputText', text: text }
    const result: ToolResultValue = { contentItems: [contentItem], success: success }
    await this.requireIpc().respond(requestId, result)
  }

  async cancel(sessionId: string): Promise<void> {
    this.requireSession(sessionId)
    if (this.ipc && this.ipc.isConnected() && this.turnId) {
      const params: TurnInterruptParams = { threadId: this.threadId, turnId: this.turnId }
      await this.ipc.request('turn/interrupt', params, 10000)
    }
    this.status = 'cancelled'
  }

  async shutdown(): Promise<void> {
    this.ipc = null
    this.activeAccessToken = ''
    await this.runtime.stop()
  }

  private async ensureServer(resume: boolean): Promise<void> {
    if (this.connectInFlight) return await this.connectInFlight
    const token = await this.auth.getValidAccessToken()
    if (this.ipc && this.ipc.isConnected() && this.activeAccessToken === token.value) return
    this.connectInFlight = this.connectServer(token, resume)
    try { await this.connectInFlight } finally { this.connectInFlight = null }
  }

  private async connectServer(token: ChatGPTAccessToken, resume: boolean): Promise<void> {
    const ipc = await this.runtime.start(token.value)
    this.ipc = ipc
    this.activeAccessToken = token.value
    ipc.setNotificationListener((method: string, params: Object): void => this.handleNotification(method, params))
    ipc.setRequestListener((id: number, method: string, params: Object): void => {
      void this.handleServerRequest(id, method, params)
    })
    const clientInfo: ClientInfo = { name: 'HiSH', title: 'HiSH', version: '1.0.0' }
    const capabilities: ClientCapabilities = { experimentalApi: true }
    const initializeParams: InitializeParams = { clientInfo: clientInfo, capabilities: capabilities }
    await ipc.request('initialize', initializeParams)
    await ipc.notify('initialized', new Object())
    if (resume && this.threadId) {
      const resumeParams: ThreadResumeParams = { threadId: this.threadId }
      await ipc.request('thread/resume', resumeParams)
    }
  }

  private async startTurn(prompt: string): Promise<void> {
    const input: TurnTextInput = { type: 'text', text: prompt }
    const params: TurnStartParams = { threadId: this.threadId, input: [input] }
    const result = await this.requireIpc().request('turn/start', params) as AppServerResult
    this.turnId = result.turn && result.turn.id ? result.turn.id : ''
    this.status = 'in_progress'
  }

  private handleNotification(method: string, params: Object): void {
    const value = params as Record<string, Object>
    if (method === 'item/agentMessage/delta') {
      this.pushEvent(new CodexAgentEvent('assistant.delta', '', this.stringValue(value['itemId']),
        this.stringValue(value['delta'])))
    } else if (method === 'item/completed') {
      const item = value['item'] as Record<string, Object>
      if (item && this.stringValue(item['type']) === 'agentMessage') {
        this.pushEvent(new CodexAgentEvent('assistant.completed', '', this.stringValue(item['id']),
          this.stringValue(item['text'])))
      }
    } else if (method === 'turn/completed') {
      const turn = value['turn'] as Record<string, Object>
      const status = turn ? this.stringValue(turn['status']) : 'completed'
      this.status = status === 'failed' ? 'failed' : (status === 'interrupted' ? 'cancelled' : 'completed')
      const eventType = this.status === 'failed' ? 'session.failed' :
        (this.status === 'cancelled' ? 'session.cancelled' : 'session.completed')
      this.pushEvent(new CodexAgentEvent(eventType, '', '', '', this.stringValue(value['error'])))
    } else if (method === 'error') {
      this.lastError = this.stringValue(value['message']) || 'CODEX_APP_SERVER_ERROR'
      this.status = 'failed'
      this.pushEvent(new CodexAgentEvent('session.failed', '', '', '', this.lastError))
    } else if (method === 'transport/disconnected') {
      this.ipc = null
      this.pushEvent(new CodexAgentEvent('transport.disconnected', '', '', '', 'CODEX_IPC_DISCONNECTED'))
    }
  }

  private async handleServerRequest(id: number, method: string, params: Object): Promise<void> {
    if (method === 'item/tool/call') {
      const value = params as Record<string, Object>
      const callId = this.stringValue(value['callId'])
      const tool = this.stringValue(value['tool'])
      const argumentsValue = value['arguments'] || new Object()
      if (!callId || !tool) {
        await this.requireIpc().respondError(id, -32602, 'Invalid dynamic tool call')
        return
      }
      this.toolRequestIds.set(callId, id)
      const call = new CodingAgentToolCall(this.stringValue(value['turnId']) || this.turnId,
        callId, tool, JSON.stringify(argumentsValue))
      this.pushEvent(new CodexAgentEvent('tool.call', '', '', '', '', call))
      return
    }
    if (method === 'item/commandExecution/requestApproval' || method === 'item/fileChange/requestApproval') {
      const decision: ApprovalDecision = { decision: 'decline' }
      await this.requireIpc().respond(id, decision)
      return
    }
    await this.requireIpc().respondError(id, -32601, 'Unsupported app-server request')
  }

  private pushEvent(event: CodexAgentEvent): void {
    this.cursor++
    event.cursor = this.cursor.toString()
    this.events.push(event)
    if (this.events.length > 200) this.events.shift()
    if (this.waiter) {
      const waiter = this.waiter
      this.waiter = null
      clearTimeout(waiter.timeoutId)
      waiter.resolve(this.drainEvents())
    }
  }

  private drainEvents(): CodexAgentEventBatch {
    const items = this.events.slice()
    this.events = []
    return new CodexAgentEventBatch(items, this.cursor.toString())
  }

  private dynamicTools(): DynamicToolSpec[] {
    return [
      this.tool('readFile', 'Read a UTF-8 project file.', ['path']),
      this.tool('listDirectory', 'List a project directory.', ['path']),
      this.tool('searchFiles', 'Search text in project files.', ['query']),
      this.tool('applyPatch', 'Replace exact text in one project file.', ['path', 'before', 'after']),
      this.tool('createFile', 'Create a project file.', ['path', 'content']),
      this.tool('renameFile', 'Rename a project file.', ['path', 'newName']),
      this.tool('deleteFile', 'Delete a project file.', ['path']),
      this.tool('runCommand', 'Run an approved shell command in the visible HiSH terminal.', ['command'])
    ]
  }

  private tool(name: string, description: string, required: string[]): DynamicToolSpec {
    const properties: Record<string, JsonSchemaProperty> = {}
    for (const key of required) {
      const property: JsonSchemaProperty = { type: 'string' }
      properties[key] = property
    }
    const schema: JsonSchemaObject = { type: 'object', properties: properties,
      required: required, additionalProperties: false }
    const spec: DynamicToolSpec = { name: name, description: description, inputSchema: schema }
    return spec
  }

  private requireSession(sessionId: string): void {
    if (!this.threadId || this.threadId !== sessionId) throw new Error('CODEX_SESSION_NOT_FOUND')
  }

  private requireIpc(): CodexJsonlIpc {
    if (!this.ipc) throw new Error('CODEX_IPC_NOT_CONNECTED')
    return this.ipc
  }

  private stringValue(value: Object | undefined): string {
    return typeof value === 'string' ? value : ''
  }

  private errorMessage(error: Object, fallback: string): string {
    return error instanceof Error ? error.message : fallback
  }
}
