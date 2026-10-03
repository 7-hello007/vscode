export enum CodingAgentState {
  IDLE = 'IDLE',
  THINKING = 'THINKING',
  READING = 'READING',
  EDITING = 'EDITING',
  WAITING_APPROVAL = 'WAITING_APPROVAL',
  RUNNING_COMMAND = 'RUNNING_COMMAND',
  DONE = 'DONE',
  FAILED = 'FAILED',
  STOPPED = 'STOPPED'
}

export enum CodingAgentToolName {
  READ_FILE = 'readFile',
  LIST_DIRECTORY = 'listDirectory',
  SEARCH_FILES = 'searchFiles',
  APPLY_PATCH = 'applyPatch',
  CREATE_FILE = 'createFile',
  RENAME_FILE = 'renameFile',
  DELETE_FILE = 'deleteFile',
  RUN_COMMAND = 'runCommand'
}

export enum CodingAgentApprovalKind {
  FILE_WRITE = 'FILE_WRITE',
  COMMAND = 'COMMAND'
}

export enum CodingAgentMessageRole {
  USER = 'user',
  ASSISTANT = 'assistant',
  SYSTEM = 'system'
}

export enum CodingAgentToolActivityStatus {
  RUNNING = 'RUNNING',
  WAITING_APPROVAL = 'WAITING_APPROVAL',
  SUCCEEDED = 'SUCCEEDED',
  REJECTED = 'REJECTED',
  FAILED = 'FAILED'
}

export class CodingAgentContext {
  projectRoot: string
  activeFilePath: string
  activeEditorBuffer: string

  constructor(projectRoot: string, activeFilePath: string, activeEditorBuffer: string) {
    this.projectRoot = projectRoot
    this.activeFilePath = activeFilePath
    this.activeEditorBuffer = activeEditorBuffer
  }
}

export class CodingAgentTask {
  prompt: string
  context: CodingAgentContext

  constructor(prompt: string, context: CodingAgentContext) {
    this.prompt = prompt
    this.context = context
  }
}

export class CodingAgentProviderInfo {
  id: string
  name: string
  available: boolean
  availabilityMessage: string

  constructor(id: string, name: string, available: boolean, availabilityMessage: string = '') {
    this.id = id
    this.name = name
    this.available = available
    this.availabilityMessage = availabilityMessage
  }
}

export class CodingAgentStartResult {
  sessionId: string
  state: CodingAgentState
  message: string

  constructor(sessionId: string, state: CodingAgentState, message: string) {
    this.sessionId = sessionId
    this.state = state
    this.message = message
  }
}

export class CodingAgentMessage {
  id: string
  role: CodingAgentMessageRole
  content: string

  constructor(id: string, role: CodingAgentMessageRole, content: string) {
    this.id = id
    this.role = role
    this.content = content
  }
}

export class CodingAgentToolActivity {
  id: string
  tool: string
  summary: string
  status: CodingAgentToolActivityStatus

  constructor(id: string, tool: string, summary: string, status: CodingAgentToolActivityStatus) {
    this.id = id
    this.tool = tool
    this.summary = summary
    this.status = status
  }
}

export class CodingAgentToolCall {
  turnId: string
  callId: string
  name: string
  argumentsJson: string

  constructor(turnId: string, callId: string, name: string, argumentsJson: string) {
    this.turnId = turnId
    this.callId = callId
    this.name = name
    this.argumentsJson = argumentsJson
  }
}

export class AgentCommandExecutionResult {
  stdout: string
  stderr: string
  exitCode: number

  constructor(stdout: string, stderr: string, exitCode: number) {
    this.stdout = stdout
    this.stderr = stderr
    this.exitCode = exitCode
  }
}

export interface AgentCommandExecutor {
  executeApprovedCommand(command: string): Promise<AgentCommandExecutionResult>
}

export class CodingAgentDiffPreview {
  path: string
  location: string
  before: string
  after: string

  constructor(path: string, location: string, before: string, after: string) {
    this.path = path
    this.location = location
    this.before = before
    this.after = after
  }
}

export class CodingAgentApprovalRequest {
  id: string
  kind: CodingAgentApprovalKind
  tool: CodingAgentToolName
  title: string
  command: string
  argumentsJson: string
  diffs: CodingAgentDiffPreview[]

  constructor(id: string, kind: CodingAgentApprovalKind, tool: CodingAgentToolName, title: string,
    command: string, argumentsJson: string, diffs: CodingAgentDiffPreview[]) {
    this.id = id
    this.kind = kind
    this.tool = tool
    this.title = title
    this.command = command
    this.argumentsJson = argumentsJson
    this.diffs = diffs
  }
}

export class CodingAgentSnapshot {
  state: CodingAgentState
  sessionId: string
  messages: CodingAgentMessage[]
  activities: CodingAgentToolActivity[]
  pendingApproval: CodingAgentApprovalRequest | null
  error: string
  configured: boolean

  constructor(state: CodingAgentState, sessionId: string, messages: CodingAgentMessage[],
    activities: CodingAgentToolActivity[], pendingApproval: CodingAgentApprovalRequest | null,
    error: string, configured: boolean) {
    this.state = state
    this.sessionId = sessionId
    this.messages = messages
    this.activities = activities
    this.pendingApproval = pendingApproval
    this.error = error
    this.configured = configured
  }
}

export type CodingAgentListener = (snapshot: CodingAgentSnapshot) => void

export interface CodingAgentProvider {
  getInfo(): CodingAgentProviderInfo
  getState(): CodingAgentState
  getSnapshot(): CodingAgentSnapshot
  subscribe(id: string, listener: CodingAgentListener): void
  unsubscribe(id: string): void
  start(task: CodingAgentTask): Promise<CodingAgentStartResult>
  approve(requestId: string): Promise<void>
  reject(requestId: string): Promise<void>
  stop(): void
}

