import { terminalOutputBridge } from '../../lib/TerminalOutputBridge'
import IDETerminalRunner from '../run/IDETerminalRunner'
import { AgentCommandExecutionResult, AgentCommandExecutor } from './CodingAgentContracts'

const AGENT_COMMAND_SUBSCRIBER = 'IDE.CodexAgent.CommandRunner'
const AGENT_COMMAND_TIMEOUT_MS = 120000

/** Runs an approved command through the existing visible Terminal input path. */
export default class IDEAgentCommandRunner implements AgentCommandExecutor {
  private terminalRunner: IDETerminalRunner
  private sequence: number = 0
  private busy: boolean = false

  constructor(terminalRunner: IDETerminalRunner) {
    this.terminalRunner = terminalRunner
  }

  async executeApprovedCommand(command: string): Promise<AgentCommandExecutionResult> {
    if (this.busy) throw new Error('AGENT_COMMAND_ALREADY_RUNNING')
    this.busy = true
    this.sequence++
    const token = Date.now() + '_' + this.sequence
    const outMarker = '__HISH_AGENT_STDOUT_' + token + '__'
    const errMarker = '__HISH_AGENT_STDERR_' + token + '__'
    const exitMarker = '__HISH_AGENT_EXIT_' + token + '__'
    let output = ''

    return new Promise<AgentCommandExecutionResult>((resolve, reject): void => {
      let settled = false
      const finish = (result: AgentCommandExecutionResult | null, error: Error | null): void => {
        if (settled) return
        settled = true
        this.busy = false
        terminalOutputBridge.unsubscribe(AGENT_COMMAND_SUBSCRIBER)
        clearTimeout(timeoutId)
        if (error) reject(error)
        else if (result) resolve(result)
      }
      const listener = (chunk: string): void => {
        output += chunk
        const parsed = this.tryParse(output, outMarker, errMarker, exitMarker)
        if (parsed) finish(parsed, null)
      }
      terminalOutputBridge.subscribe(AGENT_COMMAND_SUBSCRIBER, listener)
      const timeoutId = setTimeout((): void => {
        finish(null, new Error('AGENT_COMMAND_TIMEOUT'))
      }, AGENT_COMMAND_TIMEOUT_MS)
      try {
        this.terminalRunner.send(this.buildWrappedCommand(command, token, outMarker, errMarker, exitMarker))
      } catch (error) {
        finish(null, error as Error)
      }
    })
  }

  private buildWrappedCommand(command: string, token: string, outMarker: string,
    errMarker: string, exitMarker: string): string {
    const outPath = '/tmp/.hish-agent-' + token + '.out'
    const errPath = '/tmp/.hish-agent-' + token + '.err'
    return 'ide_agent_out=' + this.shellQuote(outPath) + '; ' +
      'ide_agent_err=' + this.shellQuote(errPath) + '; ' +
      'sh -c ' + this.shellQuote(command) + ' >"$ide_agent_out" 2>"$ide_agent_err"; ' +
      'ide_agent_status=$?; ' +
      'printf "\\n' + outMarker + '\\n"; cat "$ide_agent_out"; ' +
      'printf "\\n' + errMarker + '\\n"; cat "$ide_agent_err"; ' +
      'printf "\\n' + exitMarker + '%s\\n" "$ide_agent_status"; ' +
      'rm -f "$ide_agent_out" "$ide_agent_err"'
  }

  private tryParse(output: string, outMarker: string, errMarker: string,
    exitMarker: string): AgentCommandExecutionResult | null {
    const normalized = output.replace(/\r/g, '')
    const outStart = normalized.lastIndexOf('\n' + outMarker + '\n')
    const errStart = normalized.lastIndexOf('\n' + errMarker + '\n')
    const exitStart = normalized.lastIndexOf('\n' + exitMarker)
    if (outStart === -1 || errStart <= outStart || exitStart <= errStart) return null
    const stdout = normalized.substring(outStart + outMarker.length + 2, errStart)
    const stderr = normalized.substring(errStart + errMarker.length + 2, exitStart)
    const statusStart = exitStart + exitMarker.length + 1
    const statusEnd = normalized.indexOf('\n', statusStart)
    if (statusEnd === -1) return null
    const exitCode = parseInt(normalized.substring(statusStart, statusEnd).trim())
    if (Number.isNaN(exitCode)) return null
    return new AgentCommandExecutionResult(stdout, stderr, exitCode)
  }

  private shellQuote(value: string): string {
    return '\'' + value.replace(/\'/g, '\'"\'"\'') + '\''
  }
}
