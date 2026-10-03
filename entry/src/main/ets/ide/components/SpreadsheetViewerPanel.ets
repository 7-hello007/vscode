import { SpreadsheetSheet } from '../document/IDEDocumentModels'
import { OOXMLParser } from '../document/IDEDocumentParsers'
import IDEDocumentRuntime from '../document/IDEDocumentRuntime'
import {
  IDE_BORDER_SUBTLE_COLOR,
  IDE_SURFACE_RAISED_COLOR,
  IDE_SURFACE_SELECTED_COLOR
} from '../theme/IDEBackgroundSurfaces'

const SHEET_COLUMN_WIDTH = 140

@Component
export default struct SpreadsheetViewerPanel {
  @Watch('onPathChanged') @Prop path: string = ''
  @Prop legacy: boolean = false
  @Require runtime: IDEDocumentRuntime
  @State sheets: SpreadsheetSheet[] = []
  @State activeSheetIndex: number = 0
  @State maxColumns: number = 1
  @State columnIndices: number[] = [0]
  @State loading: boolean = false
  @State errorText: string = ''
  private sequence: number = 0

  aboutToAppear(): void { void this.load() }
  private onPathChanged(): void { void this.load() }

  private async load(): Promise<void> {
    const request = ++this.sequence
    this.sheets = []; this.activeSheetIndex = 0; this.errorText = ''
    if (this.legacy) { this.errorText = 'Legacy .xls preview is not available. The binary file was not parsed as XLSX.'; return }
    this.loading = true
    try {
      const document = await this.runtime.prepare(this.path, true)
      const sheets = new OOXMLParser(this.runtime).parseXlsx(document)
      if (request !== this.sequence) return
      this.sheets = sheets
      this.updateColumns()
    } catch (error) { if (request === this.sequence) this.errorText = (error as Error).message }
    finally { if (request === this.sequence) this.loading = false }
  }

  private activeSheet(): SpreadsheetSheet | null {
    return this.activeSheetIndex >= 0 && this.activeSheetIndex < this.sheets.length ?
      this.sheets[this.activeSheetIndex] : null
  }

  private selectSheet(index: number): void { this.activeSheetIndex = index; this.updateColumns() }

  private updateColumns(): void {
    const sheet = this.activeSheet()
    let count = 1
    if (sheet) for (const row of sheet.rows) count = Math.max(count, row.length)
    this.maxColumns = Math.min(100, count)
    const indices: number[] = []
    for (let index = 0; index < this.maxColumns; index++) indices.push(index)
    this.columnIndices = indices
  }

  build() {
    Column() {
      Row({ space: 4 }) {
        Text(this.legacy ? 'XLS · limited preview' : 'XLSX').fontSize(10).fontColor('#AAB2BD').margin({ right: 8 })
        ForEach(this.sheets, (sheet: SpreadsheetSheet, index: number) => {
          Button(sheet.name, { buttonStyle: ButtonStyleMode.TEXTUAL })
            .height(28).fontSize(10)
            .fontColor(index === this.activeSheetIndex ? '#E2E6EC' : '#8D96A3')
            .backgroundColor(index === this.activeSheetIndex ? IDE_SURFACE_SELECTED_COLOR : Color.Transparent)
            .onClick(() => this.selectSheet(index))
        }, (sheet: SpreadsheetSheet): string => sheet.id)
      }.width('100%').height(36).padding({ left: 10, right: 8 }).backgroundColor(IDE_SURFACE_RAISED_COLOR)
      if (this.loading) {
        LoadingProgress().width(28).height(28).color('#8F98A6').margin({ top: 30 })
      } else if (this.errorText) {
        Text(this.errorText).width('100%').padding(18).fontSize(12).fontColor('#D9A0A0')
      } else if (this.activeSheet()) {
        if (this.activeSheet()!.truncated) {
          Text('Preview limited to 2,000 rows and 100 columns.')
            .width('100%').fontSize(9).fontColor('#D6B56C').padding({ left: 10, top: 3, bottom: 3 })
        }
        Scroll() {
          List() {
            ForEach(this.activeSheet()!.rows, (row: string[], rowIndex: number) => {
              ListItem() {
                Row() {
                  ForEach(this.columnIndices, (columnIndex: number) => {
                    Text(columnIndex < row.length ? row[columnIndex] : '')
                      .width(SHEET_COLUMN_WIDTH).height(30).padding({ left: 6, right: 6 })
                      .fontSize(10).fontColor('#C4CBD5').maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .border({ width: 0.5, color: IDE_BORDER_SUBTLE_COLOR })
                  }, (columnIndex: number): string => 'xlsx-cell-' + rowIndex + '-' + columnIndex)
                }.width(this.maxColumns * SHEET_COLUMN_WIDTH)
              }
            }, (row: string[], rowIndex: number): string => 'xlsx-row-' + rowIndex)
          }.width(this.maxColumns * SHEET_COLUMN_WIDTH).height('100%').backgroundColor(Color.Transparent)
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Auto)
          .width('100%').layoutWeight(1).backgroundColor(Color.Transparent)
      }
    }.width('100%').height('100%').backgroundColor(Color.Transparent)
  }
}
