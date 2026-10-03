import { IDEAIContext, IDEAIMessage, IDEAIProviderInfo } from '../model/IDEAIContracts'
import { LOCAL_AI_WORKSPACE_ID, webAIProviderRegistry } from '../webai/WebAIProviderRegistry'
import AIAssistantPanel from './AIAssistantPanel'
import AIWebPanel from './AIWebPanel'
import CodingAgentPanel from './CodingAgentPanel'

const CODEX_AGENT_WORKSPACE_ID = 'agent.codex'

class AIWorkspaceMenuOption {
  value: string
  action: () => void
  enabled: boolean

  constructor(value: string, action: () => void, enabled: boolean = true) {
    this.value = value
    this.action = action
    this.enabled = enabled
  }
}

@Component
export default struct AIWorkspacePanel {
  @Prop context: IDEAIContext = new IDEAIContext('', '', '', 'plaintext', [], '')
  @Prop providers: IDEAIProviderInfo[] = []
  @Prop selectedProviderId: string = ''
  @Prop messages: IDEAIMessage[] = []
  @Prop busy: boolean = false
  @Prop preparing: boolean = false
  @Prop errorText: string = ''
  @Prop agentProjectRoot: string = '/'
  @Prop agentActiveFilePath: string = ''
  @Prop agentActiveEditorBuffer: string = ''
  @Require onProviderSelected: (id: string) => void
  @Require onSend: (prompt: string) => void
  @Require onStop: () => void
  @Require onClearConversation: () => void
  @State activeWorkspaceId: string = LOCAL_AI_WORKSPACE_ID
  @State lastWebProviderId: string = ''
  @State webStarted: boolean = false
  @State webBackRequest: number = 0
  @State webForwardRequest: number = 0
  @State webRefreshRequest: number = 0
  @State webCanGoBack: boolean = false
  @State webCanGoForward: boolean = false

  private isLocal(): boolean {
    return this.activeWorkspaceId === LOCAL_AI_WORKSPACE_ID
  }

  private isAgent(): boolean {
    return this.activeWorkspaceId === CODEX_AGENT_WORKSPACE_ID
  }

  private isWeb(): boolean {
    return !this.isLocal() && !this.isAgent()
  }

  private currentName(): string {
    if (this.isLocal()) return 'Local'
    if (this.isAgent()) return 'Codex'
    return webAIProviderRegistry.find(this.activeWorkspaceId)?.name || 'Web AI'
  }

  private selectWorkspace(id: string): void {
    if (id === LOCAL_AI_WORKSPACE_ID) {
      this.activeWorkspaceId = id
      return
    }
    if (id === CODEX_AGENT_WORKSPACE_ID) {
      this.activeWorkspaceId = id
      return
    }
    const provider = webAIProviderRegistry.find(id)
    if (!provider) return
    this.lastWebProviderId = provider.id
    this.webStarted = true
    this.activeWorkspaceId = provider.id
  }

  private providerMenu(): AIWorkspaceMenuOption[] {
    const result: AIWorkspaceMenuOption[] = []
    result.push(new AIWorkspaceMenuOption('Local', (): void => {}, false))
    result.push(new AIWorkspaceMenuOption('Local AI', (): void => this.selectWorkspace(LOCAL_AI_WORKSPACE_ID)))
    result.push(new AIWorkspaceMenuOption('Web AI', (): void => {}, false))
    for (const provider of webAIProviderRegistry.list()) {
      result.push(new AIWorkspaceMenuOption(provider.name, (): void => this.selectWorkspace(provider.id)))
    }
    result.push(new AIWorkspaceMenuOption('Agent', (): void => {}, false))
    result.push(new AIWorkspaceMenuOption('Codex', (): void => this.selectWorkspace(CODEX_AGENT_WORKSPACE_ID)))
    return result
  }

  private refreshWebProvider(): void {
    if (this.isWeb()) {
      this.webRefreshRequest++
    }
  }

  private goBackWebProvider(): void {
    if (this.isWeb() && this.webCanGoBack) {
      this.webBackRequest++
    }
  }

  private goForwardWebProvider(): void {
    if (this.isWeb() && this.webCanGoForward) {
      this.webForwardRequest++
    }
  }

  private updateWebNavigationState(canGoBack: boolean, canGoForward: boolean): void {
    this.webCanGoBack = canGoBack
    this.webCanGoForward = canGoForward
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.ide_ai_title'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#D7DAE0')
          .letterSpacing(0.6)
        Blank()
        if (this.isLocal()) {
          Button($r('app.string.ide_ai_clear_conversation'), { buttonStyle: ButtonStyleMode.TEXTUAL })
            .fontSize(9)
            .fontColor('#939CAA')
            .height(28)
            .enabled(this.messages.length > 0 && !this.busy)
            .onClick(() => this.onClearConversation())
        } else if (this.isWeb()) {
          Button({ type: ButtonType.Normal, stateEffect: true }) {
            Text('←')
              .fontSize(14)
              .fontColor('#AEB6C2')
          }
            .width(30)
            .height(28)
            .padding(0)
            .backgroundColor(Color.Transparent)
            .hoverEffect(HoverEffect.Auto)
            .opacity(this.webCanGoBack ? 1 : 0.35)
            .enabled(this.webCanGoBack)
            .onClick(() => this.goBackWebProvider())
          Button({ type: ButtonType.Normal, stateEffect: true }) {
            Text('→')
              .fontSize(14)
              .fontColor('#AEB6C2')
          }
            .width(30)
            .height(28)
            .padding(0)
            .backgroundColor(Color.Transparent)
            .hoverEffect(HoverEffect.Auto)
            .opacity(this.webCanGoForward ? 1 : 0.35)
            .enabled(this.webCanGoForward)
            .onClick(() => this.goForwardWebProvider())
          Button({ type: ButtonType.Normal, stateEffect: true }) {
            Text('↻')
              .fontSize(14)
              .fontColor('#AEB6C2')
          }
            .width(30)
            .height(28)
            .padding(0)
            .backgroundColor(Color.Transparent)
            .hoverEffect(HoverEffect.Auto)
            .onClick(() => this.refreshWebProvider())
        }
        Button(this.currentName() + ' ▼', { buttonStyle: ButtonStyleMode.TEXTUAL })
          .fontSize(10)
          .fontColor('#AEB6C2')
          .height(28)
          .backgroundColor(Color.Transparent)
          .stateEffect(true)
          .bindMenu(this.providerMenu())
      }
      .width('100%')
      .height(36)
      .padding({ left: 12, right: 10 })
      .backgroundColor('#181B20')

      Divider().strokeWidth(1).color('#30343B')

      Stack() {
        AIAssistantPanel({
          headerVisible: false,
          context: this.context,
          providers: this.providers,
          selectedProviderId: this.selectedProviderId,
          messages: this.messages,
          busy: this.busy,
          preparing: this.preparing,
          errorText: this.errorText,
          onProviderSelected: (id: string) => this.onProviderSelected(id),
          onSend: (prompt: string) => this.onSend(prompt),
          onStop: () => this.onStop(),
          onClearConversation: () => this.onClearConversation()
        })
          .visibility(this.isLocal() ? Visibility.Visible : Visibility.Hidden)

        CodingAgentPanel({
          projectRoot: this.agentProjectRoot,
          activeFilePath: this.agentActiveFilePath,
          activeEditorBuffer: this.agentActiveEditorBuffer
        })
          .visibility(this.isAgent() ? Visibility.Visible : Visibility.Hidden)

        if (this.webStarted) {
          AIWebPanel({
            providerId: this.lastWebProviderId,
            backRequest: this.webBackRequest,
            forwardRequest: this.webForwardRequest,
            refreshRequest: this.webRefreshRequest,
            onNavigationStateChanged: (canGoBack: boolean, canGoForward: boolean): void =>
              this.updateWebNavigationState(canGoBack, canGoForward)
          })
            .visibility(this.isWeb() ? Visibility.Visible : Visibility.Hidden)
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#181B20')
  }
}
