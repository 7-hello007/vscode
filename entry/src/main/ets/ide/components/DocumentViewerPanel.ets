import { DocumentParagraph, DocumentTable } from '../document/IDEDocumentModels'
import { OOXMLParser, ParsedDocx } from '../document/IDEDocumentParsers'
import IDEDocumentRuntime from '../document/IDEDocumentRuntime'
import { IDE_BORDER_SUBTLE_COLOR, IDE_SURFACE_RAISED_COLOR } from '../theme/IDEBackgroundSurfaces'

@Component
export default struct DocumentViewerPanel {
  @Watch('onPathChanged') @Prop path: string = ''
  @Prop legacy: boolean = false
  @Require runtime: IDEDocumentRuntime
  @State paragraphs: DocumentParagraph[] = []
  @State tables: DocumentTable[] = []
  @State imageUris: string[] = []
  @State loading: boolean = false
  @State errorText: string = ''
  private sequence: number = 0

  aboutToAppear(): void { void this.load() }
  private onPathChanged(): void { void this.load() }

  private async load(): Promise<void> {
    const request = ++this.sequence
    this.paragraphs = []; this.tables = []; this.imageUris = []; this.errorText = ''
    if (this.legacy) { this.errorText = 'Legacy .doc preview is not available. The binary file was not parsed as DOCX.'; return }
    this.loading = true
    try {
      const document = await this.runtime.prepare(this.path, true)
      const parsed: ParsedDocx = new OOXMLParser(this.runtime).parseDocx(document)
      if (request !== this.sequence) return
      this.paragraphs = parsed.paragraphs; this.tables = parsed.tables; this.imageUris = parsed.imageUris
    } catch (error) {
      if (request === this.sequence) this.errorText = (error as Error).message
    } finally { if (request === this.sequence) this.loading = false }
  }

  build() {
    Column() {
      Row() {
        Text(this.legacy ? 'DOC · limited preview' : 'DOCX · local OOXML preview')
          .fontSize(10).fontColor('#AAB2BD')
      }.width('100%').height(34).padding({ left: 12 }).backgroundColor(IDE_SURFACE_RAISED_COLOR)
      if (this.loading) {
        LoadingProgress().width(28).height(28).color('#8F98A6').margin({ top: 30 })
      } else if (this.errorText) {
        Text(this.errorText).width('100%').padding(18).fontSize(12).fontColor('#D9A0A0')
      } else {
        List({ space: 5 }) {
          ForEach(this.paragraphs, (paragraph: DocumentParagraph) => {
            ListItem() {
              Row({ space: 7 }) {
                if (paragraph.list) Text('•').fontSize(13).fontColor('#8EA4C4')
                Text(paragraph.text).layoutWeight(1)
                  .fontSize(paragraph.headingLevel > 0 ? Math.max(15, 22 - paragraph.headingLevel) : 12)
                  .fontWeight(paragraph.headingLevel > 0 || paragraph.bold ? FontWeight.Bold : FontWeight.Normal)
                  .fontStyle(paragraph.italic ? FontStyle.Italic : FontStyle.Normal)
                  .fontColor('#D9DDE4').lineHeight(19)
              }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 4 })
            }
          }, (paragraph: DocumentParagraph): string => paragraph.id)
          ForEach(this.tables, (table: DocumentTable) => {
            ListItem() {
              Column() {
                ForEach(table.rows, (row: string[], rowIndex: number) => {
                  Row() {
                    ForEach(row, (cell: string, columnIndex: number) => {
                      Text(cell).layoutWeight(1).padding(6).fontSize(10).fontColor('#C6CDD7')
                        .border({ width: 0.5, color: IDE_BORDER_SUBTLE_COLOR })
                    }, (cell: string, columnIndex: number): string => table.id + '-' + rowIndex + '-' + columnIndex)
                  }.width('100%')
                }, (row: string[], rowIndex: number): string => table.id + '-row-' + rowIndex)
              }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
            }
          }, (table: DocumentTable): string => table.id)
          ForEach(this.imageUris, (uri: string, index: number) => {
            ListItem() {
              Image(uri).width('100%').height(260).objectFit(ImageFit.Contain)
                .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            }
          }, (uri: string, index: number): string => 'docx-image-' + index)
        }.width('100%').layoutWeight(1).backgroundColor(Color.Transparent)
      }
    }.width('100%').height('100%').backgroundColor(Color.Transparent)
  }
}
