import { common } from '@kit.AbilityKit'
import { fileIo as hostFs, fileUri } from '@kit.CoreFileKit'
import IDEFileSystem from '../filesystem/IDEFileSystem'

const UPLOAD_CHUNK_SIZE = 64 * 1024

/**
 * Materializes one explicitly user-selected Linux guest file for ArkWeb's
 * standard file chooser. Guest bytes stay binary-safe and are never exposed
 * through a JavaScript/native bridge.
 */
export default class IDEWebUploadFileAdapter {
  private fileSystem: IDEFileSystem
  private context: common.UIAbilityContext
  private temporaryPaths: string[] = []

  constructor(fileSystem: IDEFileSystem, context: common.UIAbilityContext) {
    this.fileSystem = fileSystem
    this.context = context
  }

  async stageHiSHFile(path: string): Promise<string> {
    await this.cleanup()
    const normalized = this.fileSystem.normalizePath(path)
    const fileName = this.fileSystem.baseName(normalized)
    if (!fileName || fileName === '/') {
      throw new Error('Select a file, not a directory')
    }

    const uploadDirectory = this.context.cacheDir + '/hish-web-upload'
    if (!hostFs.accessSync(uploadDirectory, hostFs.AccessModeType.EXIST)) {
      hostFs.mkdirSync(uploadDirectory)
    }
    const target = uploadDirectory + '/' + Date.now() + '-' + fileName
    const file = hostFs.openSync(target,
      hostFs.OpenMode.WRITE_ONLY | hostFs.OpenMode.CREATE | hostFs.OpenMode.TRUNC)
    let offset = 0
    try {
      while (true) {
        const bytes = await this.fileSystem.readBinary(normalized, offset, UPLOAD_CHUNK_SIZE)
        if (bytes.byteLength === 0) break
        const written = hostFs.writeSync(file.fd, bytes.buffer, { offset: 0, length: bytes.byteLength })
        if (written !== bytes.byteLength) {
          throw new Error('Unable to stage the complete HiSH file')
        }
        offset += bytes.byteLength
        if (bytes.byteLength < UPLOAD_CHUNK_SIZE) break
      }
    } catch (error) {
      hostFs.closeSync(file)
      if (hostFs.accessSync(target, hostFs.AccessModeType.EXIST)) {
        try { hostFs.unlinkSync(target) } catch (cleanupError) {}
      }
      throw new Error((error as Error).message || 'Unable to stage the selected HiSH file')
    }
    hostFs.closeSync(file)
    this.temporaryPaths.push(target)
    return fileUri.getUriFromPath(target)
  }

  async cleanup(): Promise<void> {
    const paths = this.temporaryPaths
    this.temporaryPaths = []
    for (const path of paths) {
      if (!hostFs.accessSync(path, hostFs.AccessModeType.EXIST)) continue
      try {
        await hostFs.unlink(path)
      } catch (error) {
        // App cache remains sandboxed and can be cleaned on the next attempt.
      }
    }
  }
}
