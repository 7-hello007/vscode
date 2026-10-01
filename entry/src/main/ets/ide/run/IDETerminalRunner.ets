import napi from 'libentry.so'
import stringToArrayBuffer from '../../lib/stringToArrayBuffer'

/**
 * IDE-only adapter that submits run commands through HiSH's existing terminal
 * input channel. It does not create another shell or bypass WebTerminal.
 */
export default class IDETerminalRunner {
  buildCommand(path: string): string | null {
    const name = this.baseName(path)
    const directory = this.parentPath(path)
    const lowerName = name.toLowerCase()
    let runCommand = ''

    if (lowerName.endsWith('.py')) {
      runCommand = 'python3 ' + this.shellQuote(name)
    } else if (lowerName.endsWith('.sh')) {
      runCommand = 'sh ' + this.shellQuote(name)
    } else {
      return null
    }

    return 'cd ' + this.shellQuote(directory) + ' && ' + runCommand
  }

  send(command: string): void {
    if (!command) {
      return
    }
    napi.sendInput(stringToArrayBuffer(command + '\r'))
  }

  private parentPath(path: string): string {
    const separator = path.lastIndexOf('/')
    return separator <= 0 ? '/' : path.substring(0, separator)
  }

  private baseName(path: string): string {
    return path.substring(path.lastIndexOf('/') + 1)
  }

  private shellQuote(value: string): string {
    return '\'' + value.replace(/\'/g, '\'"\'"\'') + '\''
  }
}
