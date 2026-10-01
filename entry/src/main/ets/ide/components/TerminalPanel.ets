import WebTerminal from '../../components/WebTerminal'
import { terminalOutputBridge } from '../../lib/TerminalOutputBridge'

const IDE_TERMINAL_OUTPUT_SUBSCRIBER = 'IDE.TerminalPanel.AIContext'

@Component
export default struct TerminalPanel {
  @Require virtKeyEnabled: boolean
  @Require onRun: () => void
  @Prop canRun: boolean = false
  @Prop running: boolean = false
  @Require onOutput: (text: string) => void
  private pendingOutput: string = ''
  private outputTimer: number | undefined = undefined
  private outputListener: (text: string) => void = (text: string): void => this.captureOutput(text)

  aboutToAppear(): void {
    terminalOutputBridge.subscribe(IDE_TERMINAL_OUTPUT_SUBSCRIBER, this.outputListener)
  }

  aboutToDisappear(): void {
    terminalOutputBridge.unsubscribe(IDE_TERMINAL_OUTPUT_SUBSCRIBER)
    if (this.outputTimer !== undefined) {
      clearTimeout(this.outputTimer)
      this.outputTimer = undefined
    }
    this.pendingOutput = ''
  }

  private captureOutput(text: string): void {
    this.pendingOutput += text
    if (this.outputTimer !== undefined) {
      return
    }
    this.outputTimer = setTimeout((): void => {
      const output = this.pendingOutput
      this.pendingOutput = ''
      this.outputTimer = undefined
      if (output) {
        this.onOutput(output)
      }
    }, 250)
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.ide_terminal_title'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#D7DAE0')
          .letterSpacing(0.6)
        Blank()
        Button(this.running ? $r('app.string.ide_running') : $r('app.string.ide_run'))
          .fontSize(10)
          .height(25)
          .enabled(this.canRun && !this.running)
          .margin({ right: 10 })
          .onClick(() => this.onRun())
        Text($r('app.string.ide_terminal_runtime'))
          .fontSize(11)
          .fontColor('#7E8794')
      }
      .width('100%')
      .height(32)
      .padding({ left: 12, right: 12 })
      .backgroundColor('#181B20')

      WebTerminal({ virtKeyEnabled: this.virtKeyEnabled })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
