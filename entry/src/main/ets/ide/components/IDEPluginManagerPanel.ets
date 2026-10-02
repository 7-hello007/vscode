import { IDEPluginCheckerStatus, IDEPluginState } from '../plugin/IDEPluginContracts'

@Component
export default struct IDEPluginManagerPanel {
  @Prop plugins: IDEPluginState[] = []
  @Require onEnabledChange: (id: string, enabled: boolean) => void
  @Require onShowInfo: (plugin: IDEPluginState) => void

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.ide_plugins_description'))
        .fontSize(12)
        .fontColor('#9BA4B2')
        .width('100%')

      if (this.plugins.length === 0) {
        Column({ space: 6 }) {
          Text($r('app.string.ide_plugins_empty'))
            .fontSize(14)
            .fontColor('#D7DAE0')
          Text($r('app.string.ide_plugins_future'))
            .fontSize(11)
            .fontColor('#7E8794')
        }
        .width('100%')
        .padding(20)
        .backgroundColor('#20242B')
        .borderRadius(6)
      } else {
        List({ space: 8 }) {
          ForEach(this.plugins, (state: IDEPluginState) => {
            ListItem() {
              Row({ space: 10 }) {
                Column({ space: 3 }) {
                  Text(state.manifest.name)
                    .fontSize(13)
                    .fontColor('#E2E5EA')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(state.manifest.type)
                    .fontSize(10)
                    .fontColor('#8D96A3')
                    .maxLines(1)
                  Row({ space: 12 }) {
                    Text(state.enabled ? 'Enabled' : 'Disabled')
                      .fontSize(10)
                      .fontColor(state.enabled ? '#A7C080' : '#8D96A3')
                    Text('Checker: ' + (state.checkerStatus === IDEPluginCheckerStatus.AVAILABLE ?
                      'Available' : 'Unavailable'))
                      .fontSize(10)
                      .fontColor(state.checkerStatus === IDEPluginCheckerStatus.AVAILABLE ? '#A7C080' : '#D3A65A')
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Toggle({ type: ToggleType.Switch, isOn: state.enabled })
                  .onChange((enabled: boolean) => this.onEnabledChange(state.manifest.id, enabled))
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .backgroundColor('#20242B')
              .borderRadius(6)
              .onClick(() => this.onShowInfo(state))
            }
          }, (state: IDEPluginState): string => state.manifest.id)
        }
        .width('100%')
        .height(260)
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }
}
