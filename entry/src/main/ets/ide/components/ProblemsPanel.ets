import { IDEProblem, IDEProblemSeverity } from '../problems/IDEProblemContracts'

@Component
export default struct ProblemsPanel {
  @Prop problems: IDEProblem[] = []
  @Prop busy: boolean = false
  @Prop status: string = ''
  @Require onCheckCurrent: () => void
  @Require onCheckProject: () => void
  @Require onCancel: () => void
  @Require onClear: () => void
  @Require onOpenProblem: (problem: IDEProblem) => void

  @Builder
  private actionButton(label: ResourceStr, action: () => void, enabled: boolean = true) {
    Button(label, { buttonStyle: ButtonStyleMode.TEXTUAL })
      .fontSize(10)
      .height(26)
      .enabled(enabled)
      .fontColor(enabled ? '#C6CBD3' : '#6F7782')
      .backgroundColor(Color.Transparent)
      .onClick(action)
  }

  build() {
    Column() {
      Row({ space: 4 }) {
        this.actionButton($r('app.string.ide_problems_check_current'), () => this.onCheckCurrent(), !this.busy)
        this.actionButton($r('app.string.ide_problems_check_project'), () => this.onCheckProject(), !this.busy)
        if (this.busy) {
          this.actionButton($r('app.string.ide_problems_cancel'), () => this.onCancel())
        }
        this.actionButton($r('app.string.ide_problems_clear'), () => this.onClear(), !this.busy)
        Blank()
        if (this.busy) {
          LoadingProgress().width(16).height(16).color('#7AA2F7')
        }
      }
      .width('100%')
      .height(32)
      .padding({ left: 8, right: 10 })
      .backgroundColor('#181B20')

      if (this.status) {
        Text(this.status)
          .width('100%')
          .fontSize(10)
          .fontColor('#8D96A3')
          .padding({ left: 12, right: 12, top: 4, bottom: 4 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      if (this.problems.length === 0 && !this.busy && !this.status) {
        Text($r('app.string.ide_problems_empty'))
          .fontSize(11)
          .fontColor('#737C88')
          .margin({ top: 22 })
      } else {
        List() {
          ForEach(this.problems, (problem: IDEProblem) => {
            ListItem() {
              Row({ space: 8 }) {
                Text(problem.severity === IDEProblemSeverity.ERROR ? '●' : '▲')
                  .fontSize(10)
                  .fontColor(problem.severity === IDEProblemSeverity.ERROR ? '#F07178' : '#E0AF68')
                Column({ space: 2 }) {
                  Text(problem.message)
                    .width('100%')
                    .fontSize(11)
                    .fontColor('#D2D6DC')
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(problem.filePath + ':' + problem.line + ':' + problem.column + '  ' + problem.source)
                    .width('100%')
                    .fontSize(9)
                    .fontColor('#788391')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding({ left: 12, right: 10, top: 7, bottom: 7 })
              .onClick(() => this.onOpenProblem(problem))
            }
          }, (problem: IDEProblem): string => problem.id)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#111318')
  }
}
