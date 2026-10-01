import { IDEPluginState } from '../plugin/IDEPluginContracts'

@Component
export default struct IDEPluginManagerPanel {
  @Prop plugins: IDEPluginState[] = []
  @Require onEnabledChange: (id: string, enabled: boolean) => void

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
                  Text(state.manifest.name + '  ' + state.manifest.version)
                    .fontSize(13)
                    .fontColor('#E2E5EA')
                  Text(state.manifest.description)
                    .fontSize(10)
                    .fontColor('#8F98A6')
                    .maxLines(2)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: state.enabled })
                  .onChange((enabled: boolean) => this.onEnabledChange(state.manifest.id, enabled))
              }
              .width('100%')
              .padding(10)
              .backgroundColor('#20242B')
              .borderRadius(6)
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
