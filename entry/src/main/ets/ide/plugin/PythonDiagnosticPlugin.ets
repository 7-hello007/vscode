import { IDEProblemSeverity } from '../problems/IDEProblemContracts'
import {
  IDEDiagnosticEntry,
  IDEDiagnosticPlugin,
  IDEDiagnosticRuntime,
  IDEGuestDiagnosticResult
} from './IDEDiagnosticPluginContracts'
import {
  IDEPluginCapability,
  IDEPluginCheckerStatus,
  IDEPluginContext,
  IDEPluginManifest,
  IDEPluginType
} from './IDEPluginContracts'

const PYTHON_SOURCE = 'python3/ast'

export default class PythonDiagnosticPlugin implements IDEDiagnosticPlugin {
  manifest: IDEPluginManifest = {
    id: 'hish.python',
    name: 'Python',
    version: '1.0.0',
    description: '使用 HiSH Linux guest 中的 python3 提供 Python 语言诊断。',
    type: IDEPluginType.LANGUAGE_DIAGNOSTIC,
    capabilities: [IDEPluginCapability.LANGUAGE, IDEPluginCapability.DIAGNOSTIC]
  }
  checkerStatus: IDEPluginCheckerStatus = IDEPluginCheckerStatus.UNKNOWN
  checkerMessage: string = 'Python 检查器状态尚未确认'
  private active: boolean = false

  activate(context: IDEPluginContext): void {
    this.active = true
    this.checkerStatus = IDEPluginCheckerStatus.UNKNOWN
    this.checkerMessage = 'Python 检查器状态尚未确认'
  }

  deactivate(): void {
    this.active = false
    this.checkerStatus = IDEPluginCheckerStatus.UNAVAILABLE
    this.checkerMessage = 'Python 插件未启用'
  }

  supportsFile(path: string): boolean {
    const extension = this.extensionOf(path)
    return extension === 'py' || extension === 'pyw'
  }

  async probe(runtime: IDEDiagnosticRuntime): Promise<boolean> {
    if (!this.active) {
      this.deactivate()
      return false
    }
    const result = await runtime.execute('command -v python3 >/dev/null 2>&1', 10000)
    if (!result) {
      this.checkerStatus = IDEPluginCheckerStatus.UNAVAILABLE
      this.checkerMessage = 'Python 检查器不可用'
      return false
    }
    if (result.status === 0) {
      this.checkerStatus = IDEPluginCheckerStatus.AVAILABLE
      this.checkerMessage = 'Python 检查器可用'
      return true
    }
    this.checkerStatus = IDEPluginCheckerStatus.UNAVAILABLE
    this.checkerMessage = 'Python 检查器不可用'
    return false
  }

  async diagnose(path: string, runtime: IDEDiagnosticRuntime): Promise<IDEDiagnosticEntry[] | null> {
    const command = 'python3 -c ' + runtime.quote(
      'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), filename=sys.argv[1])') +
      ' ' + runtime.quote(path)
    const result = await runtime.execute(command, 20000)
    if (!result) return null
    return this.parse(path, result)
  }

  diagnosticSource(): string {
    return PYTHON_SOURCE
  }

  unavailableMessage(): string {
    return this.active ? 'Python 检查器不可用' : 'Python 插件未启用'
  }

  private parse(path: string, result: IDEGuestDiagnosticResult): IDEDiagnosticEntry[] {
    const diagnostics: IDEDiagnosticEntry[] = []
    if (result.status === 0) return diagnostics
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
    diagnostics.push(new IDEDiagnosticEntry(path, lineNumber, column, IDEProblemSeverity.ERROR,
      message || this.compactOutput(result.output), PYTHON_SOURCE))
    return diagnostics
  }

  private compactOutput(output: string): string {
    const compact = output.replace(/\s+/g, ' ').trim()
    return compact.length > 400 ? compact.substring(0, 400) + '…' : compact || 'Python diagnostic failed'
  }

  private extensionOf(path: string): string {
    const dot = path.lastIndexOf('.')
    const slash = path.lastIndexOf('/')
    return dot > slash ? path.substring(dot + 1).toLowerCase() : ''
  }
}
