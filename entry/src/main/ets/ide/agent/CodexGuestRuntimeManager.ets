import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import nativeRuntime from 'libentry.so'
import appOption from '../../model/appOption'
import QemuAgentManager, { AgentPriority } from '../../lib/QemuAgentManager'
import CodexJsonlIpc from './CodexJsonlIpc'

const RUNTIME_OWNER = 'IDE.CodexGuestRuntime'
const CODEX_VERSION = '0.160.0'
const BINARY_NAME = 'codex-' + CODEX_VERSION
const EXPECTED_SIZE = 248966648
const GUEST_BINARY = '/mnt/share/.hish-runtime/' + BINARY_NAME
const GUEST_CHANNEL = '/dev/virtio-ports/dev.hish.codex'
const GUEST_STDERR = '/tmp/hish-codex-app-server.log'
const DOMAIN = 0x0000

/** Installs the verified official binary into the existing shared folder and
 * starts app-server with stdio bound exclusively to dev.hish.codex. */
export default class CodexGuestRuntimeManager {
  private context: common.UIAbilityContext
  private processId: number = 0
  private ipc: CodexJsonlIpc | null = null

  constructor(context: common.UIAbilityContext) {
    this.context = context
  }

  async start(accessToken: string): Promise<CodexJsonlIpc> {
    if (!accessToken) throw new Error('CODEX_ACCESS_TOKEN_MISSING')
    await this.stop()
    await this.prepareBinary()
    // QEMU owns the host-side listening socket. Connect it before opening the
    // guest virtio port so app-server cannot observe an initial stdin EOF and
    // exit before the host JSONL client is attached.
    const appTempDir = AppStorage.get(appOption.appTempDir) as string
    const ipc = new CodexJsonlIpc(appTempDir + '/codex_socket')
    let connected = false
    let lastError: Object = new Error('CODEX_IPC_CONNECT_FAILED')
    for (let attempt = 0; attempt < 10; attempt++) {
      try {
        await ipc.connect(2000)
        connected = true
        break
      } catch (error) {
        lastError = error as Object
        await this.delay(Math.min(250 * (attempt + 1), 1500))
      }
    }
    if (!connected) {
      throw lastError instanceof Error ? lastError : new Error('CODEX_IPC_CONNECT_FAILED')
    }

    const agent = await QemuAgentManager.acquire(RUNTIME_OWNER, AgentPriority.NORMAL, 15000)
    if (!agent) {
      await ipc.disconnect()
      throw new Error('CODEX_GUEST_NOT_READY')
    }
    try {
      const versionOutput = await agent.execAndGetOutput('/bin/sh', ['-c',
        'magic=$(od -An -tx1 -N4 ' + GUEST_BINARY + ' | tr -d " \\n") && ' +
        '[ "$magic" = "7f454c46" ] && chmod 700 ' + GUEST_BINARY +
        ' && [ -x ' + GUEST_BINARY + ' ] && ' +
        GUEST_BINARY + ' --version'], 10000)
      if (!versionOutput || versionOutput.indexOf(CODEX_VERSION) < 0) {
        throw new Error('CODEX_RUNTIME_VERSION_MISMATCH')
      }
      hilog.info(DOMAIN, 'CodexRuntime', '[CODEX_RUNTIME] verified version=%{public}s', CODEX_VERSION)
      const script = 'chmod 700 ' + GUEST_BINARY + ' && : >' + GUEST_STDERR +
        ' && exec 3<>' + GUEST_CHANNEL + ' 2>>' + GUEST_STDERR +
        ' && exec ' + GUEST_BINARY + ' app-server --listen stdio://' +
        ' -c \'model_provider="openai_chatgpt_plan"\'' +
        ' -c \'model_providers.openai_chatgpt_plan.name="ChatGPT plan"\'' +
        ' -c \'model_providers.openai_chatgpt_plan.base_url="https://api.openai.com/v1"\'' +
        ' -c \'model_providers.openai_chatgpt_plan.env_key="ACCESS_TOKEN"\'' +
        ' -c \'model_providers.openai_chatgpt_plan.wire_api="responses"\'' +
        ' -c \'model_providers.openai_chatgpt_plan.requires_openai_auth=false\'' +
        ' -c \'model_providers.openai_chatgpt_plan.supports_websockets=false\'' +
        ' <&3 >&3 3>&- 2>>' + GUEST_STDERR
      const pid = await agent.execDetached('/bin/sh', ['-c', script], ['ACCESS_TOKEN=' + accessToken])
      if (!pid) throw new Error('CODEX_APP_SERVER_START_FAILED')
      this.processId = pid
      await this.delay(300)
      const status = await agent.execStatus(pid)
      const diagnostics = await agent.execAndGetOutput('/bin/sh', ['-c',
        'printf "binary="; [ -f ' + GUEST_BINARY + ' ] && printf present || printf missing; ' +
        'printf " executable="; [ -x ' + GUEST_BINARY + ' ] && printf yes || printf no; ' +
        'printf " device="; [ -c ' + GUEST_CHANNEL + ' ] && printf present || printf missing; ' +
        'printf " readable="; [ -r ' + GUEST_CHANNEL + ' ] && printf yes || printf no; ' +
        'printf " writable="; [ -w ' + GUEST_CHANNEL + ' ] && printf yes || printf no; ' +
        'printf " process="; kill -0 ' + pid + ' 2>/dev/null && printf running || printf exited; ' +
        'printf " stderr_bytes="; [ -f ' + GUEST_STDERR + ' ] && wc -c <' + GUEST_STDERR +
        ' || printf 0'], 5000)
      hilog.info(DOMAIN, 'CodexRuntime', '[CODEX_RUNTIME] pid=%{public}d %{public}s', pid,
        diagnostics || 'diagnostics unavailable')
      if (status && status.exited) {
        const stderr = await agent.execAndGetOutput('/bin/sh', ['-c',
          '[ -f ' + GUEST_STDERR + ' ] && tail -c 1024 ' + GUEST_STDERR + ' || true'], 5000)
        const statusFields = status as Object as Record<string, Object>
        const exitCodeValue = statusFields['exit-code']
        const exitCode = typeof exitCodeValue === 'number' ? exitCodeValue : -1
        hilog.error(DOMAIN, 'CodexRuntime',
          '[CODEX_RUNTIME] app-server exited code=%{public}d signal=%{public}d stderr=%{public}s',
          exitCode,
          status.signal === undefined ? 0 : status.signal,
          this.redactDiagnostic(stderr || '', accessToken))
        throw new Error('CODEX_APP_SERVER_EXITED')
      }
    } catch (error) {
      this.processId = 0
      await ipc.disconnect()
      throw error instanceof Error ? error : new Error('CODEX_APP_SERVER_START_FAILED')
    } finally {
      await QemuAgentManager.release(RUNTIME_OWNER)
    }
    this.ipc = ipc
    return ipc
  }

  async stop(): Promise<void> {
    const ipc = this.ipc
    this.ipc = null
    if (ipc) await ipc.disconnect()
    const pid = this.processId
    this.processId = 0
    if (!pid) return
    const agent = await QemuAgentManager.acquire(RUNTIME_OWNER, AgentPriority.NORMAL, 5000)
    if (!agent) return
    try { await agent.kill(pid) } finally { await QemuAgentManager.release(RUNTIME_OWNER) }
  }

  private async prepareBinary(): Promise<void> {
    const sharedHost = AppStorage.get(appOption.sharedHost) as string
    if (!sharedHost) throw new Error('CODEX_SHARED_FOLDER_NOT_READY')
    const runtimeDir = sharedHost.replace(/[\\\/]$/, '') + '/.hish-runtime'
    const target = runtimeDir + '/' + BINARY_NAME
    if (!fs.accessSync(runtimeDir, fs.AccessModeType.EXIST)) fs.mkdirSync(runtimeDir)
    // RawFileDescriptor exposes the enclosing HAP fd plus an offset. On the
    // affected device that path exposed the HAP's PK header instead of this
    // large entry's payload. Native RawFile64 streams the resource entry itself
    // and validates its pinned SHA before publishing it.
    const preparedPath = await nativeRuntime.prepareBundledCodex(this.context.resourceManager, target)
    if (preparedPath !== target) throw new Error('CODEX_RUNTIME_PREPARE_FAILED')
    this.validateRuntimeBinary(target)
  }

  private validateRuntimeBinary(path: string): void {
    if (!fs.accessSync(path, fs.AccessModeType.EXIST)) throw new Error('CODEX_RUNTIME_NOT_FOUND')
    const stat = fs.statSync(path)
    if (stat.size <= 0 || stat.size !== EXPECTED_SIZE) {
      hilog.error(DOMAIN, 'CodexRuntime',
        '[CODEX_RUNTIME] binary validation failed stage=copied-file size=%{public}d expected=%{public}d',
        stat.size, EXPECTED_SIZE)
      throw new Error('CODEX_RUNTIME_INVALID_BINARY')
    }
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY)
    const header = new ArrayBuffer(20)
    let read = 0
    try {
      read = fs.readSync(file.fd, header, { offset: 0, length: header.byteLength })
    } finally {
      fs.closeSync(file)
    }
    this.validateRuntimeHeader(header, read, 'copied-file')
  }

  private validateRuntimeHeader(header: ArrayBuffer, read: number, stage: string): void {
    if (read < 20) {
      hilog.error(DOMAIN, 'CodexRuntime',
        '[CODEX_RUNTIME] binary validation failed stage=%{public}s header_bytes=%{public}d', stage, read)
      throw new Error('CODEX_RUNTIME_INVALID_BINARY')
    }
    const bytes = new Uint8Array(header)
    if (bytes[0] === 0x50 && bytes[1] === 0x4B && bytes[2] === 0x03 && bytes[3] === 0x04) {
      hilog.error(DOMAIN, 'CodexRuntime',
        '[CODEX_RUNTIME] binary validation failed stage=%{public}s magic=50-4B-03-04', stage)
      throw new Error('CODEX_RUNTIME_INVALID_ARCHIVE')
    }
    const elf = bytes[0] === 0x7F && bytes[1] === 0x45 && bytes[2] === 0x4C && bytes[3] === 0x46
    const elf64LittleEndian = bytes[4] === 0x02 && bytes[5] === 0x01
    const arm64 = bytes[18] === 0xB7 && bytes[19] === 0x00
    if (!elf || !elf64LittleEndian || !arm64) {
      hilog.error(DOMAIN, 'CodexRuntime',
        '[CODEX_RUNTIME] binary validation failed stage=%{public}s magic=%{public}d-%{public}d-%{public}d-%{public}d class=%{public}d endian=%{public}d machine=%{public}d',
        stage, bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[18])
      throw new Error('CODEX_RUNTIME_INVALID_BINARY')
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve): void => { setTimeout(resolve, ms) })
  }

  private redactDiagnostic(value: string, accessToken: string): string {
    let safe = value.substring(0, 1024)
    if (accessToken) safe = safe.split(accessToken).join('[REDACTED]')
    safe = safe.replace(/Bearer\s+[^\s"']+/gi, 'Bearer [REDACTED]')
    safe = safe.replace(/(access_token|refresh_token|id_token)\s*[=:]\s*[^\s"']+/gi, '$1=[REDACTED]')
    return safe
  }
}
