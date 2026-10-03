import {
  IDEAIContext,
  IDEAIMessage,
  IDEAIMessageRole,
  IDEAIProviderInfo,
  IDEAIProviderKind
} from '../model/IDEAIContracts'
import {
  IDE_BORDER_SUBTLE_COLOR,
  IDE_SURFACE_COLOR,
  IDE_SURFACE_INPUT_COLOR,
  IDE_SURFACE_MESSAGE_COLOR,
  IDE_SURFACE_SELECTED_COLOR,
  IDE_SURFACE_TOOLBAR_COLOR
} from '../theme/IDEBackgroundSurfaces'

class AIProviderMenuOption {
  value: string = ''
  action: () => void = () => {}
}

@Component
export default struct AIAssistantPanel {
  @Prop headerVisible: boolean = true
  @Prop context: IDEAIContext = new IDEAIContext('', '', '', 'plaintext', [], '')
  @Prop providers: IDEAIProviderInfo[] = []
  @Prop selectedProviderId: string = ''
  @Prop messages: IDEAIMessage[] = []
  @Prop busy: boolean = false
  @Prop preparing: boolean = false
  @Prop errorText: string = ''
  @Require onProviderSelected: (id: string) => void
  @Require onSend: (prompt: string) => void
  @Require onStop: () => void
  @Require onClearConversation: () => void
  @State prompt: string = ''

  private selectedProvider(): IDEAIProviderInfo | null {
    for (const provider of this.providers) {
      if (provider.id === this.selectedProviderId) {
        return provider
      }
    }
    return null
  }

  private providerMenu(): AIProviderMenuOption[] {
    const options: AIProviderMenuOption[] = []
    for (const provider of this.providers) {
      options.push({
        value: provider.name + (provider.kind === IDEAIProviderKind.LOCAL ? ' · Local' : ' · Cloud'),
        action: (): void => this.onProviderSelected(provider.id)
      })
    }
    return options
  }

  private submit(): void {
    const value = this.prompt.trim()
    const provider = this.selectedProvider()
    if (!value || !provider?.available || this.busy) {
      return
    }
    this.onSend(value)
    this.prompt = ''
  }

  private contextFileLabel(): string {
    return this.context.activeFilePath.substring(this.context.activeFilePath.lastIndexOf('/') + 1)
  }

  @Builder
  private messageBubble(message: IDEAIMessage) {
    Column({ space: 4 }) {
      Text(message.role === IDEAIMessageRole.USER ? $r('app.string.ide_ai_you') :
        message.role === IDEAIMessageRole.ASSISTANT ? $r('app.string.ide_ai_assistant') :
          $r('app.string.ide_ai_system'))
        .fontSize(9)
        .fontColor('#7E8794')
      Text(message.content)
        .fontSize(11)
        .fontColor('#D7DAE0')
        .lineHeight(17)
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(9)
    .borderRadius(6)
    .backgroundColor(message.role === IDEAIMessageRole.USER ?
      IDE_SURFACE_SELECTED_COLOR : IDE_SURFACE_MESSAGE_COLOR)
    .border({ width: 1, color: IDE_BORDER_SUBTLE_COLOR })
  }

  build() {
    Column() {
      if (this.headerVisible) {
        Row() {
          Text($r('app.string.ide_ai_title'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#D7DAE0')
            .letterSpacing(0.6)
          Blank()
          Button($r('app.string.ide_ai_clear_conversation'), { buttonStyle: ButtonStyleMode.TEXTUAL })
            .fontSize(9)
            .fontColor('#939CAA')
            .height(28)
            .enabled(this.messages.length > 0 && !this.busy)
            .onClick(() => this.onClearConversation())
          if (this.providers.length > 0) {
            Button(this.selectedProvider()?.name || $r('app.string.ide_ai_choose_provider'),
              { buttonStyle: ButtonStyleMode.TEXTUAL })
              .fontSize(10)
              .fontColor('#AEB6C2')
              .height(28)
              .bindMenu(this.providerMenu())
          } else {
            Text($r('app.string.ide_ai_no_provider'))
              .fontSize(9)
              .fontColor('#D09A61')
          }
        }
        .width('100%')
        .height(36)
        .padding({ left: 12, right: 10 })

        Divider().strokeWidth(1).color('#30343B')
      }

      Column({ space: 5 }) {
        if (this.context.activeFilePath) {
          Text(this.contextFileLabel() + ' · ' + this.context.language)
            .fontSize(10)
            .fontColor('#B7C1CE')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          Text($r('app.string.ide_ai_no_active_file'))
            .fontSize(10)
            .fontColor('#B7C1CE')
        }
        Text($r('app.string.ide_ai_context_file'))
          .fontSize(9)
          .fontColor('#7E8794')
        Text((this.getUIContext().getHostContext()?.resourceManager
          .getStringByNameSync('ide_ai_context_open_files') || 'Open files') + ': ' +
          this.context.openedFiles.length)
          .fontSize(9)
          .fontColor('#7E8794')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor(IDE_SURFACE_TOOLBAR_COLOR)
      .border({ width: { bottom: 1 }, color: IDE_BORDER_SUBTLE_COLOR })

      if (this.messages.length === 0) {
        Column({ space: 9 }) {
          Text('AI')
            .width(38)
            .height(38)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#AEB6C2')
            .textAlign(TextAlign.Center)
            .border({ width: 1, color: '#505762' })
            .borderRadius(19)
          Text(this.errorText ? $r('app.string.ide_ai_local_error_title') :
            this.preparing ? $r('app.string.ide_ai_preparing_model') :
              this.selectedProvider()?.available ? $r('app.string.ide_ai_local_ready_title') :
                $r('app.string.ide_ai_ready_title'))
            .fontSize(13)
            .fontColor('#D7DAE0')
          Text(this.errorText ? $r('app.string.ide_ai_local_error_hint') :
            this.preparing ? $r('app.string.ide_ai_local_preparing_hint') :
              this.selectedProvider()?.available ? $r('app.string.ide_ai_local_ready_hint') :
                $r('app.string.ide_ai_ready_hint'))
            .fontSize(10)
            .fontColor('#8F98A6')
            .textAlign(TextAlign.Center)
            .lineHeight(16)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16 })
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.messages, (message: IDEAIMessage) => {
            ListItem() {
              this.messageBubble(message)
            }
          }, (message: IDEAIMessage): string => message.id)
        }
        .layoutWeight(1)
        .width('100%')
        .padding(8)
        .edgeEffect(EdgeEffect.Spring)
      }

      if (this.preparing) {
        Row({ space: 7 }) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color('#AEB6C2')
          Text($r('app.string.ide_ai_preparing_model'))
            .fontSize(10)
            .fontColor('#AEB6C2')
        }
        .width('100%')
        .padding({ left: 10, right: 10, bottom: 6 })
      }
      if (this.errorText) {
        Text(this.errorText)
          .width('100%')
          .padding({ left: 10, right: 10, bottom: 6 })
          .fontSize(10)
          .fontColor('#E08A8A')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Row({ space: 7 }) {
        TextInput({ text: this.prompt, placeholder: $r('app.string.ide_ai_input_placeholder') })
          .layoutWeight(1)
          .height(34)
          .fontSize(11)
          .backgroundColor(IDE_SURFACE_INPUT_COLOR)
          .border({ width: 1, color: IDE_BORDER_SUBTLE_COLOR })
          .borderRadius(6)
          .onChange((value: string) => this.prompt = value)
          .onSubmit(() => this.submit())
        Button(this.busy ? $r('app.string.ide_ai_thinking') : $r('app.string.ide_ai_send'))
          .height(34)
          .fontSize(10)
          .enabled(!!this.prompt.trim() && (this.selectedProvider()?.available || false) && !this.busy)
          .onClick(() => this.submit())
        if (this.busy) {
          Button($r('app.string.ide_ai_stop'), { buttonStyle: ButtonStyleMode.TEXTUAL })
            .height(34)
            .fontSize(10)
            .fontColor('#D7DAE0')
            .onClick(() => this.onStop())
        }
      }
      .width('100%')
      .padding({ left: 8, right: 8, bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(IDE_SURFACE_COLOR)
  }
}
