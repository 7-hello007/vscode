import { common, Want } from '@kit.AbilityKit'
import { picker } from '@kit.CoreFileKit'
import { webview } from '@kit.ArkWeb'
import { WebAIProvider, webAIProviderRegistry } from '../webai/WebAIProviderRegistry'
import {
  IDE_BORDER_SUBTLE_COLOR,
  IDE_SURFACE_COLOR,
  IDE_SURFACE_MESSAGE_COLOR,
  IDE_SURFACE_RAISED_COLOR
} from '../theme/IDEBackgroundSurfaces'

enum WebAILoadState {
  LOADING = 0,
  READY = 1,
  LOAD_FAILED = 2,
  UNSUPPORTED = 3
}

@Component
export default struct AIWebPanel {
  @Watch('onProviderChanged') @Prop providerId: string = ''
  @Watch('onBackRequested') @Prop backRequest: number = 0
  @Watch('onForwardRequested') @Prop forwardRequest: number = 0
  @Watch('onRefreshRequested') @Prop refreshRequest: number = 0
  @Require onNavigationStateChanged: (canGoBack: boolean, canGoForward: boolean) => void
  @Require onChooseHiSHUploadFiles: () => Promise<string[]>
  @State loadState: WebAILoadState = WebAILoadState.LOADING
  @State errorText: string = ''
  @State canGoBack: boolean = false
  @State canGoForward: boolean = false
  private controller: WebviewController = new webview.WebviewController()
  private controllerAttached: boolean = false
  private providerUrls: Map<string, string> = new Map<string, string>()
  private fileSelectionInFlight: boolean = false

  private provider(): WebAIProvider | null {
    return webAIProviderRegistry.find(this.providerId)
  }

  private initialUrl(): string {
    return this.provider()?.homeUrl || 'about:blank'
  }

  private onProviderChanged(): void {
    const provider = this.provider()
    if (!provider) {
      this.loadState = WebAILoadState.UNSUPPORTED
      this.errorText = 'Unknown Web AI provider'
      return
    }
    this.loadState = WebAILoadState.LOADING
    this.errorText = ''
    this.canGoBack = false
    this.canGoForward = false
    this.onNavigationStateChanged(false, false)
    if (!this.controllerAttached) return
    try {
      this.controller.loadUrl(this.providerUrls.get(provider.id) || provider.homeUrl)
    } catch (error) {
      this.fail((error as Error).message)
    }
  }

  private onBackRequested(): void {
    if (this.backRequest > 0) {
      this.goBack()
    }
  }

  private onForwardRequested(): void {
    if (this.forwardRequest > 0) {
      this.goForward()
    }
  }

  private onRefreshRequested(): void {
    if (this.refreshRequest > 0) {
      this.reload()
    }
  }

  private updateNavigationState(): void {
    if (!this.controllerAttached) return
    try {
      this.canGoBack = this.controller.accessBackward()
      this.canGoForward = this.controller.accessForward()
    } catch (error) {
      this.canGoBack = false
      this.canGoForward = false
    }
    this.onNavigationStateChanged(this.canGoBack, this.canGoForward)
  }

  private goBack(): void {
    if (!this.canGoBack) return
    try {
      this.controller.backward()
    } catch (error) {
      this.fail((error as Error).message)
    }
  }

  private goForward(): void {
    if (!this.canGoForward) return
    try {
      this.controller.forward()
    } catch (error) {
      this.fail((error as Error).message)
    }
  }

  private reload(): void {
    const provider = this.provider()
    if (!provider || !this.controllerAttached) return
    this.loadState = WebAILoadState.LOADING
    this.errorText = ''
    try {
      this.controller.refresh()
    } catch (error) {
      try {
        this.controller.loadUrl(this.providerUrls.get(provider.id) || provider.homeUrl)
      } catch (loadError) {
        this.fail((loadError as Error).message)
      }
    }
  }

  private fail(message: string): void {
    this.loadState = WebAILoadState.LOAD_FAILED
    this.errorText = message || 'Page load failed'
    this.updateNavigationState()
  }

  private shouldOverride(request: WebResourceRequest): boolean {
    if (!request.isMainFrame()) return false
    const targetUrl = request.getRequestUrl()
    if (webAIProviderRegistry.isAllowedNavigation(this.providerId, targetUrl)) return false
    void this.openExternal(targetUrl)
    return true
  }

  private async openExternal(targetUrl: string): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: targetUrl,
        parameters: { bundleName: context.abilityInfo.bundleName }
      }
      await context.startAbility(want)
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.ide_web_ai_external_link')
      })
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.ide_web_ai_external_failed')
      })
    }
  }

  private async chooseDeviceFiles(multiple: boolean): Promise<string[]> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext
    const options = new picker.DocumentSelectOptions()
    options.maxSelectNumber = multiple ? 9 : 1
    return await new picker.DocumentViewPicker(context).select(options)
  }

  private async handleFileSelector(event: OnShowFileSelectorEvent): Promise<void> {
    if (this.fileSelectionInFlight) {
      event.result.handleFileList([])
      return
    }
    this.fileSelectionInFlight = true
    try {
      const response = await this.getUIContext().getPromptAction().showActionMenu({
        title: 'Choose upload source',
        buttons: [
          { text: 'HiSH Files', color: '#D7DAE0' },
          { text: 'Device Files', color: '#D7DAE0' }
        ]
      })
      let files: string[] = []
      if (response.index === 0) {
        files = await this.onChooseHiSHUploadFiles()
      } else if (response.index === 1) {
        files = await this.chooseDeviceFiles(event.fileSelector.getMode() === FileSelectorMode.FileOpenMultipleMode)
      }
      event.result.handleFileList(files)
    } catch (error) {
      event.result.handleFileList([])
    } finally {
      this.fileSelectionInFlight = false
    }
  }

  build() {
    Column() {
      Stack() {
        Web({ src: this.initialUrl(), controller: this.controller })
          .width('100%')
          .height('100%')
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .fileAccess(false)
          .darkMode(WebDarkMode.On)
          .forceDarkAccess(false)
          .multiWindowAccess(false)
          .onControllerAttached((): void => {
            this.controllerAttached = true
          })
          .onPageBegin((_event: OnPageBeginEvent): void => {
            this.loadState = WebAILoadState.LOADING
            this.errorText = ''
          })
          .onPageEnd((event: OnPageEndEvent): void => {
            if (webAIProviderRegistry.isAllowedNavigation(this.providerId, event.url)) {
              this.providerUrls.set(this.providerId, event.url)
            }
            this.loadState = WebAILoadState.READY
            this.updateNavigationState()
          })
          .onErrorReceive((event: OnErrorReceiveEvent): void => {
            if (event.request.isMainFrame()) {
              this.fail(event.error.getErrorInfo() + ' (' + event.error.getErrorCode() + ')')
            }
          })
          .onOverrideUrlLoading((request: WebResourceRequest): boolean => this.shouldOverride(request))
          .onShowFileSelector((event: OnShowFileSelectorEvent): boolean => {
            void this.handleFileSelector(event)
            return true
          })

        if (this.loadState === WebAILoadState.LOADING) {
          Column({ space: 8 }) {
            LoadingProgress()
              .width(22)
              .height(22)
              .color('#AEB6C2')
            Text($r('app.string.ide_web_ai_loading'))
              .fontSize(10)
              .fontColor('#AEB6C2')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(IDE_SURFACE_MESSAGE_COLOR)
        } else if (this.loadState === WebAILoadState.LOAD_FAILED ||
          this.loadState === WebAILoadState.UNSUPPORTED) {
          Column({ space: 9 }) {
            Text(this.provider()?.name || 'Web AI')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#D7DAE0')
            Text(this.loadState === WebAILoadState.UNSUPPORTED ?
              $r('app.string.ide_web_ai_unsupported') : $r('app.string.ide_web_ai_load_failed'))
              .fontSize(10)
              .fontColor('#E08A8A')
            Text(this.errorText)
              .fontSize(9)
              .fontColor('#939CAA')
              .maxLines(4)
              .textAlign(TextAlign.Center)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Button($r('app.string.ide_web_ai_retry'))
              .height(30)
              .fontSize(10)
              .onClick(() => this.reload())
          }
          .width('100%')
          .height('100%')
          .padding(16)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(IDE_SURFACE_RAISED_COLOR)
          .border({ width: 1, color: IDE_BORDER_SUBTLE_COLOR })
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(IDE_SURFACE_COLOR)
  }
}
