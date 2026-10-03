export class IDEBinaryPatch {
  offset: number
  bytes: Uint8Array

  constructor(offset: number, bytes: Uint8Array) {
    this.offset = offset
    this.bytes = bytes
  }
}

/** Non-reactive byte edit storage shared by binary tabs. */
export default class BinaryEditSessionStore {
  private edits: Map<string, Map<number, number>> = new Map<string, Map<number, number>>()

  setByte(path: string, offset: number, value: number): void {
    let fileEdits = this.edits.get(path)
    if (!fileEdits) {
      fileEdits = new Map<number, number>()
      this.edits.set(path, fileEdits)
    }
    fileEdits.set(offset, Math.max(0, Math.min(255, value)))
  }

  mergePage(path: string, baseOffset: number, source: Uint8Array): number[] {
    const values: number[] = []
    const fileEdits = this.edits.get(path)
    for (let index = 0; index < source.byteLength; index++) {
      const edited = fileEdits?.get(baseOffset + index)
      values.push(edited === undefined ? source[index] : edited)
    }
    return values
  }

  hasEdits(path: string): boolean {
    return (this.edits.get(path)?.size || 0) > 0
  }

  isEdited(path: string, offset: number): boolean {
    return this.edits.get(path)?.has(offset) || false
  }

  buildPatches(path: string): IDEBinaryPatch[] {
    const fileEdits = this.edits.get(path)
    if (!fileEdits || fileEdits.size === 0) return []
    const offsets: number[] = []
    fileEdits.forEach((_value: number, offset: number): void => {
      offsets.push(offset)
    })
    offsets.sort((left: number, right: number): number => left - right)
    const patches: IDEBinaryPatch[] = []
    let start = offsets[0]
    let values: number[] = [fileEdits.get(start)!!]
    for (let index = 1; index < offsets.length; index++) {
      const offset = offsets[index]
      if (offset === offsets[index - 1] + 1) {
        values.push(fileEdits.get(offset)!!)
      } else {
        patches.push(new IDEBinaryPatch(start, new Uint8Array(values)))
        start = offset
        values = [fileEdits.get(offset)!!]
      }
    }
    patches.push(new IDEBinaryPatch(start, new Uint8Array(values)))
    return patches
  }

  clear(path: string): void {
    this.edits.delete(path)
  }

  rename(oldPath: string, newPath: string): void {
    const existing = this.edits.get(oldPath)
    if (!existing) return
    this.edits.set(newPath, existing)
    this.edits.delete(oldPath)
  }
}
