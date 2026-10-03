import IDEFileSystem from '../filesystem/IDEFileSystem'
import BinaryEditSessionStore from '../model/BinaryEditSessionStore'
import {
  IDE_BORDER_SUBTLE_COLOR,
  IDE_SURFACE_INPUT_COLOR,
  IDE_SURFACE_RAISED_COLOR
} from '../theme/IDEBackgroundSurfaces'

const BINARY_PAGE_SIZE = 512
const BYTES_PER_LINE = 16

export class BinaryByteCell {
  id: string
  offset: number
  hex: string
  edited: boolean

  constructor(id: string, offset: number, hex: string, edited: boolean = false) {
    this.id = id
    this.offset = offset
    this.hex = hex
    this.edited = edited
  }
}

export class BinaryDisplayLine {
  id: string
  offset: string
  cells: BinaryByteCell[]
  ascii: string

  constructor(id: string, offset: string, cells: BinaryByteCell[], ascii: string) {
    this.id = id
    this.offset = offset
    this.cells = cells
    this.ascii = ascii
  }
}

/** Pure formatter over plain numbers so no TypedArray can enter ArkUI reactive state. */
export function formatBinaryDisplayLines(values: number[], baseOffset: number): BinaryDisplayLine[] {
  const result: BinaryDisplayLine[] = []
  for (let start = 0; start < values.length; start += BYTES_PER_LINE) {
    let ascii = ''
    const cells: BinaryByteCell[] = []
    const end = Math.min(start + BYTES_PER_LINE, values.length)
    for (let index = start; index < end; index++) {
      const value = Math.max(0, Math.min(255, values[index]))
      const absoluteOffset = baseOffset + index
      cells.push(new BinaryByteCell('byte-' + absoluteOffset, absoluteOffset,
        value.toString(16).toUpperCase().padStart(2, '0')))
      ascii += value >= 0x20 && value <= 0x7e ? String.fromCharCode(value) : '.'
    }
    const absolute = baseOffset + start
    result.push(new BinaryDisplayLine('binary-' + absolute,
      absolute.toString(16).toUpperCase().padStart(8, '0'), cells, ascii))
  }
  return result
}

@Component
export default struct BinaryViewerPanel {
  @Require fileSystem: IDEFileSystem
  @Require editStore: BinaryEditSessionStore
  @Watch('onPathChanged') @Prop path: string = ''
  @Prop detectedType: string = 'Binary'
  @Watch('onRevisionChanged') @Prop revision: number = 0
  @Require onDirtyChange: (path: string, dirty: boolean) => void
  @State pageOffset: number = 0
  @State pageByteCount: number = 0
  @State pageValues: number[] = []
  @State lines: BinaryDisplayLine[] = []
  @State loading: boolean = false
  @State errorText: string = ''
  private pageBytes: Uint8Array = new Uint8Array(0)
  private loadSequence: number = 0

  aboutToAppear(): void {
    void this.loadPage(0)
  }

  private onPathChanged(): void {
    this.loadSequence++
    this.pageOffset = 0
    this.pageBytes = new Uint8Array(0)
    this.pageByteCount = 0
    this.pageValues = []
    this.lines = []
    this.errorText = ''
    this.loading = false
    void this.loadPage(0)
  }

  private onRevisionChanged(): void {
    void this.loadPage(this.pageOffset)
  }

  private rebuildLines(): void {
    const nextLines = formatBinaryDisplayLines(this.pageValues, this.pageOffset)
    for (const line of nextLines) {
      for (const cell of line.cells) {
        cell.edited = this.editStore.isEdited(this.path, cell.offset)
      }
    }
    this.lines = nextLines
  }

  private async loadPage(pageOffset: number): Promise<void> {
    if (!this.path) return
    const requestPath = this.path
    const requestSequence = ++this.loadSequence
    this.loading = true
    this.errorText = ''
    try {
      const result = await this.fileSystem.readBinary(requestPath, pageOffset, BINARY_PAGE_SIZE)
      if (requestSequence !== this.loadSequence || requestPath !== this.path) return
      this.pageBytes = result
      this.pageOffset = pageOffset
      this.pageByteCount = result.byteLength
      this.pageValues = this.editStore.mergePage(requestPath, pageOffset, result)
      this.rebuildLines()
    } catch (error) {
      if (requestSequence === this.loadSequence) this.errorText = (error as Error).message
    } finally {
      if (requestSequence === this.loadSequence) this.loading = false
    }
  }

  private editByte(cell: BinaryByteCell, value: string): void {
    const normalized = value.replace(/[^0-9a-fA-F]/g, '')
    if (normalized.length < 2) return
    const hex = normalized.substring(normalized.length - 2)
    const byteValue = parseInt(hex, 16)
    if (!Number.isFinite(byteValue)) return
    const localIndex = cell.offset - this.pageOffset
    if (localIndex < 0 || localIndex >= this.pageValues.length) return
    this.editStore.setByte(this.path, cell.offset, byteValue)
    const nextValues = this.pageValues.slice()
    nextValues[localIndex] = byteValue
    this.pageValues = nextValues
    this.rebuildLines()
    this.onDirtyChange(this.path, true)
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text(this.path.substring(this.path.lastIndexOf('/') + 1))
            .fontSize(13)
            .fontColor('#E1E5EA')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.detectedType + ' · editable bytes · ' + BINARY_PAGE_SIZE + ' bytes/page')
            .fontSize(10)
            .fontColor('#89929F')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('‹')
          .width(34)
          .height(28)
          .enabled(this.pageOffset > 0 && !this.loading)
          .backgroundColor(Color.Transparent)
          .onClick(() => void this.loadPage(Math.max(0, this.pageOffset - BINARY_PAGE_SIZE)))
        Text('0x' + this.pageOffset.toString(16).toUpperCase().padStart(8, '0'))
          .fontSize(10)
          .fontFamily('monospace')
          .fontColor('#AEB6C2')
        Button('›')
          .width(34)
          .height(28)
          .enabled(this.pageByteCount === BINARY_PAGE_SIZE && !this.loading)
          .backgroundColor(Color.Transparent)
          .onClick(() => void this.loadPage(this.pageOffset + BINARY_PAGE_SIZE))
      }
      .width('100%')
      .height(48)
      .padding({ left: 12, right: 8 })
      .backgroundColor(IDE_SURFACE_RAISED_COLOR)

      Row() {
        Text('OFFSET').width(82).fontSize(10).fontFamily('monospace').fontColor('#7F8996')
        Text('HEX (edit 00–FF)').layoutWeight(1).fontSize(10).fontFamily('monospace').fontColor('#7F8996')
        Text('ASCII').width(130).fontSize(10).fontFamily('monospace').fontColor('#7F8996')
      }
      .height(28)
      .padding({ left: 12, right: 12 })
      .backgroundColor(IDE_SURFACE_RAISED_COLOR)

      if (this.loading) {
        LoadingProgress().width(28).height(28).color('#8F98A6').margin({ top: 28 })
      } else if (this.errorText) {
        Text(this.errorText).fontSize(12).fontColor('#E39A9A').padding(16).width('100%')
      } else if (this.lines.length === 0) {
        Text('End of file').fontSize(12).fontColor('#7F8996').padding(16)
      } else {
        List() {
          ForEach(this.lines, (line: BinaryDisplayLine) => {
            ListItem() {
              Row() {
                Text(line.offset)
                  .width(82)
                  .fontSize(11)
                  .fontFamily('monospace')
                  .fontColor('#8EA4C4')
                Row({ space: 2 }) {
                  ForEach(line.cells, (cell: BinaryByteCell) => {
                    TextInput({ text: cell.hex })
                      .width(27)
                      .height(22)
                      .padding(0)
                      .fontSize(10)
                      .fontFamily('monospace')
                      .fontColor(cell.edited ? '#EBCB8B' : '#D4D8DE')
                      .textAlign(TextAlign.Center)
                      .backgroundColor(cell.edited ? IDE_SURFACE_INPUT_COLOR : Color.Transparent)
                      .border({ width: cell.edited ? 1 : 0, color: IDE_BORDER_SUBTLE_COLOR })
                      .onChange((value: string) => this.editByte(cell, value))
                  }, (cell: BinaryByteCell): string => cell.id + ':' + cell.hex + ':' +
                    (cell.edited ? '1' : '0'))
                }
                .layoutWeight(1)
                Text(line.ascii)
                  .width(130)
                  .fontSize(11)
                  .fontFamily('monospace')
                  .fontColor('#A9B5A1')
              }
              .height(26)
              .padding({ left: 12, right: 12 })
            }
          }, (line: BinaryDisplayLine): string => line.id)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
