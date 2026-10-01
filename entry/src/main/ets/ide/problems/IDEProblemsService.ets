import QemuAgent from '../../lib/QemuAgent'
import { AgentPriority, QemuAgentManager } from '../../lib/QemuAgentManager'
import IDEFileSystem from '../filesystem/IDEFileSystem'
import { IDEFileEntry, IDEFileType } from '../filesystem/IDEFileSystemTypes'
import { IDEDiagnosticResult, IDEProblem, IDEProblemSeverity } from './IDEProblemContracts'

interface GuestShellResult {
  output: string
  status: number
}

class IDEDiagnosticTools {
  python: boolean = false
  node: boolean = false
  shell: boolean = false
  cCompiler: string = ''

  summary(): string {
    const names: string[] = []
    if (this.python) names.push('python3/ast')
    if (this.node) names.push('node --check')
    if (this.shell) names.push('sh -n')
    if (this.cCompiler) names.push(this.cCompiler + ' -fsyntax-only')
    return names.length > 0 ? names.join(', ') : 'unavailable'
  }
}

class ScanDirectory {
  path: string
  depth: number

  constructor(path: string, depth: number) {
    this.path = path
    this.depth = depth
  }
}

const DIAGNOSTICS_USER_ID = 'IDEProblems'
const DIAGNOSTICS_STATUS_MARKER = '__HISH_PROBLEMS_STATUS__'
const MAX_PROJECT_FILES = 100
const MAX_PROJECT_DEPTH = 6
const MAX_SOURCE_FILE_SIZE = 512 * 1024

export default class IDEProblemsService {
  private fileSystem: IDEFileSystem
  private generation: number = 0
  private problemSequence: number = 0

  constructor(fileSystem: IDEFileSystem) {
    this.fileSystem = fileSystem
  }

  cancel(): void {
    this.generation++
  }

  async diagnoseFile(path: string): Promise<IDEDiagnosticResult> {
    const generation = ++this.generation
    const result = new IDEDiagnosticResult()
    let tools: IDEDiagnosticTools | null = null
    try {
      tools = await this.probeTools(generation)
    } catch (error) {
      result.failureMessage = this.failureMessage(error as Error)
      return result
    }
    if (!tools || this.isCancelled(generation)) {
      result.cancelled = true
      return result
    }
    result.toolSummary = tools.summary()
    let diagnostic: IDEProblem[] | null = null
    try {
      diagnostic = await this.diagnosePath(path, tools, generation)
    } catch (error) {
      result.failedFiles = 1
      result.failureMessage = this.failureMessage(error as Error)
      return result
    }
    if (this.isCancelled(generation)) {
      result.cancelled = true
      return result
    }
    if (diagnostic === null) {
      result.unavailableMessage = this.unavailableForPath(path, tools)
      return result
    }
    result.checkedFiles = 1
    result.problems = diagnostic
    return result
  }

  async diagnoseProject(rootPath: string): Promise<IDEDiagnosticResult> {
    const generation = ++this.generation
    const result = new IDEDiagnosticResult()
    let tools: IDEDiagnosticTools | null = null
    try {
      tools = await this.probeTools(generation)
    } catch (error) {
      result.failureMessage = this.failureMessage(error as Error)
      return result
    }
    if (!tools || this.isCancelled(generation)) {
      result.cancelled = true
      return result
    }
    result.toolSummary = tools.summary()
    if (result.toolSummary === 'unavailable') {
      result.unavailableMessage = 'No supported compiler, interpreter, or checker is available in the Linux guest.'
      return result
    }

    const queue: ScanDirectory[] = [new ScanDirectory(this.fileSystem.normalizePath(rootPath), 0)]
    while (queue.length > 0 && result.checkedFiles < MAX_PROJECT_FILES) {
      if (this.isCancelled(generation)) {
        result.cancelled = true
        return result
      }
      const directory = queue.shift()
      if (!directory) break
      let entries: IDEFileEntry[] = []
      try {
        entries = await this.fileSystem.listDirectory(directory.path)
      } catch (error) {
        result.skippedDirectories++
        continue
      }
      if (this.isCancelled(generation)) {
        result.cancelled = true
        return result
      }
      for (const entry of entries) {
        if (this.isCancelled(generation)) {
          result.cancelled = true
          return result
        }
        if (entry.type === IDEFileType.DIRECTORY) {
          if (directory.depth < MAX_PROJECT_DEPTH && !this.shouldIgnoreDirectory(entry.path, entry.name, rootPath)) {
            queue.push(new ScanDirectory(entry.path, directory.depth + 1))
          }
          continue
        }
        if (entry.type !== IDEFileType.FILE || entry.size > MAX_SOURCE_FILE_SIZE ||
          !this.hasSupportedExtension(entry.path, tools)) {
          continue
        }
        if (result.checkedFiles >= MAX_PROJECT_FILES) {
          result.truncated = true
          break
        }
        let diagnostics: IDEProblem[] | null = null
        try {
          diagnostics = await this.diagnosePath(entry.path, tools, generation)
        } catch (error) {
          result.failedFiles++
          result.failureMessage = this.failureMessage(error as Error)
          return result
        }
        if (diagnostics !== null) {
          result.checkedFiles++
          for (const problem of diagnostics) {
            result.problems.push(problem)
          }
        }
      }
    }
    if (queue.length > 0 || result.checkedFiles >= MAX_PROJECT_FILES) {
      result.truncated = true
    }
    return result
  }

  private async probeTools(generation: number): Promise<IDEDiagnosticTools | null> {
    const command =
      'for ide_tool in python3 node clang gcc cc sh; do ' +
      'if command -v "$ide_tool" >/dev/null 2>&1; then printf "%s\\n" "$ide_tool"; fi; done'
    const result = await this.runGuestShell(command, 10000, generation)
    if (!result || this.isCancelled(generation)) return null
    const tools = new IDEDiagnosticTools()
    const names = result.output.split('\n')
    tools.python = names.indexOf('python3') !== -1
    tools.node = names.indexOf('node') !== -1
    tools.shell = names.indexOf('sh') !== -1
    if (names.indexOf('clang') !== -1) {
      tools.cCompiler = 'clang'
    } else if (names.indexOf('gcc') !== -1) {
      tools.cCompiler = 'gcc'
    } else if (names.indexOf('cc') !== -1) {
      tools.cCompiler = 'cc'
    }
    return tools
  }

  private async diagnosePath(path: string, tools: IDEDiagnosticTools,
    generation: number): Promise<IDEProblem[] | null> {
    const extension = this.extensionOf(path)
    const quotedPath = this.shellQuote(path)
    let command = ''
    let source = ''
    if ((extension === 'py' || extension === 'pyw') && tools.python) {
      command = 'python3 -c ' + this.shellQuote(
        'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), filename=sys.argv[1])') +
        ' ' + quotedPath
      source = 'python3/ast'
    } else if (extension === 'js' && tools.node) {
      command = 'node --check ' + quotedPath
      source = 'node --check'
    } else if ((extension === 'sh' || extension === 'bash') && tools.shell) {
      command = 'sh -n ' + quotedPath
      source = 'sh -n'
    } else if (this.isCSource(extension) && tools.cCompiler) {
      command = tools.cCompiler + ' -fsyntax-only -Wall -- ' + quotedPath
      source = tools.cCompiler
    } else {
      return null
    }

    const result = await this.runGuestShell(command, 20000, generation)
    if (!result || this.isCancelled(generation)) return []
    if (source === 'python3/ast') return this.parsePython(path, result, source)
    if (source === 'node --check') return this.parseNode(path, result, source)
    if (source === 'sh -n') return this.parseShell(path, result, source)
    return this.parseCompiler(path, result, source)
  }

  private parseCompiler(path: string, result: GuestShellResult, source: string): IDEProblem[] {
    const problems: IDEProblem[] = []
    const lines = result.output.split('\n')
    for (const line of lines) {
      const match = line.match(/^(.+?):(\d+):(\d+):\s*(fatal error|error|warning):\s*(.+)$/)
      if (!match) continue
      const severity = match[4].indexOf('warning') !== -1 ? IDEProblemSeverity.WARNING : IDEProblemSeverity.ERROR
      problems.push(this.createProblem(match[1] || path, parseInt(match[2]), parseInt(match[3]),
        severity, match[5], source))
    }
    this.addFallbackProblem(problems, path, result, source)
    return problems
  }

  private parsePython(path: string, result: GuestShellResult, source: string): IDEProblem[] {
    const problems: IDEProblem[] = []
    if (result.status === 0) return problems
    const lines = result.output.split('\n')
    let lineNumber = 1
    let column = 1
    let message = ''
    for (let index = 0; index < lines.length; index++) {
      const location = lines[index].match(/^\s*File "(.+)", line (\d+)/)
      if (location) {
        lineNumber = parseInt(location[2]) || 1
        if (index + 2 < lines.length) {
          const caret = lines[index + 2].indexOf('^')
          if (caret !== -1) column = Math.max(1, caret - 3)
        }
      }
      if (/^(SyntaxError|IndentationError|TabError):/.test(lines[index].trim())) {
        message = lines[index].trim()
      }
    }
    problems.push(this.createProblem(path, lineNumber, column, IDEProblemSeverity.ERROR,
      message || this.compactOutput(result.output), source))
    return problems
  }

  private parseNode(path: string, result: GuestShellResult, source: string): IDEProblem[] {
    const problems: IDEProblem[] = []
    if (result.status === 0) return problems
    const lines = result.output.split('\n')
    let lineNumber = 1
    let column = 1
    let message = ''
    for (let index = 0; index < lines.length; index++) {
      const location = lines[index].match(/^(.+):(\d+)$/)
      if (location) lineNumber = parseInt(location[2]) || 1
      const caret = lines[index].indexOf('^')
      if (caret !== -1) column = caret + 1
      if (lines[index].trim().startsWith('SyntaxError:')) message = lines[index].trim()
    }
    problems.push(this.createProblem(path, lineNumber, column, IDEProblemSeverity.ERROR,
      message || this.compactOutput(result.output), source))
    return problems
  }

  private parseShell(path: string, result: GuestShellResult, source: string): IDEProblem[] {
    const problems: IDEProblem[] = []
    if (result.status === 0) return problems
    const lines = result.output.split('\n')
    for (const line of lines) {
      const match = line.match(/^(.+?):(?:\s*line\s*)?(\d+):\s*(.+)$/)
      if (match) {
        problems.push(this.createProblem(match[1] || path, parseInt(match[2]), 1,
          IDEProblemSeverity.ERROR, match[3], source))
      }
    }
    this.addFallbackProblem(problems, path, result, source)
    return problems
  }

  private addFallbackProblem(problems: IDEProblem[], path: string, result: GuestShellResult, source: string): void {
    if (result.status !== 0 && problems.length === 0) {
      problems.push(this.createProblem(path, 1, 1, IDEProblemSeverity.ERROR,
        this.compactOutput(result.output), source))
    }
  }

  private createProblem(path: string, line: number, column: number, severity: IDEProblemSeverity,
    message: string, source: string): IDEProblem {
    this.problemSequence++
    return new IDEProblem('problem-' + this.problemSequence, path, line, column, severity,
      message.trim() || 'Diagnostic failed without output', source)
  }

  private compactOutput(output: string): string {
    const compact = output.replace(/\s+/g, ' ').trim()
    return compact.length > 400 ? compact.substring(0, 400) + '…' : compact || 'Diagnostic command failed'
  }

  private unavailableForPath(path: string, tools: IDEDiagnosticTools): string {
    const extension = this.extensionOf(path)
    if (extension === 'py' || extension === 'pyw') return 'Python 检查器不可用（Linux guest 中未找到 python3）。'
    if (extension === 'js') return 'node is unavailable in the Linux guest.'
    if (extension === 'sh' || extension === 'bash') return 'sh is unavailable in the Linux guest.'
    if (this.isCSource(extension)) return 'clang, gcc, and cc are unavailable in the Linux guest.'
    return 'No diagnostic adapter is available for this file type. Detected tools: ' + tools.summary()
  }

  private hasSupportedExtension(path: string, tools: IDEDiagnosticTools): boolean {
    const extension = this.extensionOf(path)
    return ((extension === 'py' || extension === 'pyw') && tools.python) ||
      (extension === 'js' && tools.node) ||
      ((extension === 'sh' || extension === 'bash') && tools.shell) ||
      (this.isCSource(extension) && tools.cCompiler.length > 0)
  }

  private isCSource(extension: string): boolean {
    return extension === 'c' || extension === 'cc' || extension === 'cpp' || extension === 'cxx'
  }

  private extensionOf(path: string): string {
    const dot = path.lastIndexOf('.')
    const slash = path.lastIndexOf('/')
    return dot > slash ? path.substring(dot + 1).toLowerCase() : ''
  }

  private shouldIgnoreDirectory(path: string, name: string, rootPath: string): boolean {
    const ignored = ['.git', '.hg', '.svn', 'node_modules', 'oh_modules', 'vendor', 'build', 'dist',
      'target', '.hvigor', '.cxx', '__pycache__', '.venv', 'venv']
    if (ignored.indexOf(name) !== -1) return true
    if (this.fileSystem.normalizePath(rootPath) === '/') {
      const systemPaths = ['/bin', '/dev', '/etc', '/lib', '/lib64', '/proc', '/run', '/sbin', '/sys', '/usr', '/var']
      return systemPaths.indexOf(path) !== -1
    }
    return false
  }

  private isCancelled(generation: number): boolean {
    return generation !== this.generation
  }

  private async runGuestShell(command: string, timeoutMs: number,
    generation: number): Promise<GuestShellResult | null> {
    if (this.isCancelled(generation)) return null
    const agent: QemuAgent | null = await QemuAgentManager.acquire(DIAGNOSTICS_USER_ID, AgentPriority.NORMAL, 5000)
    if (!agent || this.isCancelled(generation)) {
      if (agent) await QemuAgentManager.release(DIAGNOSTICS_USER_ID)
      if (this.isCancelled(generation)) return null
      throw new Error('Linux guest diagnostic service is unavailable.')
    }
    try {
      const wrapped = '(\n' + command + '\n) 2>&1' +
        '\nide_problem_status=$?' +
        '\nprintf \'\\n' + DIAGNOSTICS_STATUS_MARKER + '%s\' "$ide_problem_status"'
      const raw = await agent.execAndGetOutput('/bin/sh', ['-c', wrapped], timeoutMs)
      if (this.isCancelled(generation)) return null
      if (raw === null) {
        throw new Error('Linux guest did not return a diagnostic command result.')
      }
      const markerIndex = raw.lastIndexOf('\n' + DIAGNOSTICS_STATUS_MARKER)
      if (markerIndex === -1) {
        throw new Error('Linux guest returned an incomplete diagnostic command result.')
      }
      const statusText = raw.substring(markerIndex + DIAGNOSTICS_STATUS_MARKER.length + 1).trim()
      const status = parseInt(statusText)
      if (Number.isNaN(status)) {
        throw new Error('Linux guest returned an invalid diagnostic exit status.')
      }
      return {
        output: raw.substring(0, markerIndex),
        status
      }
    } finally {
      await QemuAgentManager.release(DIAGNOSTICS_USER_ID)
    }
  }

  private failureMessage(error: Error): string {
    const message = error && error.message ? error.message.trim() : ''
    return message || 'The diagnostic command failed.'
  }

  private shellQuote(value: string): string {
    return '\'' + value.replace(/\'/g, '\'"\'"\'') + '\''
  }
}
