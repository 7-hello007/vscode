import IDEFileSystem from '../filesystem/IDEFileSystem'
import { IDEFileEntry, IDEFileType } from '../filesystem/IDEFileSystemTypes'
import {
  AgentCommandExecutionResult,
  AgentCommandExecutor,
  CodingAgentApprovalKind,
  CodingAgentApprovalRequest,
  CodingAgentDiffPreview,
  CodingAgentToolCall,
  CodingAgentToolName
} from './CodingAgentContracts'

export class AgentSearchMatch {
  path: string
  line: number
  preview: string

  constructor(path: string, line: number, preview: string) {
    this.path = path
    this.line = line
    this.preview = preview
  }
}

class AgentToolArguments {
  path?: string
  query?: string
  startPath?: string
  before?: string
  after?: string
  content?: string
  newName?: string
  command?: string
}

class AgentCommandResultPayload {
  stdout: string
  stderr: string
  exitCode: number

  constructor(result: AgentCommandExecutionResult) {
    this.stdout = result.stdout
    this.stderr = result.stderr
    this.exitCode = result.exitCode
  }
}

/**
 * Project-root-scoped adapter over existing HiSH services. Read calls execute;
 * side-effect calls only create reviewable approval requests until Apply.
 */
export default class HiSHAgentToolBridge {
  private fileSystem: IDEFileSystem
  private commandExecutor: AgentCommandExecutor
  private projectRoot: string
  private requestSequence: number = 0

  constructor(fileSystem: IDEFileSystem, commandExecutor: AgentCommandExecutor, projectRoot: string) {
    this.fileSystem = fileSystem
    this.commandExecutor = commandExecutor
    this.projectRoot = this.fileSystem.normalizePath(projectRoot)
  }

  setProjectRoot(projectRoot: string): void {
    this.projectRoot = this.fileSystem.normalizePath(projectRoot)
  }

  async readFile(path: string): Promise<string> {
    return this.fileSystem.readFile(this.requireProjectPath(path))
  }

  async listDirectory(path: string): Promise<IDEFileEntry[]> {
    return this.fileSystem.listDirectory(this.requireProjectPath(path))
  }

  async searchFiles(query: string, startPath: string = ''): Promise<AgentSearchMatch[]> {
    const needle = query.trim()
    if (!needle) return []
    const root = this.requireProjectPath(startPath || this.projectRoot)
    const results: AgentSearchMatch[] = []
    const paths: string[] = [root]
    const depths: number[] = [0]
    let visitedFiles = 0
    while (paths.length > 0 && visitedFiles < 200 && results.length < 100) {
      const current = paths.shift() || root
      const depth = depths.shift() || 0
      const entries = await this.fileSystem.listDirectory(current)
      for (const entry of entries) {
        if (entry.type === IDEFileType.DIRECTORY && depth < 8 && !this.isIgnoredDirectory(entry.name)) {
          paths.push(entry.path)
          depths.push(depth + 1)
          continue
        }
        if (entry.type !== IDEFileType.FILE || this.isLikelyBinary(entry.name)) continue
        visitedFiles++
        const content = await this.fileSystem.readFile(entry.path)
        const lines = content.split('\n')
        for (let index = 0; index < lines.length && results.length < 100; index++) {
          if (lines[index].indexOf(needle) !== -1) {
            results.push(new AgentSearchMatch(entry.path, index + 1, lines[index].trim()))
          }
        }
        if (visitedFiles >= 200 || results.length >= 100) break
      }
    }
    return results
  }

  async executeReadTool(call: CodingAgentToolCall): Promise<string> {
    const args = this.parseArguments(call.argumentsJson)
    if (call.name === CodingAgentToolName.READ_FILE) {
      return await this.readFile(this.requireArgument(args.path, 'path'))
    }
    if (call.name === CodingAgentToolName.LIST_DIRECTORY) {
      return JSON.stringify(await this.listDirectory(this.requireArgument(args.path, 'path')))
    }
    if (call.name === CodingAgentToolName.SEARCH_FILES) {
      return JSON.stringify(await this.searchFiles(this.requireArgument(args.query, 'query'), args.startPath || ''))
    }
    throw new Error('AGENT_TOOL_NOT_READ_ONLY')
  }

  async prepareApprovalForToolCall(call: CodingAgentToolCall): Promise<CodingAgentApprovalRequest> {
    const args = this.parseArguments(call.argumentsJson)
    if (call.name === CodingAgentToolName.APPLY_PATCH) {
      return this.prepareApplyPatch(this.requireArgument(args.path, 'path'),
        this.requireArgument(args.before, 'before'), this.requireArgument(args.after, 'after'))
    }
    if (call.name === CodingAgentToolName.CREATE_FILE) {
      return this.prepareCreateFile(this.requireArgument(args.path, 'path'), args.content || '')
    }
    if (call.name === CodingAgentToolName.RENAME_FILE) {
      return this.prepareRenameFile(this.requireArgument(args.path, 'path'),
        this.requireArgument(args.newName, 'newName'))
    }
    if (call.name === CodingAgentToolName.DELETE_FILE) {
      return this.prepareDeleteFile(this.requireArgument(args.path, 'path'))
    }
    if (call.name === CodingAgentToolName.RUN_COMMAND) {
      return this.prepareRunCommand(this.requireArgument(args.command, 'command'))
    }
    throw new Error('AGENT_TOOL_UNSUPPORTED')
  }

  async prepareApplyPatch(path: string, before: string, after: string): Promise<CodingAgentApprovalRequest> {
    const target = this.requireProjectPath(path)
    const current = await this.fileSystem.readFile(target)
    if (current !== before) {
      throw new Error('AGENT_PATCH_BASE_CHANGED')
    }
    return this.fileApproval(CodingAgentToolName.APPLY_PATCH, '修改文件 ' + target,
      target, 'whole file', before, after, JSON.stringify({ path: target, after }))
  }

  prepareCreateFile(path: string, content: string): CodingAgentApprovalRequest {
    const target = this.requireProjectPath(path)
    return this.fileApproval(CodingAgentToolName.CREATE_FILE, '创建文件 ' + target,
      target, 'new file', '', content, JSON.stringify({ path: target, content }))
  }

  prepareRenameFile(path: string, newName: string): CodingAgentApprovalRequest {
    const source = this.requireProjectPath(path)
    return this.fileApproval(CodingAgentToolName.RENAME_FILE, '重命名文件 ' + source,
      source, 'rename', source, newName, JSON.stringify({ path: source, newName }))
  }

  async prepareDeleteFile(path: string): Promise<CodingAgentApprovalRequest> {
    const target = this.requireProjectPath(path)
    const before = await this.fileSystem.readFile(target)
    return this.fileApproval(CodingAgentToolName.DELETE_FILE, '删除文件 ' + target,
      target, 'delete file', before, '', JSON.stringify({ path: target }))
  }

  prepareRunCommand(command: string): CodingAgentApprovalRequest {
    const normalized = command.trim()
    if (!normalized) throw new Error('AGENT_COMMAND_EMPTY')
    if (this.isDangerousCommand(normalized)) throw new Error('AGENT_DANGEROUS_COMMAND_REJECTED')
    return new CodingAgentApprovalRequest(this.nextRequestId(), CodingAgentApprovalKind.COMMAND,
      CodingAgentToolName.RUN_COMMAND, '运行命令', normalized,
      JSON.stringify({ command: normalized }), [])
  }

  async applyApproved(request: CodingAgentApprovalRequest): Promise<string> {
    if (request.kind === CodingAgentApprovalKind.COMMAND) {
      const result = await this.commandExecutor.executeApprovedCommand(request.command)
      return JSON.stringify(new AgentCommandResultPayload(result))
    }
    const args = this.parseArguments(request.argumentsJson)
    if (request.tool === CodingAgentToolName.APPLY_PATCH) {
      await this.fileSystem.writeFile(this.requireProjectPath(this.requireArgument(args.path, 'path')),
        this.requireArgument(args.after, 'after'))
    } else if (request.tool === CodingAgentToolName.CREATE_FILE) {
      const target = this.requireProjectPath(this.requireArgument(args.path, 'path'))
      await this.fileSystem.createFile(this.fileSystem.parentPath(target), this.fileSystem.baseName(target))
      await this.fileSystem.writeFile(target, args.content || '')
    } else if (request.tool === CodingAgentToolName.RENAME_FILE) {
      await this.fileSystem.renameEntry(this.requireProjectPath(this.requireArgument(args.path, 'path')),
        this.requireArgument(args.newName, 'newName'))
    } else if (request.tool === CodingAgentToolName.DELETE_FILE) {
      await this.fileSystem.deleteEntry(this.requireProjectPath(this.requireArgument(args.path, 'path')))
    } else {
      throw new Error('AGENT_APPROVAL_TOOL_UNSUPPORTED')
    }
    return JSON.stringify({ success: true, tool: request.tool })
  }

  private fileApproval(tool: CodingAgentToolName, title: string, path: string, location: string,
    before: string, after: string, argumentsJson: string): CodingAgentApprovalRequest {
    return new CodingAgentApprovalRequest(this.nextRequestId(), CodingAgentApprovalKind.FILE_WRITE,
      tool, title, '', argumentsJson, [new CodingAgentDiffPreview(path, location, before, after)])
  }

  private requireProjectPath(path: string): string {
    const normalized = this.fileSystem.normalizePath(path)
    if (this.projectRoot !== '/' && normalized !== this.projectRoot &&
      !normalized.startsWith(this.projectRoot + '/')) {
      throw new Error('AGENT_PATH_OUTSIDE_PROJECT')
    }
    return normalized
  }

  private isIgnoredDirectory(name: string): boolean {
    return name === '.git' || name === '.hvigor' || name === '.cxx' || name === 'node_modules' ||
      name === 'vendor' || name === 'build' || name === 'dist' || name === 'target'
  }

  private isLikelyBinary(name: string): boolean {
    const lower = name.toLowerCase()
    const suffixes = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.zip', '.gz', '.tar', '.so', '.a',
      '.o', '.class', '.jar', '.hap', '.bin', '.gguf', '.pdf', '.mp3', '.mp4']
    for (const suffix of suffixes) {
      if (lower.endsWith(suffix)) return true
    }
    return false
  }

  private isDangerousCommand(command: string): boolean {
    const lower = command.toLowerCase()
    return lower.indexOf('rm -rf /') !== -1 || lower.indexOf('mkfs') !== -1 ||
      lower.indexOf('dd if=') !== -1 || lower.indexOf('shutdown') !== -1 ||
      lower.indexOf('reboot') !== -1 || lower.indexOf(':(){:|:&};:') !== -1
  }

  private parseArguments(argumentsJson: string): AgentToolArguments {
    return JSON.parse(argumentsJson || '{}') as AgentToolArguments
  }

  private requireArgument(value: string | undefined, name: string): string {
    if (value === undefined) throw new Error('AGENT_ARGUMENT_REQUIRED_' + name)
    return value
  }

  private nextRequestId(): string {
    this.requestSequence++
    return 'agent-approval-' + this.requestSequence
  }
}

