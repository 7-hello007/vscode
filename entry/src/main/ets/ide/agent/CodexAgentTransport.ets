import { http } from '@kit.NetworkKit'
import { CodingAgentToolCall } from './CodingAgentContracts'

/** Trusted HiSH backend configuration. No OpenAI API key is accepted here. */
export class CodexAgentConnectionConfig {
  backendBaseUrl: string
  agentId: string
  appSessionToken: string

  constructor(backendBaseUrl: string, agentId: string, appSessionToken: string) {
    this.backendBaseUrl = backendBaseUrl
    this.agentId = agentId
    this.appSessionToken = appSessionToken
  }
}

export class CodexAgentSessionResult {
  id: string
  status: string
  cursor: string

  constructor(id: string, status: string, cursor: string = '') {
    this.id = id
    this.status = status
    this.cursor = cursor
  }
}

export class CodexAgentEvent {
  type: string
  cursor: string
  messageId: string
  content: string
  error: string
  toolCall: CodingAgentToolCall | null

  constructor(type: string, cursor: string, messageId: string = '', content: string = '',
    error: string = '', toolCall: CodingAgentToolCall | null = null) {
    this.type = type
    this.cursor = cursor
    this.messageId = messageId
    this.content = content
    this.error = error
    this.toolCall = toolCall
  }
}

export class CodexAgentEventBatch {
  events: CodexAgentEvent[]
  nextCursor: string

  constructor(events: CodexAgentEvent[], nextCursor: string) {
    this.events = events
    this.nextCursor = nextCursor
  }
}

export class CodexAgentSessionSnapshot {
  id: string
  status: string
  cursor: string
  error: string
  requiredActions: CodingAgentToolCall[]

  constructor(id: string, status: string, cursor: string, error: string,
    requiredActions: CodingAgentToolCall[]) {
    this.id = id
    this.status = status
    this.cursor = cursor
    this.error = error
    this.requiredActions = requiredActions
  }
}

/** Common transport contract. The app-server transport is the default while
 * this file remains the trusted-backend fallback. */
export interface ICodexAgentTransport {
  isConfigured(): boolean
  createSession(prompt: string, projectRoot: string): Promise<CodexAgentSessionResult>
  sendMessage(sessionId: string, prompt: string): Promise<void>
  pollEvents(sessionId: string, cursor: string): Promise<CodexAgentEventBatch>
  retrieveSession(sessionId: string): Promise<CodexAgentSessionSnapshot>
  submitToolResult(sessionId: string, call: CodingAgentToolCall,
    success: boolean, output: string, error: string): Promise<void>
  cancel(sessionId: string): Promise<void>
}

interface BackendToolCallPayload {
  turn_id?: string
  call_id?: string
  name?: string
  arguments_json?: string
}

interface BackendEventPayload {
  type?: string
  cursor?: string
  message_id?: string
  content?: string
  error?: string
  tool_call?: BackendToolCallPayload
}

interface BackendEventBatchPayload {
  events?: BackendEventPayload[]
  next_cursor?: string
}

interface BackendSessionPayload {
  id?: string
  status?: string
  cursor?: string
  error?: string
  required_actions?: BackendToolCallPayload[]
}

class BackendCreateSessionPayload {
  agent_id: string
  input: string
  project_root: string
  tools: string[]

  constructor(agentId: string, input: string, projectRoot: string, tools: string[]) {
    this.agent_id = agentId
    this.input = input
    this.project_root = projectRoot
    this.tools = tools
  }
}

class BackendMessagePayload {
  input: string

  constructor(input: string) {
    this.input = input
  }
}

class BackendToolResultPayload {
  turn_id: string
  call_id: string
  success: boolean
  output: string
  error: string

  constructor(turnId: string, callId: string, success: boolean, output: string, error: string) {
    this.turn_id = turnId
    this.call_id = callId
    this.success = success
    this.output = output
    this.error = error
  }
}

class BackendToolResultsEnvelope {
  results: BackendToolResultPayload[]

  constructor(result: BackendToolResultPayload) {
    this.results = [result]
  }
}

class BackendCancelPayload {
  reason: string = 'user_requested'
}

const AGENT_TOOL_NAMES: string[] = [
  'readFile', 'listDirectory', 'searchFiles', 'applyPatch',
  'createFile', 'renameFile', 'deleteFile', 'runCommand'
]

/**
 * The trusted backend owns the OpenAI key and maps these endpoints to the
 * official Agents API session/event endpoints:
 * POST /v1/hish/codex/sessions
 * POST /v1/hish/codex/sessions/{id}/messages
 * GET  /v1/hish/codex/sessions/{id}/events?cursor=...&wait_ms=25000
 * GET  /v1/hish/codex/sessions/{id}
 * POST /v1/hish/codex/sessions/{id}/tool-results
 * POST /v1/hish/codex/sessions/{id}/cancel
 */
export default class TrustedBackendTransport implements ICodexAgentTransport {
  private config: CodexAgentConnectionConfig | null = null

  configure(config: CodexAgentConnectionConfig): void {
    this.validateConfig(config)
    this.config = config
  }

  clearCredentials(): void {
    this.config = null
  }

  isConfigured(): boolean {
    return this.config !== null
  }

  async createSession(prompt: string, projectRoot: string): Promise<CodexAgentSessionResult> {
    const config = this.requireConfig()
    const payload = new BackendCreateSessionPayload(config.agentId, prompt, projectRoot, AGENT_TOOL_NAMES)
    const parsed = await this.requestJson('POST', '/v1/hish/codex/sessions', JSON.stringify(payload)) as
      BackendSessionPayload
    if (!parsed.id) throw new Error(parsed.error || 'CODEX_SESSION_INVALID_RESPONSE')
    return new CodexAgentSessionResult(parsed.id, parsed.status || 'in_progress', parsed.cursor || '')
  }

  async sendMessage(sessionId: string, prompt: string): Promise<void> {
    await this.requestJson('POST', this.sessionPath(sessionId) + '/messages',
      JSON.stringify(new BackendMessagePayload(prompt)))
  }

  async pollEvents(sessionId: string, cursor: string): Promise<CodexAgentEventBatch> {
    const path = this.sessionPath(sessionId) + '/events?cursor=' + encodeURIComponent(cursor) + '&wait_ms=25000'
    const parsed = await this.requestJson('GET', path, '') as BackendEventBatchPayload
    const events: CodexAgentEvent[] = []
    for (const item of parsed.events || []) events.push(this.toEvent(item))
    return new CodexAgentEventBatch(events, parsed.next_cursor || cursor)
  }

  async retrieveSession(sessionId: string): Promise<CodexAgentSessionSnapshot> {
    const parsed = await this.requestJson('GET', this.sessionPath(sessionId), '') as BackendSessionPayload
    const actions: CodingAgentToolCall[] = []
    for (const action of parsed.required_actions || []) {
      const call = this.toToolCall(action)
      if (call) actions.push(call)
    }
    return new CodexAgentSessionSnapshot(parsed.id || sessionId, parsed.status || 'failed',
      parsed.cursor || '', parsed.error || '', actions)
  }

  async submitToolResult(sessionId: string, call: CodingAgentToolCall,
    success: boolean, output: string, error: string): Promise<void> {
    const result = new BackendToolResultPayload(call.turnId, call.callId, success, output, error)
    await this.requestJson('POST', this.sessionPath(sessionId) + '/tool-results',
      JSON.stringify(new BackendToolResultsEnvelope(result)))
  }

  async cancel(sessionId: string): Promise<void> {
    await this.requestJson('POST', this.sessionPath(sessionId) + '/cancel',
      JSON.stringify(new BackendCancelPayload()))
  }

  private async requestJson(method: string, path: string, body: string): Promise<Object> {
    const config = this.requireConfig()
    const request = http.createHttp()
    try {
      const options: http.HttpRequestOptions = {
        method: method === 'GET' ? http.RequestMethod.GET : http.RequestMethod.POST,
        header: {
          'Authorization': 'Bearer ' + config.appSessionToken,
          'Content-Type': 'application/json'
        },
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        connectTimeout: 15000,
        readTimeout: 35000
      }
      if (body) options.extraData = body
      const response = await request.request(config.backendBaseUrl + path, options)
      const responseText = typeof response.result === 'string' ? response.result : ''
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('CODEX_BACKEND_HTTP_' + response.responseCode)
      }
      if (!responseText) return new Object()
      return JSON.parse(responseText) as Object
    } finally {
      request.destroy()
    }
  }

  private toEvent(payload: BackendEventPayload): CodexAgentEvent {
    return new CodexAgentEvent(payload.type || 'unknown', payload.cursor || '',
      payload.message_id || '', payload.content || '', payload.error || '',
      payload.tool_call ? this.toToolCall(payload.tool_call) : null)
  }

  private toToolCall(payload: BackendToolCallPayload): CodingAgentToolCall | null {
    if (!payload.turn_id || !payload.call_id || !payload.name) return null
    return new CodingAgentToolCall(payload.turn_id, payload.call_id, payload.name,
      payload.arguments_json || '{}')
  }

  private sessionPath(sessionId: string): string {
    return '/v1/hish/codex/sessions/' + encodeURIComponent(sessionId)
  }

  private requireConfig(): CodexAgentConnectionConfig {
    if (!this.config) throw new Error('CODEX_NOT_CONFIGURED')
    return this.config
  }

  private validateConfig(config: CodexAgentConnectionConfig): void {
    if (!config.backendBaseUrl.startsWith('https://')) throw new Error('CODEX_HTTPS_BACKEND_REQUIRED')
    if (config.backendBaseUrl.indexOf('api.openai.com') !== -1) {
      throw new Error('CODEX_DIRECT_OPENAI_CLIENT_AUTH_FORBIDDEN')
    }
    if (!config.agentId.trim()) throw new Error('CODEX_AGENT_ID_REQUIRED')
    if (!config.appSessionToken.trim()) throw new Error('CODEX_APP_SESSION_REQUIRED')
  }
}
