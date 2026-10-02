export enum IDEAIProviderKind {
  CLOUD = 'cloud',
  LOCAL = 'local'
}

export enum IDEAIMessageRole {
  USER = 'user',
  ASSISTANT = 'assistant',
  SYSTEM = 'system'
}

export class IDEAIFileContext {
  path: string
  language: string
  content: string
  active: boolean

  constructor(path: string, language: string, content: string, active: boolean) {
    this.path = path
    this.language = language
    this.content = content
    this.active = active
  }
}

/** Immutable snapshot supplied by the Workbench, never read from editor internals. */
export class IDEAIContext {
  activeFilePath: string
  activeFileContent: string
  selectedText: string
  language: string
  openedFiles: IDEAIFileContext[]
  terminalOutput: string

  constructor(activeFilePath: string, activeFileContent: string, selectedText: string,
    language: string, openedFiles: IDEAIFileContext[], terminalOutput: string) {
    this.activeFilePath = activeFilePath
    this.activeFileContent = activeFileContent
    this.selectedText = selectedText
    this.language = language
    this.openedFiles = openedFiles
    this.terminalOutput = terminalOutput
  }
}

export class IDEAIRequest {
  prompt: string
  context: IDEAIContext
  history: IDEAIConversationTurn[]

  constructor(prompt: string, context: IDEAIContext, history: IDEAIConversationTurn[] = []) {
    this.prompt = prompt
    this.context = context
    this.history = history
  }
}

/** One completed exchange retained by the provider-neutral AI service. */
export class IDEAIConversationTurn {
  user: string
  assistant: string

  constructor(user: string, assistant: string) {
    this.user = user
    this.assistant = assistant
  }
}

export class IDEAIResponse {
  content: string

  constructor(content: string) {
    this.content = content
  }
}

export class IDEAIProviderInfo {
  id: string
  name: string
  kind: IDEAIProviderKind
  available: boolean

  constructor(id: string, name: string, kind: IDEAIProviderKind, available: boolean) {
    this.id = id
    this.name = name
    this.kind = kind
    this.available = available
  }
}

/** Cloud and local adapters implement the same provider contract. */
export interface IDEAIProvider {
  getInfo(): IDEAIProviderInfo
  generate(request: IDEAIRequest): Promise<IDEAIResponse>
}

export class IDEAIMessage {
  id: string
  role: IDEAIMessageRole
  content: string

  constructor(id: string, role: IDEAIMessageRole, content: string) {
    this.id = id
    this.role = role
    this.content = content
  }
}
