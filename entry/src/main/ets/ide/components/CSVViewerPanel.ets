import { CsvPage } from '../document/IDEDocumentModels'
import { OOXMLParser } from '../document/IDEDocumentParsers'
import IDEDocumentRuntime from '../document/IDEDocumentRuntime'
import {
  IDE_BORDER_SUBTLE_COLOR,
  IDE_SURFACE_RAISED_COLOR,
  IDE_SURFACE_SELECTED_COLOR
} from '../theme/IDEBackgroundSurfaces'

const CSV_COLUMN_WIDTH = 150

@Component
export default struct CSVViewerPanel {
  @Watch('onContentChanged') @Prop content: string = ''
  @Prop path: string = ''
  @Require runtime: IDEDocumentRuntime
  @Require onViewText: (path: string) => void
  @State page: CsvPage = new CsvPage([], ',', false)
  @State maxColumns: number = 1
  @State columnIndices: number[] = [0]

  aboutToAppear(): void { this.parse() }
  private onContentChanged(): void { this.parse() }

  private parse(): void {
    this.page = new OOXMLParser(this.runtime).parseCsv(this.content)
    let maximum = 1
    for (const row of this.page.rows) maximum = Math.max(maximum, row.length)
    this.maxColumns = Math.min(100, maximum)
    const indices: number[] = []
    for (let index = 0; index < this.maxColumns; index++) indices.push(index)
    this.columnIndices = indices
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('View Table').fontSize(11).fontColor('#E1E5EA').fontWeight(FontWeight.Medium)
        Button('View Text', { buttonStyle: ButtonStyleMode.TEXTUAL })
          .fontSize(10).height(28).backgroundColor(Color.Transparent)
          .onClick(() => this.onViewText(this.path))
        Blank()
        Text((this.page.delimiter === '\t' ? 'TAB' : this.page.delimiter) + ' · ' + this.page.rows.length + ' rows')
          .fontSize(9).fontColor('#87909D')
      }
      .width('100%').height(36).padding({ left: 12, right: 10 }).backgroundColor(IDE_SURFACE_RAISED_COLOR)
      if (this.page.truncated) {
        Text('Preview limited to the first 2,000 rows and 100 columns.')
          .width('100%').fontSize(9).fontColor('#D6B56C').padding({ left: 12, top: 3, bottom: 3 })
      }
      Scroll() {
        List() {
          ForEach(this.page.rows, (row: string[], rowIndex: number) => {
            ListItem() {
              Row() {
                ForEach(this.columnIndices,
                  (columnIndex: number) => {
                    Text(columnIndex < row.length ? row[columnIndex] : '')
                      .width(CSV_COLUMN_WIDTH).height(30).padding({ left: 7, right: 7 })
                      .fontSize(10).fontColor(rowIndex === 0 ? '#E3E7ED' : '#BAC2CD')
                      .fontWeight(rowIndex === 0 ? FontWeight.Medium : FontWeight.Normal)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .border({ width: 0.5, color: IDE_BORDER_SUBTLE_COLOR })
                  }, (columnIndex: number): string => 'csv-cell-' + rowIndex + '-' + columnIndex)
              }
              .width(this.maxColumns * CSV_COLUMN_WIDTH)
              .backgroundColor(rowIndex === 0 ? IDE_SURFACE_SELECTED_COLOR : Color.Transparent)
            }
          }, (row: string[], rowIndex: number): string => 'csv-row-' + rowIndex)
        }
        .width(this.maxColumns * CSV_COLUMN_WIDTH).height('100%').backgroundColor(Color.Transparent)
      }
      .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Auto)
      .width('100%').layoutWeight(1).backgroundColor(Color.Transparent)
    }
    .width('100%').height('100%').backgroundColor(Color.Transparent)
  }
}
