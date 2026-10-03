import { socket } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { hilog } from '@kit.PerformanceAnalysisKit'

const MAX_LINE_BYTES = 1024 * 1024
const REQUEST_TIMEOUT_MS = 30000
const DOMAIN = 0x0000

interface JsonRpcEnvelope {
  id?: number
  method?: string
  params?: Object
  result?: Object
  error?: Object
}

interface JsonRpcErrorValue { code: number, message: string }

class PendingJsonRpcRequest {
  resolve: (value: Object) => void
  reject: (error: Error) => void
  timeoutId: number
  method: string

  constructor(resolve: (value: Object) => void, reject: (error: Error) => void, timeoutId: number,
    method: string) {
    this.resolve = resolve
    this.reject = reject
    this.timeoutId = timeoutId
    this.method = method
  }
}

export type CodexJsonlNotificationListener = (method: string, params: Object) => void
export type CodexJsonlRequestListener = (id: number, method: string, params: Object) => void

/** Bounded JSONL channel over the dedicated host-side virtio Unix socket. */
export default class CodexJsonlIpc {
  private socketPath: string
  private client: socket.LocalSocket | null = null
  private buffer: string = ''
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8')
  private nextId: number = 0
  private generation: number = 0
  private pending: Map<number, PendingJsonRpcRequest> = new Map<number, PendingJsonRpcRequest>()
  private notificationListener: CodexJsonlNotificationListener | null = null
  private requestListener: CodexJsonlRequestListener | null = null
  private traceInitialize: boolean = false

  constructor(socketPath: string) {
    this.socketPath = socketPath
  }

  setNotificationListener(listener: CodexJsonlNotificationListener): void {
    this.notificationListener = listener
  }

  setRequestListener(listener: CodexJsonlRequestListener): void {
    this.requestListener = listener
  }

  isConnected(): boolean {
    return this.client !== null
  }

  async connect(timeoutMs: number = 5000): Promise<void> {
    await this.disconnect()
    const client = socket.constructLocalSocketInstance()
    const generation = ++this.generation
    this.client = client
    this.buffer = ''
    this.decoder = util.TextDecoder.create('utf-8')
    client.on('message', (info: socket.LocalSocketMessageInfo): void => {
      if (this.client !== client || this.generation !== generation) return
      if (this.traceInitialize) {
        hilog.info(DOMAIN, 'CodexJsonlIpc', '[CODEX_IPC] received bytes=%{public}d', info.message.byteLength)
      }
      const chunk = this.decoder.decodeToString(new Uint8Array(info.message), { stream: true })
      this.acceptChunk(chunk)
    })
    client.on('close', (): void => this.handleDisconnect(client, generation, 'CODEX_IPC_CLOSED'))
    client.on('error', (): void => this.handleDisconnect(client, generation, 'CODEX_IPC_ERROR'))
    await client.connect({ address: { address: this.socketPath }, timeout: timeoutMs })
    hilog.info(DOMAIN, 'CodexJsonlIpc', '[CODEX_IPC] connected')
  }

  async disconnect(): Promise<void> {
    const client = this.client
    this.client = null
    this.generation++
    this.buffer = ''
    this.decoder = util.TextDecoder.create('utf-8')
    this.rejectPending('CODEX_IPC_DISCONNECTED')
    if (client) {
      try {
        client.off('message')
        client.off('close')
        client.off('error')
        await client.close()
      } catch (error) { }
    }
  }

  async request(method: string, params: Object, timeoutMs: number = REQUEST_TIMEOUT_MS): Promise<Object> {
    const client = this.requireClient()
    const id = ++this.nextId
    const frame = JSON.stringify({ id: id, method: method, params: params }) + '\n'
    if (method === 'initialize') {
      this.traceInitialize = true
      const byteLength = util.TextEncoder.create().encodeInto(frame).length
      hilog.info(DOMAIN, 'CodexJsonlIpc', '[CODEX_IPC] initialize write bytes=%{public}d', byteLength)
    }
    const result = new Promise<Object>((resolve, reject): void => {
      const timeoutId = setTimeout((): void => {
        this.pending.delete(id)
        if (method === 'initialize') this.traceInitialize = false
        reject(new Error('CODEX_IPC_TIMEOUT_' + method))
      }, timeoutMs)
      this.pending.set(id, new PendingJsonRpcRequest(resolve, reject, timeoutId, method))
    })
    try {
      await client.send({ data: frame })
      if (method === 'initialize') {
        hilog.info(DOMAIN, 'CodexJsonlIpc', '[CODEX_IPC] initialize write success')
      }
      return await result
    } catch (error) {
      const pending = this.pending.get(id)
      if (pending) clearTimeout(pending.timeoutId)
      this.pending.delete(id)
      if (method === 'initialize') this.traceInitialize = false
      throw error instanceof Error ? error : new Error('CODEX_IPC_SEND_FAILED')
    }
  }

  async notify(method: string, params: Object): Promise<void> {
    await this.requireClient().send({ data: JSON.stringify({ method: method, params: params }) + '\n' })
  }

  async respond(id: number, result: Object): Promise<void> {
    await this.requireClient().send({ data: JSON.stringify({ id: id, result: result }) + '\n' })
  }

  async respondError(id: number, code: number, message: string): Promise<void> {
    const errorValue: JsonRpcErrorValue = { code: code, message: message }
    const envelope: JsonRpcEnvelope = { id: id, error: errorValue }
    await this.requireClient().send({ data: JSON.stringify(envelope) + '\n' })
  }

  private acceptChunk(chunk: string): void {
    this.buffer += chunk
    if (util.TextEncoder.create().encodeInto(this.buffer).length > MAX_LINE_BYTES) {
      this.buffer = ''
      this.rejectPending('CODEX_IPC_OVERSIZED_FRAME')
      return
    }
    let lineEnd = this.buffer.indexOf('\n')
    while (lineEnd >= 0) {
      const line = this.buffer.substring(0, lineEnd).trim()
      this.buffer = this.buffer.substring(lineEnd + 1)
      if (line) this.acceptLine(line)
      lineEnd = this.buffer.indexOf('\n')
    }
  }

  private acceptLine(line: string): void {
    let message: JsonRpcEnvelope
    try {
      message = JSON.parse(line) as JsonRpcEnvelope
    } catch (error) {
      if (this.traceInitialize) {
        hilog.warn(DOMAIN, 'CodexJsonlIpc', '[CODEX_IPC] received JSON type=malformed')
      }
      return // malformed peer output is isolated from subsequent JSONL frames
    }
    if (this.traceInitialize) {
      const type = message.id !== undefined && !message.method ? 'response' :
        (message.id !== undefined && message.method ? 'request' : (message.method ? 'notification' : 'unknown'))
      hilog.info(DOMAIN, 'CodexJsonlIpc', '[CODEX_IPC] received JSON type=%{public}s', type)
    }
    if (message.id !== undefined && !message.method) {
      const pending = this.pending.get(message.id)
      if (!pending) return
      if (pending.method === 'initialize') {
        hilog.info(DOMAIN, 'CodexJsonlIpc', '[CODEX_IPC] response id=%{public}d', message.id)
        this.traceInitialize = false
      }
      clearTimeout(pending.timeoutId)
      this.pending.delete(message.id)
      if (message.error) pending.reject(new Error('CODEX_APP_SERVER_ERROR_' + JSON.stringify(message.error)))
      else pending.resolve(message.result || new Object())
      return
    }
    if (message.method && message.id !== undefined) {
      if (this.requestListener) this.requestListener(message.id, message.method, message.params || new Object())
      else void this.respondError(message.id, -32601, 'No request handler')
      return
    }
    if (message.method && this.notificationListener) {
      this.notificationListener(message.method, message.params || new Object())
    }
  }

  private handleDisconnect(client: socket.LocalSocket, generation: number, reason: string): void {
    if (this.client !== client || this.generation !== generation) return
    this.client = null
    this.generation++
    this.buffer = ''
    this.decoder = util.TextDecoder.create('utf-8')
    this.traceInitialize = false
    this.rejectPending(reason)
    if (this.notificationListener) this.notificationListener('transport/disconnected', new Object())
  }

  private rejectPending(reason: string): void {
    this.pending.forEach((pending: PendingJsonRpcRequest): void => {
      clearTimeout(pending.timeoutId)
      pending.reject(new Error(reason))
    })
    this.pending.clear()
  }

  private requireClient(): socket.LocalSocket {
    if (!this.client) throw new Error('CODEX_IPC_NOT_CONNECTED')
    return this.client
  }
}
