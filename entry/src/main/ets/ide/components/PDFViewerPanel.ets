import { webview } from '@kit.ArkWeb'
import IDEDocumentRuntime, { IDEPreparedDocument } from '../document/IDEDocumentRuntime'
import { IDE_SURFACE_MESSAGE_COLOR } from '../theme/IDEBackgroundSurfaces'

const PDF_RESOURCE_URL = 'https://hish.local/document.pdf'

@Component
export default struct PDFViewerPanel {
  @Watch('onPathChanged') @Prop path: string = ''
  @Require runtime: IDEDocumentRuntime
  @State loading: boolean = false
  @State errorText: string = ''
  private controller: WebviewController = new webview.WebviewController()
  private webReady: boolean = false
  private prepared: IDEPreparedDocument | null = null
  private sequence: number = 0

  aboutToAppear(): void { void this.prepare() }
  private onPathChanged(): void { void this.prepare() }

  private async prepare(): Promise<void> {
    const request = ++this.sequence
    this.loading = true; this.errorText = ''; this.prepared = null
    try {
      const document = await this.runtime.prepare(this.path, false)
      if (request !== this.sequence) return
      this.prepared = document
      this.openInWeb()
    } catch (error) { if (request === this.sequence) this.errorText = (error as Error).message }
    finally { if (request === this.sequence) this.loading = false }
  }

  private openInWeb(): void {
    if (!this.webReady || !this.prepared) return
    try { this.controller.runJavaScript("window.hishPdf&&window.hishPdf.open('" + PDF_RESOURCE_URL + "')") }
    catch (error) { this.errorText = (error as Error).message }
  }

  private intercept(event: OnInterceptRequestEvent): WebResourceResponse | null {
    const response = new WebResourceResponse()
    if (event.request.getRequestUrl() !== PDF_RESOURCE_URL || !this.prepared) return null
    try {
      response.setResponseData(this.runtime.readLocalBytes(this.prepared.localPath))
      response.setResponseMimeType('application/pdf')
      response.setResponseEncoding('binary')
      response.setResponseHeader([{ headerKey: 'Access-Control-Allow-Origin', headerValue: '*' }])
      response.setResponseCode(200)
      response.setReasonMessage('OK')
      response.setResponseIsReady(true)
    } catch (error) {
      response.setResponseData('')
      response.setResponseCode(500)
      response.setReasonMessage('PDF unavailable')
      response.setResponseIsReady(true)
    }
    return response
  }

  build() {
    Stack() {
      Web({ src: $rawfile('ide/pdf/viewer.html'), controller: this.controller })
        .width('100%').height('100%').javaScriptAccess(true).domStorageAccess(false)
        .fileAccess(false).darkMode(WebDarkMode.On).forceDarkAccess(false)
        .onControllerAttached((): void => { this.webReady = true; this.openInWeb() })
        .onInterceptRequest((event: OnInterceptRequestEvent): WebResourceResponse | null => this.intercept(event))
      if (this.loading) {
        LoadingProgress().width(28).height(28).color('#8F98A6')
      } else if (this.errorText) {
        Text(this.errorText).width('100%').padding(18).fontSize(12).fontColor('#D9A0A0')
          .backgroundColor(IDE_SURFACE_MESSAGE_COLOR)
      }
    }.width('100%').height('100%').backgroundColor(Color.Transparent)
  }
}
