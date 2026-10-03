import {
  CodingAgentApprovalKind,
  CodingAgentApprovalRequest,
  CodingAgentContext,
  CodingAgentDiffPreview,
  CodingAgentMessage,
  CodingAgentMessageRole,
  CodingAgentSnapshot,
  CodingAgentState,
  CodingAgentTask,
  CodingAgentToolActivity
} from '../agent/CodingAgentContracts'
import { CODEX_AGENT_PROVIDER_ID } from '../agent/CodexAgentProvider'
import { codingAgentProviderRegistry } from '../agent/CodingAgentProviderRegistry'

const CODEX_PANEL_SUBSCRIBER = 'IDE.CodingAgentPanel'
const codexAgentProvider = codingAgentProviderRegistry.find(CODEX_AGENT_PROVIDER_ID)!

@Component
export default struct CodingAgentPanel {
  @Prop projectRoot: string = '/'
  @Prop activeFilePath: string = ''
  @Prop activeEditorBuffer: string = ''
  @State state: CodingAgentState = CodingAgentState.IDLE
  @State sessionId: string = ''
  @State messages: CodingAgentMessage[] = []
  @State activities: CodingAgentToolActivity[] = []
  @State pendingApproval: CodingAgentApprovalRequest | null = null
  @State errorText: string = ''
  @State configured: boolean = false
  @State prompt: string = ''
  private snapshotListener = (snapshot: CodingAgentSnapshot): void => this.applySnapshot(snapshot)

  aboutToAppear(): void {
    codexAgentProvider.subscribe(CODEX_PANEL_SUBSCRIBER, this.snapshotListener)
  }

  aboutToDisappear(): void {
    codexAgentProvider.unsubscribe(CODEX_PANEL_SUBSCRIBER)
  }

  private applySnapshot(snapshot: CodingAgentSnapshot): void {
    this.state = snapshot.state
    this.sessionId = snapshot.sessionId
    this.messages = snapshot.messages
    this.activities = snapshot.activities
    this.pendingApproval = snapshot.pendingApproval
    this.errorText = snapshot.error
    this.configured = snapshot.configured
  }

  private isBusy(): boolean {
    return this.state === CodingAgentState.THINKING || this.state === CodingAgentState.READING ||
      this.state === CodingAgentState.EDITING || this.state === CodingAgentState.WAITING_APPROVAL ||
      this.state === CodingAgentState.RUNNING_COMMAND
  }

  private send(): void {
    const text = this.prompt.trim()
    if (!text || !this.configured || this.isBusy()) return
    this.prompt = ''
    void codexAgentProvider.start(new CodingAgentTask(text,
      new CodingAgentContext(this.projectRoot, this.activeFilePath, this.activeEditorBuffer)))
  }

  private approve(): void {
    if (this.pendingApproval) void codexAgentProvider.approve(this.pendingApproval.id)
  }

  private reject(): void {
    if (this.pendingApproval) void codexAgentProvider.reject(this.pendingApproval.id)
  }

  private messageColor(role: CodingAgentMessageRole): ResourceColor {
    if (role === CodingAgentMessageRole.USER) return '#8EC5FF'
    if (role === CodingAgentMessageRole.SYSTEM) return '#E0A86A'
    return '#D7DAE0'
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('Codex Agent')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#D7DAE0')
        Text(this.state)
          .fontSize(9)
          .fontColor(this.state === CodingAgentState.FAILED ? '#E06C75' : '#8C96A5')
        Blank()
        if (this.sessionId) {
          Text(this.sessionId)
            .fontSize(8)
            .fontColor('#636D7B')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .height(30)

      if (!this.configured) {
        Column({ space: 8 }) {
          Text('NOT_CONFIGURED')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#D1A85A')
          Text('需要可信 HiSH 后端与已登录的应用会话。OpenAI API Key 只能保存在服务端，' +
            '不会写入 HAP、Preferences、日志或 Git。')
            .fontSize(10)
            .fontColor('#9DA6B3')
            .lineHeight(17)
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#20242A')
      }

      if (this.errorText && this.errorText !== 'NOT_CONFIGURED') {
        Text(this.errorText)
          .fontSize(10)
          .fontColor('#E06C75')
          .width('100%')
          .padding({ top: 6, bottom: 6 })
      }

      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.messages, (message: CodingAgentMessage) => {
            Column({ space: 4 }) {
              Text(message.role === CodingAgentMessageRole.USER ? 'You' :
                (message.role === CodingAgentMessageRole.ASSISTANT ? 'Codex' : 'System'))
                .fontSize(9)
                .fontColor('#737E8D')
              Text(message.content)
                .fontSize(11)
                .fontColor(this.messageColor(message.role))
                .lineHeight(18)
                .copyOption(CopyOptions.LocalDevice)
            }
            .width('100%')
            .padding(8)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor(message.role === CodingAgentMessageRole.USER ? '#1E2731' : '#1B1F25')
          }, (message: CodingAgentMessage): string => message.id)

          if (this.activities.length > 0) {
            Column({ space: 5 }) {
              Text('Tool activity')
                .fontSize(9)
                .fontColor('#737E8D')
              ForEach(this.activities, (activity: CodingAgentToolActivity) => {
                Text(activity.tool + '  ' + activity.status + '  ' + activity.summary)
                  .fontSize(9)
                  .fontColor('#9DA6B3')
                  .width('100%')
              }, (activity: CodingAgentToolActivity): string => activity.id)
            }
            .width('100%')
            .padding(8)
            .backgroundColor('#171A1F')
          }

          if (this.pendingApproval) {
            Column({ space: 8 }) {
              Text(this.pendingApproval.title)
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor('#E4C07A')
              if (this.pendingApproval.kind === CodingAgentApprovalKind.COMMAND) {
                Text(this.pendingApproval.command)
                  .fontSize(10)
                  .fontFamily('monospace')
                  .fontColor('#D7DAE0')
                  .copyOption(CopyOptions.LocalDevice)
              } else {
                ForEach(this.pendingApproval.diffs, (diff: CodingAgentDiffPreview) => {
                  Column({ space: 5 }) {
                    Text(diff.path + '  ' + diff.location)
                      .fontSize(9)
                      .fontColor('#AEB6C2')
                    Text('Before\n' + diff.before)
                      .fontSize(9)
                      .fontColor('#D98B8B')
                      .fontFamily('monospace')
                      .copyOption(CopyOptions.LocalDevice)
                    Text('After\n' + diff.after)
                      .fontSize(9)
                      .fontColor('#8FD19E')
                      .fontFamily('monospace')
                      .copyOption(CopyOptions.LocalDevice)
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }, (diff: CodingAgentDiffPreview): string => diff.path + ':' + diff.location)
              }
              Row({ space: 8 }) {
                Button('Apply', { buttonStyle: ButtonStyleMode.TEXTUAL })
                  .fontSize(10)
                  .onClick((): void => this.approve())
                Button('Reject', { buttonStyle: ButtonStyleMode.TEXTUAL })
                  .fontSize(10)
                  .onClick((): void => this.reject())
              }
            }
            .width('100%')
            .padding(10)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor('#25231D')
            .border({ width: 1, color: '#5B5038' })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)

      TextArea({ text: this.prompt, placeholder: '描述要检查、修改或运行的任务' })
        .width('100%')
        .height(72)
        .fontSize(11)
        .fontColor('#D7DAE0')
        .placeholderColor('#697382')
        .backgroundColor('#20242A')
        .enabled(true)
        .onChange((value: string): void => {
          this.prompt = value
        })

      Row({ space: 8 }) {
        Button('Send', { buttonStyle: ButtonStyleMode.TEXTUAL })
          .fontSize(10)
          .enabled(this.configured && !!this.prompt.trim() && !this.isBusy())
          .onClick((): void => this.send())
        Button('Stop', { buttonStyle: ButtonStyleMode.TEXTUAL })
          .fontSize(10)
          .enabled(this.isBusy())
          .onClick((): void => codexAgentProvider.stop())
        Blank()
        Text('Root: ' + this.projectRoot)
          .fontSize(8)
          .fontColor('#626C79')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(34)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 10, right: 10, bottom: 8 })
    .backgroundColor('#181B20')
  }
}
