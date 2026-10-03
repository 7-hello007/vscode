export const REFRESH_TOKEN_CHUNK_BYTES: number = 900
export const REFRESH_TOKEN_STORAGE_VERSION: number = 1

export interface RefreshTokenMetadata {
  version: number
  generation: string
  chunkCount: number
  byteLength: number
  sha256: string
}

export interface RefreshTokenSecretBackend {
  read(alias: string): Promise<Uint8Array | null>
  writeNew(alias: string, value: Uint8Array): Promise<void>
  replace(alias: string, value: Uint8Array): Promise<void>
  remove(alias: string): Promise<void>
  listAliases(prefix: string): Promise<string[]>
}

export interface RefreshTokenIntegrityProvider {
  sha256(value: Uint8Array): Promise<string>
  newGeneration(): string
}

/**
 * Stores a refresh token as bounded Asset Store secrets. The metadata record is
 * the active-generation pointer and never contains credential material.
 */
export class RefreshTokenChunkStore {
  private backend: RefreshTokenSecretBackend
  private integrity: RefreshTokenIntegrityProvider
  private prefix: string
  private metadataAlias: string

  constructor(backend: RefreshTokenSecretBackend, integrity: RefreshTokenIntegrityProvider,
    prefix: string, metadataAlias: string) {
    this.backend = backend
    this.integrity = integrity
    this.prefix = prefix
    this.metadataAlias = metadataAlias
  }

  async save(value: string): Promise<RefreshTokenMetadata> {
    const encoded = encodeUtf8(value)
    if (encoded.length === 0) throw new Error('OAUTH_REFRESH_TOKEN_EMPTY')
    const previous = await this.readMetadata(false)
    const generation = this.integrity.newGeneration()
    const chunks = this.split(encoded)
    const candidate: RefreshTokenMetadata = {
      version: REFRESH_TOKEN_STORAGE_VERSION,
      generation: generation,
      chunkCount: chunks.length,
      byteLength: encoded.length,
      sha256: await this.integrity.sha256(encoded)
    }
    try {
      for (let index = 0; index < chunks.length; index++) {
        await this.backend.writeNew(this.chunkAlias(generation, index), chunks[index])
      }
      const verified = await this.loadFromMetadata(candidate)
      if (verified !== value) throw new Error('OAUTH_REFRESH_TOKEN_VERIFY_FAILED')
      await this.backend.replace(this.metadataAlias, this.encodeMetadata(candidate))
    } catch (error) {
      await this.removeGeneration(candidate)
      throw error instanceof Error ? error : new Error('OAUTH_REFRESH_TOKEN_SAVE_FAILED')
    }
    if (previous && previous.generation !== candidate.generation) {
      await this.removeGeneration(previous)
    }
    return candidate
  }

  async load(): Promise<string> {
    const metadata = await this.readMetadata(true)
    if (!metadata) throw new Error('OAUTH_REFRESH_TOKEN_METADATA_MISSING')
    return await this.loadFromMetadata(metadata)
  }

  async deleteAll(): Promise<void> {
    let aliases: string[] = []
    try {
      aliases = await this.backend.listAliases(this.prefix)
    } catch (error) {
      const current = await this.readMetadata(false)
      if (current) await this.removeGeneration(current)
    }
    for (const alias of aliases) {
      await this.backend.remove(alias)
    }
    await this.backend.remove(this.metadataAlias)
  }

  private split(value: Uint8Array): Uint8Array[] {
    const chunks: Uint8Array[] = []
    for (let offset = 0; offset < value.length; offset += REFRESH_TOKEN_CHUNK_BYTES) {
      const length = Math.min(REFRESH_TOKEN_CHUNK_BYTES, value.length - offset)
      const chunk = new Uint8Array(length)
      chunk.set(value.subarray(offset, offset + length))
      chunks.push(chunk)
    }
    return chunks
  }

  private async loadFromMetadata(metadata: RefreshTokenMetadata): Promise<string> {
    this.validateMetadata(metadata)
    const result = new Uint8Array(metadata.byteLength)
    let offset = 0
    for (let index = 0; index < metadata.chunkCount; index++) {
      const chunk = await this.backend.read(this.chunkAlias(metadata.generation, index))
      if (!chunk || chunk.length === 0) throw new Error('OAUTH_REFRESH_TOKEN_CHUNK_MISSING')
      if (chunk.length > REFRESH_TOKEN_CHUNK_BYTES || offset + chunk.length > result.length) {
        throw new Error('OAUTH_REFRESH_TOKEN_CHUNK_INVALID')
      }
      result.set(chunk, offset)
      offset += chunk.length
    }
    if (offset !== metadata.byteLength) throw new Error('OAUTH_REFRESH_TOKEN_LENGTH_MISMATCH')
    const digest = await this.integrity.sha256(result)
    if (digest !== metadata.sha256) throw new Error('OAUTH_REFRESH_TOKEN_INTEGRITY_FAILED')
    const decoded = decodeUtf8(result)
    const roundTrip = encodeUtf8(decoded)
    if (!this.bytesEqual(result, roundTrip)) throw new Error('OAUTH_REFRESH_TOKEN_UTF8_INVALID')
    return decoded
  }

  private async readMetadata(required: boolean): Promise<RefreshTokenMetadata | null> {
    const value = await this.backend.read(this.metadataAlias)
    if (!value) {
      if (required) throw new Error('OAUTH_REFRESH_TOKEN_METADATA_MISSING')
      return null
    }
    try {
      const decoded = decodeUtf8(value)
      const metadata = JSON.parse(decoded) as RefreshTokenMetadata
      this.validateMetadata(metadata)
      return metadata
    } catch (error) {
      if (required) throw new Error('OAUTH_REFRESH_TOKEN_METADATA_INVALID')
      return null
    }
  }

  private validateMetadata(metadata: RefreshTokenMetadata): void {
    if (metadata.version !== REFRESH_TOKEN_STORAGE_VERSION || !metadata.generation ||
      metadata.chunkCount < 1 || metadata.chunkCount > 128 || metadata.byteLength < 1 ||
      metadata.byteLength > metadata.chunkCount * REFRESH_TOKEN_CHUNK_BYTES || !metadata.sha256) {
      throw new Error('OAUTH_REFRESH_TOKEN_METADATA_INVALID')
    }
  }

  private encodeMetadata(metadata: RefreshTokenMetadata): Uint8Array {
    return encodeUtf8(JSON.stringify(metadata))
  }

  private async removeGeneration(metadata: RefreshTokenMetadata): Promise<void> {
    for (let index = 0; index < metadata.chunkCount; index++) {
      await this.backend.remove(this.chunkAlias(metadata.generation, index))
    }
  }

  private chunkAlias(generation: string, index: number): string {
    return this.prefix + generation + '.' + index
  }

  private bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
    if (left.length !== right.length) return false
    for (let index = 0; index < left.length; index++) {
      if (left[index] !== right[index]) return false
    }
    return true
  }
}

export function encodeUtf8(value: string): Uint8Array {
  const bytes: number[] = []
  for (let index = 0; index < value.length; index++) {
    let codePoint = value.charCodeAt(index)
    if (codePoint >= 0xd800 && codePoint <= 0xdbff && index + 1 < value.length) {
      const low = value.charCodeAt(index + 1)
      if (low >= 0xdc00 && low <= 0xdfff) {
        codePoint = 0x10000 + ((codePoint - 0xd800) << 10) + (low - 0xdc00)
        index++
      }
    }
    if (codePoint <= 0x7f) {
      bytes.push(codePoint)
    } else if (codePoint <= 0x7ff) {
      bytes.push(0xc0 | (codePoint >> 6), 0x80 | (codePoint & 0x3f))
    } else if (codePoint <= 0xffff) {
      bytes.push(0xe0 | (codePoint >> 12), 0x80 | ((codePoint >> 6) & 0x3f), 0x80 | (codePoint & 0x3f))
    } else {
      bytes.push(0xf0 | (codePoint >> 18), 0x80 | ((codePoint >> 12) & 0x3f),
        0x80 | ((codePoint >> 6) & 0x3f), 0x80 | (codePoint & 0x3f))
    }
  }
  return new Uint8Array(bytes)
}

export function decodeUtf8(value: Uint8Array): string {
  let result = ''
  for (let index = 0; index < value.length;) {
    const first = value[index]
    let codePoint = 0
    let length = 0
    if (first <= 0x7f) {
      codePoint = first
      length = 1
    } else if (first >= 0xc2 && first <= 0xdf) {
      codePoint = first & 0x1f
      length = 2
    } else if (first >= 0xe0 && first <= 0xef) {
      codePoint = first & 0x0f
      length = 3
    } else if (first >= 0xf0 && first <= 0xf4) {
      codePoint = first & 0x07
      length = 4
    } else {
      throw new Error('OAUTH_REFRESH_TOKEN_UTF8_INVALID')
    }
    if (index + length > value.length) throw new Error('OAUTH_REFRESH_TOKEN_UTF8_INVALID')
    for (let offset = 1; offset < length; offset++) {
      const next = value[index + offset]
      if ((next & 0xc0) !== 0x80) throw new Error('OAUTH_REFRESH_TOKEN_UTF8_INVALID')
      codePoint = (codePoint << 6) | (next & 0x3f)
    }
    if ((length === 2 && codePoint < 0x80) || (length === 3 && codePoint < 0x800) ||
      (length === 4 && codePoint < 0x10000) || codePoint > 0x10ffff ||
      (codePoint >= 0xd800 && codePoint <= 0xdfff)) {
      throw new Error('OAUTH_REFRESH_TOKEN_UTF8_INVALID')
    }
    if (codePoint <= 0xffff) {
      result += String.fromCharCode(codePoint)
    } else {
      const adjusted = codePoint - 0x10000
      result += String.fromCharCode(0xd800 + (adjusted >> 10), 0xdc00 + (adjusted & 0x3ff))
    }
    index += length
  }
  return result
}
