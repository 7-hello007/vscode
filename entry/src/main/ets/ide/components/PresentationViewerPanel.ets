import { PresentationSlide } from '../document/IDEDocumentModels'
import { OOXMLParser } from '../document/IDEDocumentParsers'
import IDEDocumentRuntime from '../document/IDEDocumentRuntime'
import {
  IDE_BORDER_SUBTLE_COLOR,
  IDE_SURFACE_MESSAGE_COLOR,
  IDE_SURFACE_RAISED_COLOR,
  IDE_SURFACE_SELECTED_COLOR
} from '../theme/IDEBackgroundSurfaces'

@Component
export default struct PresentationViewerPanel {
  @Watch('onPathChanged') @Prop path: string = ''
  @Prop legacy: boolean = false
  @Require runtime: IDEDocumentRuntime
  @State slides: PresentationSlide[] = []
  @State activeIndex: number = 0
  @State loading: boolean = false
  @State errorText: string = ''
  private sequence: number = 0

  aboutToAppear(): void { void this.load() }
  private onPathChanged(): void { void this.load() }

  private async load(): Promise<void> {
    const request = ++this.sequence
    this.slides = []; this.activeIndex = 0; this.errorText = ''
    if (this.legacy) { this.errorText = 'Legacy .ppt preview is not available. The binary file was not parsed as PPTX.'; return }
    this.loading = true
    try {
      const document = await this.runtime.prepare(this.path, true)
      const slides = new OOXMLParser(this.runtime).parsePptx(document)
      if (request === this.sequence) this.slides = slides
    } catch (error) { if (request === this.sequence) this.errorText = (error as Error).message }
    finally { if (request === this.sequence) this.loading = false }
  }

  private activeSlide(): PresentationSlide | null {
    return this.activeIndex >= 0 && this.activeIndex < this.slides.length ? this.slides[this.activeIndex] : null
  }

  build() {
    Column() {
      Row({ space: 6 }) {
        Text(this.legacy ? 'PPT · limited preview' : 'PPTX · local preview').fontSize(10).fontColor('#AAB2BD')
        Blank()
        Text(this.slides.length > 0 ? (this.activeIndex + 1) + ' / ' + this.slides.length : '0 / 0')
          .fontSize(10).fontColor('#9AA4B1')
      }.width('100%').height(36).padding({ left: 12, right: 12 }).backgroundColor(IDE_SURFACE_RAISED_COLOR)
      if (this.loading) {
        LoadingProgress().width(28).height(28).color('#8F98A6').margin({ top: 30 })
      } else if (this.errorText) {
        Text(this.errorText).width('100%').padding(18).fontSize(12).fontColor('#D9A0A0')
      } else {
        Row() {
          List({ space: 5 }) {
            ForEach(this.slides, (slide: PresentationSlide, index: number) => {
              ListItem() {
                Column({ space: 3 }) {
                  Text('Slide ' + slide.number).fontSize(10).fontColor('#D7DCE4')
                  Text(slide.texts.join(' ')).fontSize(8).fontColor('#87919E').maxLines(3)
                }.width('100%').height(70).padding(7)
                  .backgroundColor(index === this.activeIndex ? IDE_SURFACE_SELECTED_COLOR : IDE_SURFACE_MESSAGE_COLOR)
                  .border({ width: 1, color: IDE_BORDER_SUBTLE_COLOR })
              }.onClick(() => this.activeIndex = index)
            }, (slide: PresentationSlide): string => slide.id)
          }.width(130).height('100%').padding(7).backgroundColor(Color.Transparent)
          Scroll() {
            if (this.activeSlide()) {
              Column({ space: 12 }) {
                ForEach(this.activeSlide()!.texts, (text: string, index: number) => {
                  Text(text).width('100%').fontSize(index === 0 ? 20 : 13)
                    .fontWeight(index === 0 ? FontWeight.Bold : FontWeight.Normal)
                    .fontColor('#E0E4EA').textAlign(TextAlign.Center)
                }, (text: string, index: number): string => 'ppt-text-' + this.activeIndex + '-' + index)
                ForEach(this.activeSlide()!.imageUris, (uri: string, index: number) => {
                  Image(uri).width('100%').height(240).objectFit(ImageFit.Contain)
                }, (uri: string, index: number): string => 'ppt-image-' + this.activeIndex + '-' + index)
              }.width('100%').constraintSize({ minHeight: 420 }).padding(28)
                .backgroundColor(IDE_SURFACE_MESSAGE_COLOR)
                .border({ width: 1, color: IDE_BORDER_SUBTLE_COLOR })
            }
          }.scrollBar(BarState.Auto).layoutWeight(1).height('100%').padding(12).backgroundColor(Color.Transparent)
        }.width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').backgroundColor(Color.Transparent)
  }
}
