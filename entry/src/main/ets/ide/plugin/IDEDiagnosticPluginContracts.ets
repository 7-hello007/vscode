import { IDEProblemSeverity } from '../problems/IDEProblemContracts'
import { IDEPlugin } from './IDEPluginContracts'

export interface IDEGuestDiagnosticResult {
  output: string
  status: number
}

/** Guest execution surface supplied by Problems Core to diagnostic plugins. */
export interface IDEDiagnosticRuntime {
  execute(command: string, timeoutMs: number): Promise<IDEGuestDiagnosticResult | null>
  quote(value: string): string
}

/** Parser output without UI identity; Problems Core assigns stable item ids. */
export class IDEDiagnosticEntry {
  filePath: string
  line: number
  column: number
  severity: IDEProblemSeverity
  message: string
  source: string

  constructor(filePath: string, line: number, column: number, severity: IDEProblemSeverity,
    message: string, source: string) {
    this.filePath = filePath
    this.line = line
    this.column = column
    this.severity = severity
    this.message = message
    this.source = source
  }
}

/** Language diagnostics extension point used by Problems Core. */
export interface IDEDiagnosticPlugin extends IDEPlugin {
  supportsFile(path: string): boolean
  probe(runtime: IDEDiagnosticRuntime): Promise<boolean>
  diagnose(path: string, runtime: IDEDiagnosticRuntime): Promise<IDEDiagnosticEntry[] | null>
  diagnosticSource(): string
  unavailableMessage(): string
}
