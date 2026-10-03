import { util } from '@kit.ArkTS'
import QemuAgent from '../../lib/QemuAgent'
import { AgentPriority, QemuAgentManager } from '../../lib/QemuAgentManager'
import { IDEFileEntry, IDEFileSystemError, IDEFileType } from './IDEFileSystemTypes'

interface ShellResult {
  output: string
  status: number
}

const AGENT_USER_ID = 'IDEFileSystem'
const STATUS_MARKER = '__HISH_IDE_STATUS__'
const MAX_BINARY_READ_LENGTH = 64 * 1024

/**
 * Thin IDE-facing adapter for files stored inside the Linux guest.
 *
 * The adapter deliberately uses QemuAgent's existing guest command channel so
 * the IDE does not duplicate or alter the VM, Native, QGA, or Terminal layers.
 */
export default class IDEFileSystem {
  async resolveHomeDirectory(): Promise<string> {
    const result = await this.runShell('resolve home directory', 'printf \'%s\' "${HOME:-/root}"')
    const path = result.output.trim()
    return path.startsWith('/') ? this.normalizePath(path) : '/root'
  }

  async listDirectory(path: string): Promise<IDEFileEntry[]> {
    const directory = this.normalizePath(path)
    const quotedDirectory = this.shellQuote(directory)
    const script =
      'ide_dir=' + quotedDirectory + '\n' +
      '[ -d "$ide_dir" ] || exit 20\n' +
      '[ -r "$ide_dir" ] && [ -x "$ide_dir" ] || exit 13\n' +
      'for ide_item in "$ide_dir"/.[!.]* "$ide_dir"/..?* "$ide_dir"/*; do\n' +
      '  if [ ! -e "$ide_item" ] && [ ! -L "$ide_item" ]; then continue; fi\n' +
      '  ide_name=${ide_item##*/}\n' +
      '  ide_name_hex=$(printf \'%s\' "$ide_name" | od -An -tx1 | tr -d \' \\n\')\n' +
      '  if [ -L "$ide_item" ]; then\n' +
      '    if [ -d "$ide_item" ]; then ide_type=d; else ide_type=l; fi\n' +
      '    ide_size=0\n' +
      '  elif [ -d "$ide_item" ]; then\n' +
      '    ide_type=d\n' +
      '    ide_size=0\n' +
      '  elif [ -f "$ide_item" ]; then\n' +
      '    ide_type=f\n' +
      '    ide_size=$(stat -c %s "$ide_item" 2>/dev/null || printf \'0\')\n' +
      '  else\n' +
      '    ide_type=o\n' +
      '    ide_size=0\n' +
      '  fi\n' +
      '  printf \'%s\\t%s\\t%s\\n\' "$ide_name_hex" "$ide_type" "$ide_size"\n' +
      'done'

    const result = await this.runShell('list directory', script, 15000)
    const entries: IDEFileEntry[] = []
    const lines = result.output.split('\n')
    for (const line of lines) {
      if (!line) {
        continue
      }
      const fields = line.split('\t')
      if (fields.length !== 3) {
        continue
      }
      const name = this.decodeHex(fields[0])
      if (!name) {
        continue
      }
      entries.push({
        name,
        path: this.joinPath(directory, name),
        type: this.parseFileType(fields[1]),
        size: parseInt(fields[2]) || 0
      })
    }

    entries.sort((left: IDEFileEntry, right: IDEFileEntry): number => {
      const leftDirectory = left.type === IDEFileType.DIRECTORY
      const rightDirectory = right.type === IDEFileType.DIRECTORY
      if (leftDirectory !== rightDirectory) {
        return leftDirectory ? -1 : 1
      }
      return left.name.localeCompare(right.name)
    })
    return entries
  }

  async readFile(path: string): Promise<string> {
    const filePath = this.normalizePath(path)
    const quotedPath = this.shellQuote(filePath)
    const script = '[ -f ' + quotedPath + ' ] || exit 21\ncat ' + quotedPath
    const result = await this.runShell('read file', script, 15000)
    return result.output
  }

  /**
   * Reads an exact byte range without decoding guest data as UTF-8.
   * The QGA text channel carries only Base64 ASCII; callers receive the
   * original 00-FF byte values, including NUL.
   */
  async readBinary(path: string, offset: number, length: number): Promise<Uint8Array> {
    if (!Number.isFinite(offset) || !Number.isInteger(offset) || offset < 0 ||
      !Number.isFinite(length) || !Number.isInteger(length) || length < 0 ||
      length > MAX_BINARY_READ_LENGTH) {
      throw new IDEFileSystemError('read binary',
        'Binary reads require a non-negative offset and length up to ' + MAX_BINARY_READ_LENGTH + ' bytes')
    }
    if (length === 0) return new Uint8Array(0)
    const target = this.normalizePath(path)
    const quotedTarget = this.shellQuote(target)
    const script =
      '[ -f ' + quotedTarget + ' ] || exit 21\n' +
      'dd if=' + quotedTarget + ' bs=1 skip=' + offset + ' count=' + length +
      ' 2>/dev/null | base64 | tr -d \'\\n\''
    const result = await this.runShell('read binary', script, 20000)
    const encoded = result.output.trim()
    if (!encoded) return new Uint8Array(0)
    try {
      return new util.Base64Helper().decodeSync(encoded)
    } catch (error) {
      throw new IDEFileSystemError('read binary', 'Linux VM returned invalid binary transfer data')
    }
  }

  /** Atomically replaces one byte range without text decoding or truncating the file. */
  async writeBinary(path: string, offset: number, bytes: Uint8Array): Promise<void> {
    if (!Number.isFinite(offset) || !Number.isInteger(offset) || offset < 0 ||
      bytes.byteLength > MAX_BINARY_READ_LENGTH) {
      throw new IDEFileSystemError('write binary',
        'Binary writes require a non-negative offset and at most ' + MAX_BINARY_READ_LENGTH + ' bytes')
    }
    if (bytes.byteLength === 0) return
    const target = this.normalizePath(path)
    if (target === '/') throw new IDEFileSystemError('write binary', 'The Linux root directory is not a file')
    const quotedTarget = this.shellQuote(target)
    const encoded = new util.Base64Helper().encodeToStringSync(bytes)
    const quotedEncoded = this.shellQuote(encoded)
    const script =
      '[ -f ' + quotedTarget + ' ] || exit 21\n' +
      'ide_target=' + quotedTarget + '\n' +
      'ide_temp="${ide_target}.hish-binary-$$"\n' +
      'cp -p "$ide_target" "$ide_temp" || exit $?\n' +
      'printf \'%s\' ' + quotedEncoded + ' | base64 -d | ' +
      'dd of="$ide_temp" bs=1 seek=' + offset + ' conv=notrunc 2>/dev/null\n' +
      'ide_write_status=$?\n' +
      'if [ "$ide_write_status" -eq 0 ]; then mv -f "$ide_temp" "$ide_target"; ' +
      'else rm -f "$ide_temp"; fi\n' +
      'exit "$ide_write_status"'
    await this.runShell('write binary', script, 20000)
  }

  async createFile(parentPath: string, name: string): Promise<string> {
    const target = this.joinPath(this.normalizePath(parentPath), this.validateName(name))
    const quotedTarget = this.shellQuote(target)
    const script =
      'if [ -e ' + quotedTarget + ' ] || [ -L ' + quotedTarget + ' ]; then exit 17; fi\n' +
      'umask 077\n' +
      ': > ' + quotedTarget
    await this.runShell('create file', script)
    return target
  }

  async createDirectory(parentPath: string, name: string): Promise<string> {
    const target = this.joinPath(this.normalizePath(parentPath), this.validateName(name))
    const quotedTarget = this.shellQuote(target)
    const script =
      'if [ -e ' + quotedTarget + ' ] || [ -L ' + quotedTarget + ' ]; then exit 17; fi\n' +
      'mkdir ' + quotedTarget
    await this.runShell('create directory', script)
    return target
  }

  async deleteEntry(path: string): Promise<void> {
    const target = this.normalizePath(path)
    if (target === '/') {
      throw new IDEFileSystemError('delete entry', 'Refusing to delete the Linux root directory')
    }
    const quotedTarget = this.shellQuote(target)
    const script =
      'if [ -d ' + quotedTarget + ' ] && [ ! -L ' + quotedTarget + ' ]; then\n' +
      '  rm -rf ' + quotedTarget + '\n' +
      'else\n' +
      '  rm -f ' + quotedTarget + '\n' +
      'fi'
    await this.runShell('delete entry', script, 15000)
  }

  async renameEntry(path: string, newName: string): Promise<string> {
    const source = this.normalizePath(path)
    if (source === '/') {
      throw new IDEFileSystemError('rename entry', 'Refusing to rename the Linux root directory')
    }
    const target = this.joinPath(this.parentPath(source), this.validateName(newName))
    const quotedSource = this.shellQuote(source)
    const quotedTarget = this.shellQuote(target)
    const script =
      'if [ -e ' + quotedTarget + ' ] || [ -L ' + quotedTarget + ' ]; then exit 17; fi\n' +
      'mv ' + quotedSource + ' ' + quotedTarget
    await this.runShell('rename entry', script, 15000)
    return target
  }

  async writeFile(path: string, content: string): Promise<void> {
    const target = this.normalizePath(path)
    if (target === '/') {
      throw new IDEFileSystemError('write file', 'The Linux root directory is not a file')
    }
    const quotedTarget = this.shellQuote(target)
    const encodedContent = this.encodeOctal(content)
    const quotedContent = this.shellQuote(encodedContent)
    const script =
      'ide_target=' + quotedTarget + '\n' +
      'ide_parent=${ide_target%/*}\n' +
      '[ -n "$ide_parent" ] || ide_parent=/\n' +
      '[ -d "$ide_parent" ] || exit 20\n' +
      'ide_temp="${ide_target}.hish-ide-$$"\n' +
      'umask 077\n' +
      'printf \'%b\' ' + quotedContent + ' > "$ide_temp" && mv -f "$ide_temp" "$ide_target"\n' +
      'ide_write_status=$?\n' +
      'if [ "$ide_write_status" -ne 0 ]; then rm -f "$ide_temp"; fi\n' +
      'exit "$ide_write_status"'
    await this.runShell('write file', script, 20000)
  }

  normalizePath(path: string): string {
    if (path.indexOf('\u0000') !== -1 || !path.startsWith('/')) {
      throw new IDEFileSystemError('normalize path', 'Linux paths must be absolute')
    }
    const normalizedParts: string[] = []
    const parts = path.split('/')
    for (const part of parts) {
      if (!part || part === '.') {
        continue
      }
      if (part === '..') {
        if (normalizedParts.length > 0) {
          normalizedParts.pop()
        }
        continue
      }
      normalizedParts.push(part)
    }
    return '/' + normalizedParts.join('/')
  }

  parentPath(path: string): string {
    const normalized = this.normalizePath(path)
    if (normalized === '/') {
      return '/'
    }
    const separator = normalized.lastIndexOf('/')
    return separator <= 0 ? '/' : normalized.substring(0, separator)
  }

  baseName(path: string): string {
    const normalized = this.normalizePath(path)
    if (normalized === '/') {
      return '/'
    }
    return normalized.substring(normalized.lastIndexOf('/') + 1)
  }

  private joinPath(parentPath: string, name: string): string {
    return parentPath === '/' ? '/' + name : parentPath + '/' + name
  }

  private validateName(name: string): string {
    const normalizedName = name.trim()
    if (!normalizedName || normalizedName === '.' || normalizedName === '..' ||
      normalizedName.indexOf('/') !== -1 || normalizedName.indexOf('\u0000') !== -1 ||
      normalizedName.indexOf('\n') !== -1 || normalizedName.indexOf('\r') !== -1 ||
      normalizedName.indexOf('\t') !== -1) {
      throw new IDEFileSystemError('validate name', 'Invalid Linux file name')
    }
    return normalizedName
  }

  private async runShell(operation: string, script: string, timeoutMs: number = 10000): Promise<ShellResult> {
    const agent: QemuAgent | null = await QemuAgentManager.acquire(AGENT_USER_ID, AgentPriority.NORMAL, 5000)
    if (!agent) {
      throw new IDEFileSystemError(operation, 'Linux VM file service is unavailable')
    }

    try {
      const wrappedScript = '(\n' + script + '\n)' +
        '\nide_operation_status=$?' +
        '\nprintf \'\\n' + STATUS_MARKER + '%s\' "$ide_operation_status"'
      const rawOutput = await agent.execAndGetOutput('/bin/sh', ['-c', wrappedScript], timeoutMs)
      if (rawOutput === null) {
        throw new IDEFileSystemError(operation, 'Linux VM did not return a file operation result')
      }
      const markerIndex = rawOutput.lastIndexOf('\n' + STATUS_MARKER)
      if (markerIndex === -1) {
        throw new IDEFileSystemError(operation, 'Linux VM returned an incomplete file operation result')
      }
      const statusText = rawOutput.substring(markerIndex + STATUS_MARKER.length + 1).trim()
      const status = parseInt(statusText)
      const output = rawOutput.substring(0, markerIndex)
      if (status !== 0) {
        throw new IDEFileSystemError(operation, operation + ' failed in Linux (status ' + status + ')', status)
      }
      return { output, status }
    } finally {
      await QemuAgentManager.release(AGENT_USER_ID)
    }
  }

  private shellQuote(value: string): string {
    return '\'' + value.replace(/\'/g, '\'"\'"\'') + '\''
  }

  private parseFileType(value: string): IDEFileType {
    if (value === 'd') {
      return IDEFileType.DIRECTORY
    }
    if (value === 'f') {
      return IDEFileType.FILE
    }
    if (value === 'l') {
      return IDEFileType.SYMBOLIC_LINK
    }
    return IDEFileType.OTHER
  }

  private decodeHex(value: string): string {
    if (!value || value.length % 2 !== 0) {
      return ''
    }
    const bytes = new Uint8Array(value.length / 2)
    for (let index = 0; index < value.length; index += 2) {
      const byteValue = parseInt(value.substring(index, index + 2), 16)
      if (Number.isNaN(byteValue)) {
        return ''
      }
      bytes[index / 2] = byteValue
    }
    const decoder = util.TextDecoder.create('utf-8')
    return decoder.decodeToString(bytes)
  }

  private encodeOctal(value: string): string {
    const encoder = util.TextEncoder.create()
    const bytes = encoder.encodeInto(value)
    let result = ''
    for (let index = 0; index < bytes.length; index++) {
      let octal = bytes[index].toString(8)
      while (octal.length < 3) {
        octal = '0' + octal
      }
      result += '\\0' + octal
    }
    return result
  }
}
