import { common } from '@kit.AbilityKit'
import { zlib } from '@kit.BasicServicesKit'
import { fileIo as hostFs, fileUri } from '@kit.CoreFileKit'
import IDEFileSystem from '../filesystem/IDEFileSystem'

const DOCUMENT_CHUNK_SIZE = 64 * 1024
const MAX_DOCUMENT_BYTES = 96 * 1024 * 1024
const MAX_XML_BYTES = 12 * 1024 * 1024

export class IDEPreparedDocument {
  guestPath: string
  localPath: string
  localUri: string
  rootDirectory: string
  extractedDirectory: string
  size: number

  constructor(guestPath: string, localPath: string, rootDirectory: string, size: number) {
    this.guestPath = guestPath
    this.localPath = localPath
    this.localUri = fileUri.getUriFromPath(localPath)
    this.rootDirectory = rootDirectory
    this.extractedDirectory = rootDirectory + '/content'
    this.size = size
  }
}

/** App-sandbox staging and bounded OOXML extraction shared by document tabs. */
export default class IDEDocumentRuntime {
  private fileSystem: IDEFileSystem
  private context: common.UIAbilityContext | null = null
  private prepared: Map<string, IDEPreparedDocument> = new Map<string, IDEPreparedDocument>()

  constructor(fileSystem: IDEFileSystem) {
    this.fileSystem = fileSystem
  }

  setContext(context: common.UIAbilityContext): void {
    this.context = context
  }

  async prepare(path: string, extract: boolean = false): Promise<IDEPreparedDocument> {
    const cached = this.prepared.get(path)
    if (cached && hostFs.accessSync(cached.localPath, hostFs.AccessModeType.EXIST)) {
      if (extract && !hostFs.accessSync(cached.extractedDirectory, hostFs.AccessModeType.EXIST)) {
        await this.extract(cached)
      }
      return cached
    }
    if (!this.context) throw new Error('Document runtime context is unavailable')
    const normalized = this.fileSystem.normalizePath(path)
    const root = this.context.cacheDir + '/hish-documents/' + Date.now() + '-' + this.prepared.size
    hostFs.mkdirSync(root, true)
    const localPath = root + '/' + this.fileSystem.baseName(normalized)
    const file = hostFs.openSync(localPath,
      hostFs.OpenMode.WRITE_ONLY | hostFs.OpenMode.CREATE | hostFs.OpenMode.TRUNC)
    let offset = 0
    try {
      while (true) {
        const bytes = await this.fileSystem.readBinary(normalized, offset, DOCUMENT_CHUNK_SIZE)
        if (bytes.byteLength === 0) break
        if (offset + bytes.byteLength > MAX_DOCUMENT_BYTES) {
          throw new Error('Document exceeds the 96 MB local preview limit')
        }
        const written = hostFs.writeSync(file.fd, bytes.buffer, { offset: 0, length: bytes.byteLength })
        if (written !== bytes.byteLength) throw new Error('Document staging was incomplete')
        offset += bytes.byteLength
        if (bytes.byteLength < DOCUMENT_CHUNK_SIZE) break
      }
    } catch (error) {
      hostFs.closeSync(file)
      throw new Error((error as Error).message || 'Unable to stage document')
    }
    hostFs.closeSync(file)
    const result = new IDEPreparedDocument(normalized, localPath, root, offset)
    this.prepared.set(path, result)
    if (extract) await this.extract(result)
    return result
  }

  readXml(document: IDEPreparedDocument, relativePath: string): string {
    const path = this.safeExtractedPath(document, relativePath)
    if (!hostFs.accessSync(path, hostFs.AccessModeType.EXIST)) return ''
    const stat = hostFs.statSync(path)
    if (stat.size > MAX_XML_BYTES) throw new Error('Document XML part exceeds preview limit')
    return hostFs.readTextSync(path, { encoding: 'utf-8' })
  }

  assetUri(document: IDEPreparedDocument, relativePath: string): string {
    const path = this.safeExtractedPath(document, relativePath)
    return hostFs.accessSync(path, hostFs.AccessModeType.EXIST) ? fileUri.getUriFromPath(path) : ''
  }

  listFiles(document: IDEPreparedDocument, relativeDirectory: string): string[] {
    const path = this.safeExtractedPath(document, relativeDirectory)
    if (!hostFs.accessSync(path, hostFs.AccessModeType.EXIST)) return []
    return hostFs.listFileSync(path)
  }

  readLocalBytes(path: string): ArrayBuffer {
    const stat = hostFs.statSync(path)
    if (stat.size <= 0 || stat.size > MAX_DOCUMENT_BYTES) throw new Error('PDF size is outside preview limits')
    const buffer = new ArrayBuffer(stat.size)
    const file = hostFs.openSync(path, hostFs.OpenMode.READ_ONLY)
    try {
      const read = hostFs.readSync(file.fd, buffer, { offset: 0, length: stat.size })
      if (read !== stat.size) throw new Error('PDF read was incomplete')
    } finally {
      hostFs.closeSync(file)
    }
    return buffer
  }

  release(path: string): void {
    const document = this.prepared.get(path)
    if (!document) return
    this.prepared.delete(path)
    this.removeTree(document.rootDirectory)
  }

  releaseAll(): void {
    const documents: IDEPreparedDocument[] = []
    this.prepared.forEach((value: IDEPreparedDocument): void => { documents.push(value) })
    this.prepared.clear()
    for (const document of documents) this.removeTree(document.rootDirectory)
  }

  private async extract(document: IDEPreparedDocument): Promise<void> {
    if (hostFs.accessSync(document.extractedDirectory, hostFs.AccessModeType.EXIST)) return
    hostFs.mkdirSync(document.extractedDirectory, true)
    try {
      await zlib.decompressFile(document.localPath, document.extractedDirectory)
    } catch (error) {
      throw new Error('Invalid or unsupported OOXML archive: ' + ((error as Error).message || 'decompression failed'))
    }
  }

  private safeExtractedPath(document: IDEPreparedDocument, relativePath: string): string {
    const normalized = relativePath.replace(/\\/g, '/').replace(/^\/+/, '')
    const parts = normalized.split('/')
    for (const part of parts) {
      if (!part || part === '.' || part === '..') throw new Error('Invalid document part path')
    }
    return document.extractedDirectory + '/' + parts.join('/')
  }

  private removeTree(path: string): void {
    if (!hostFs.accessSync(path, hostFs.AccessModeType.EXIST)) return
    try {
      const stat = hostFs.statSync(path)
      if (!stat.isDirectory()) {
        hostFs.unlinkSync(path)
        return
      }
      for (const child of hostFs.listFileSync(path)) this.removeTree(path + '/' + child)
      hostFs.rmdirSync(path)
    } catch (error) {
      // Cache is private and the OS may reclaim a file still owned by ArkWeb.
    }
  }
}
