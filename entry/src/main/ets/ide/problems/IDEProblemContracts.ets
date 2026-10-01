export enum IDEProblemSeverity {
  ERROR = 0,
  WARNING = 1
}

export class IDEProblem {
  id: string
  filePath: string
  line: number
  column: number
  severity: IDEProblemSeverity
  message: string
  source: string

  constructor(id: string, filePath: string, line: number, column: number,
    severity: IDEProblemSeverity, message: string, source: string) {
    this.id = id
    this.filePath = filePath
    this.line = Math.max(1, line)
    this.column = Math.max(1, column)
    this.severity = severity
    this.message = message
    this.source = source
  }
}

export class IDEDiagnosticResult {
  problems: IDEProblem[] = []
  checkedFiles: number = 0
  failedFiles: number = 0
  skippedDirectories: number = 0
  truncated: boolean = false
  cancelled: boolean = false
  unavailableMessage: string = ''
  failureMessage: string = ''
  toolSummary: string = ''
}
