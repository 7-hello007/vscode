import QemuAgent from '../../lib/QemuAgent'
import { AgentPriority, QemuAgentManager } from '../../lib/QemuAgentManager'
import IDEFileSystem from '../filesystem/IDEFileSystem'
import { IDEFileEntry, IDEFileType } from '../filesystem/IDEFileSystemTypes'
import {
  IDEDiagnosticEntry,
  IDEDiagnosticPlugin,
  IDEDiagnosticRuntime,
  IDEGuestDiagnosticResult
} from '../plugin/IDEDiagnosticPluginContracts'
import { IDEPluginCheckerStatus } from '../plugin/IDEPluginContracts'
import IDEPluginRegistry from '../plugin/IDEPluginRegistry'
import { IDEDiagnosticResult, IDEProblem } from './IDEProblemContracts'

type DiagnosticExecuteHandler = (command: string, timeoutMs: number) => Promise<IDEGuestDiagnosticResult | null>
type DiagnosticQuoteHandler = (value: string) => string

class ProblemsDiagnosticRuntime implements IDEDiagnosticRuntime {
  private executeHandler: DiagnosticExecuteHandler
  private quoteHandler: DiagnosticQuoteHandler

  constructor(executeHandler: DiagnosticExecuteHandler, quoteHandler: DiagnosticQuoteHandler) {
    this.executeHandler = executeHandler
    this.quoteHandler = quoteHandler
  }

  async execute(command: string, timeoutMs: number): Promise<IDEGuestDiagnosticResult | null> {
    return await this.executeHandler(command, timeoutMs)
  }

  quote(value: string): string {
    return this.quoteHandler(value)
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

/** Language-neutral Problems coordinator. Language commands and parsers live in diagnostic plugins. */
export default class IDEProblemsService {
  private fileSystem: IDEFileSystem
  private pluginRegistry: IDEPluginRegistry
  private generation: number = 0
  private problemSequence: number = 0

  constructor(fileSystem: IDEFileSystem, pluginRegistry: IDEPluginRegistry) {
    this.fileSystem = fileSystem
    this.pluginRegistry = pluginRegistry
  }

  cancel(): void {
    this.generation++
  }

  async refreshPluginAvailability(): Promise<void> {
    const generation = this.generation
    const runtime = this.createRuntime(generation)
    const plugins = this.pluginRegistry.listDiagnosticPlugins(true)
    for (const plugin of plugins) {
      if (this.isCancelled(generation)) return
      try {
        await plugin.probe(runtime)
      } catch (error) {
        plugin.checkerStatus = IDEPluginCheckerStatus.UNAVAILABLE
        plugin.checkerMessage = this.failureMessage(error as Error)
      }
    }
  }

  async diagnoseFile(path: string): Promise<IDEDiagnosticResult> {
    const generation = ++this.generation
    const result = new IDEDiagnosticResult()
    const plugin = this.pluginRegistry.findDiagnosticPlugin(path, true)
    if (!plugin) {
      result.unavailableMessage = 'No diagnostic plugin is registered for this file type.'
      return result
    }
    if (!this.pluginRegistry.isEnabled(plugin.manifest.id)) {
      result.unavailableMessage = plugin.manifest.name + ' 插件未启用'
      return result
    }

    const runtime = this.createRuntime(generation)
    try {
      const available = await plugin.probe(runtime)
      if (this.isCancelled(generation)) {
        result.cancelled = true
        return result
      }
      result.toolSummary = plugin.manifest.name + ' / ' + plugin.diagnosticSource()
      if (!available) {
        result.unavailableMessage = plugin.unavailableMessage()
        return result
      }
      const diagnostics = await plugin.diagnose(path, runtime)
      if (this.isCancelled(generation)) {
        result.cancelled = true
        return result
      }
      if (!diagnostics) {
        result.failedFiles = 1
        result.failureMessage = 'The diagnostic plugin did not return a result.'
        return result
      }
      result.checkedFiles = 1
      result.problems = this.toProblems(diagnostics)
    } catch (error) {
      result.failedFiles = 1
      result.failureMessage = this.failureMessage(error as Error)
    }
    return result
  }

  async diagnoseProject(rootPath: string): Promise<IDEDiagnosticResult> {
    const generation = ++this.generation
    const result = new IDEDiagnosticResult()
    const runtime = this.createRuntime(generation)
    const plugins = this.pluginRegistry.listDiagnosticPlugins(true)
    if (plugins.length === 0) {
      result.unavailableMessage = 'No diagnostic plugin is enabled.'
      return result
    }

    const availablePlugins: IDEDiagnosticPlugin[] = []
    for (const plugin of plugins) {
      try {
        if (await plugin.probe(runtime)) {
          availablePlugins.push(plugin)
        }
      } catch (error) {
        plugin.checkerStatus = IDEPluginCheckerStatus.UNAVAILABLE
        plugin.checkerMessage = this.failureMessage(error as Error)
      }
      if (this.isCancelled(generation)) {
        result.cancelled = true
        return result
      }
    }
    if (availablePlugins.length === 0) {
      result.unavailableMessage = this.unavailablePluginSummary(plugins)
      return result
    }
    result.toolSummary = this.pluginSummary(availablePlugins)

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
        if (entry.type !== IDEFileType.FILE || entry.size > MAX_SOURCE_FILE_SIZE) continue
        const plugin = this.findAvailablePlugin(entry.path, availablePlugins)
        if (!plugin) continue
        if (result.checkedFiles >= MAX_PROJECT_FILES) {
          result.truncated = true
          break
        }
        try {
          const diagnostics = await plugin.diagnose(entry.path, runtime)
          if (!diagnostics) {
            result.failedFiles++
            result.failureMessage = plugin.manifest.name + ' diagnostic did not return a result.'
            return result
          }
          result.checkedFiles++
          const problems = this.toProblems(diagnostics)
          for (const problem of problems) result.problems.push(problem)
        } catch (error) {
          result.failedFiles++
          result.failureMessage = this.failureMessage(error as Error)
          return result
        }
      }
    }
    if (queue.length > 0 || result.checkedFiles >= MAX_PROJECT_FILES) result.truncated = true
    return result
  }

  private createRuntime(generation: number): IDEDiagnosticRuntime {
    return new ProblemsDiagnosticRuntime(
      async (command: string, timeoutMs: number): Promise<IDEGuestDiagnosticResult | null> =>
        await this.runGuestShell(command, timeoutMs, generation),
      (value: string): string => this.shellQuote(value))
  }

  private toProblems(diagnostics: IDEDiagnosticEntry[]): IDEProblem[] {
    const problems: IDEProblem[] = []
    for (const diagnostic of diagnostics) {
      this.problemSequence++
      problems.push(new IDEProblem('problem-' + this.problemSequence, diagnostic.filePath,
        diagnostic.line, diagnostic.column, diagnostic.severity,
        diagnostic.message.trim() || 'Diagnostic failed without output', diagnostic.source))
    }
    return problems
  }

  private findAvailablePlugin(path: string, plugins: IDEDiagnosticPlugin[]): IDEDiagnosticPlugin | null {
    for (const plugin of plugins) {
      if (plugin.supportsFile(path)) return plugin
    }
    return null
  }

  private pluginSummary(plugins: IDEDiagnosticPlugin[]): string {
    const names: string[] = []
    for (const plugin of plugins) names.push(plugin.manifest.name + ' / ' + plugin.diagnosticSource())
    return names.join(', ')
  }

  private unavailablePluginSummary(plugins: IDEDiagnosticPlugin[]): string {
    const messages: string[] = []
    for (const plugin of plugins) messages.push(plugin.unavailableMessage())
    return messages.join('; ') || 'No diagnostic checker is available.'
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
    generation: number): Promise<IDEGuestDiagnosticResult | null> {
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
      if (raw === null) throw new Error('Linux guest did not return a diagnostic command result.')
      const markerIndex = raw.lastIndexOf('\n' + DIAGNOSTICS_STATUS_MARKER)
      if (markerIndex === -1) throw new Error('Linux guest returned an incomplete diagnostic command result.')
      const statusText = raw.substring(markerIndex + DIAGNOSTICS_STATUS_MARKER.length + 1).trim()
      const status = parseInt(statusText)
      if (Number.isNaN(status)) throw new Error('Linux guest returned an invalid diagnostic exit status.')
      return { output: raw.substring(0, markerIndex), status }
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
