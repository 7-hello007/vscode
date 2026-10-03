import { describe, it, expect } from '@ohos/hypium'
import {
  encodeUtf8,
  RefreshTokenChunkStore,
  RefreshTokenIntegrityProvider,
  RefreshTokenSecretBackend
} from '../main/ets/ide/agent/RefreshTokenChunkStore'

class MemorySecretBackend implements RefreshTokenSecretBackend {
  private values: Map<string, Uint8Array> = new Map<string, Uint8Array>()
  failWriteAt: number = 0
  private writeCount: number = 0

  async read(alias: string): Promise<Uint8Array | null> {
    const value = this.values.get(alias)
    if (!value) return null
    const copy = new Uint8Array(value.length)
    copy.set(value)
    return copy
  }

  async writeNew(alias: string, value: Uint8Array): Promise<void> {
    this.writeCount++
    if (this.failWriteAt > 0 && this.writeCount === this.failWriteAt) throw new Error('TEST_WRITE_FAILURE')
    if (this.values.has(alias)) throw new Error('TEST_DUPLICATE_ALIAS')
    const copy = new Uint8Array(value.length)
    copy.set(value)
    this.values.set(alias, copy)
  }

  async replace(alias: string, value: Uint8Array): Promise<void> {
    const copy = new Uint8Array(value.length)
    copy.set(value)
    this.values.set(alias, copy)
  }

  async remove(alias: string): Promise<void> {
    this.values.delete(alias)
  }

  async listAliases(prefix: string): Promise<string[]> {
    const result: string[] = []
    this.values.forEach((value: Uint8Array, alias: string): void => {
      if (alias.startsWith(prefix)) result.push(alias)
    })
    return result
  }

  failNextWriteAfter(successfulWrites: number): void {
    this.failWriteAt = this.writeCount + successfulWrites + 1
  }
}

class TestIntegrityProvider implements RefreshTokenIntegrityProvider {
  private generation: number = 0

  async sha256(value: Uint8Array): Promise<string> {
    let hash = 2166136261
    for (let index = 0; index < value.length; index++) {
      hash ^= value[index]
      hash = Math.imul(hash, 16777619)
    }
    return value.length + ':' + (hash >>> 0).toString(16)
  }

  newGeneration(): string {
    this.generation++
    return 'test-' + this.generation
  }
}

function repeat(character: string, count: number): string {
  let result = ''
  for (let index = 0; index < count; index++) result += character
  return result
}

function createStore(backend: MemorySecretBackend): RefreshTokenChunkStore {
  return new RefreshTokenChunkStore(backend, new TestIntegrityProvider(),
    'hish.codex.refresh.', 'hish.codex.refresh.meta')
}

export default function refreshTokenChunkStoreTest() {
  describe('refreshTokenChunkStore', () => {
    for (const byteLength of [500, 1024, 1203, 2048]) {
      it('roundTrips' + byteLength + 'Bytes', 0, async () => {
        const backend = new MemorySecretBackend()
        const store = createStore(backend)
        const token = repeat('a', byteLength)
        const metadata = await store.save(token)
        expect(metadata.byteLength).assertEqual(byteLength)
        expect(metadata.chunkCount).assertEqual(Math.ceil(byteLength / 900))
        expect(await store.load()).assertEqual(token)
      })
    }

    it('roundTripsMultibyteUtf8ByBytes', 0, async () => {
      const backend = new MemorySecretBackend()
      const store = createStore(backend)
      const token = repeat('令牌🙂', 240)
      const expectedBytes = encodeUtf8(token).length
      const metadata = await store.save(token)
      expect(metadata.byteLength).assertEqual(expectedBytes)
      expect(await store.load()).assertEqual(token)
    })

    it('rotatesOnlyAfterNewGenerationIsVerified', 0, async () => {
      const backend = new MemorySecretBackend()
      const store = createStore(backend)
      const oldToken = repeat('o', 1203)
      const newToken = repeat('n', 2048)
      await store.save(oldToken)
      await store.save(newToken)
      expect(await store.load()).assertEqual(newToken)
      const aliases = await backend.listAliases('hish.codex.refresh.')
      expect(aliases.some((alias: string): boolean => alias.indexOf('test-1.') >= 0)).assertEqual(false)
    })

    it('keepsOldGenerationWhenChunkWriteFails', 0, async () => {
      const backend = new MemorySecretBackend()
      const store = createStore(backend)
      const oldToken = repeat('o', 1203)
      await store.save(oldToken)
      backend.failNextWriteAfter(1)
      let failed = false
      try { await store.save(repeat('n', 2048)) } catch (error) { failed = true }
      expect(failed).assertEqual(true)
      expect(await store.load()).assertEqual(oldToken)
    })

    it('rejectsMissingChunkWithoutPartialToken', 0, async () => {
      const backend = new MemorySecretBackend()
      const store = createStore(backend)
      await store.save(repeat('m', 1203))
      const aliases = await backend.listAliases('hish.codex.refresh.')
      const chunkAlias = aliases.find((alias: string): boolean => alias.endsWith('.1')) || ''
      await backend.remove(chunkAlias)
      let failed = false
      try { await store.load() } catch (error) { failed = true }
      expect(failed).assertEqual(true)
    })

    it('deleteAllRemovesMetadataAndAllGenerations', 0, async () => {
      const backend = new MemorySecretBackend()
      const store = createStore(backend)
      await store.save(repeat('d', 1203))
      await store.deleteAll()
      expect((await backend.listAliases('hish.codex.refresh.')).length).assertEqual(0)
      let failed = false
      try { await store.load() } catch (error) { failed = true }
      expect(failed).assertEqual(true)
    })
  })
}
