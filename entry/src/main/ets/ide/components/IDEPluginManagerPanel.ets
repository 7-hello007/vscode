import { IDEPluginCheckerStatus, IDEPluginState, IDEPluginType } from '../plugin/IDEPluginContracts'
import {
  IDE_BORDER_SUBTLE_COLOR,
  IDE_SURFACE_MESSAGE_COLOR,
  IDE_SURFACE_SELECTED_COLOR
} from '../theme/IDEBackgroundSurfaces'

@Component
export default struct IDEPluginManagerPanel {
  @Prop plugins: IDEPluginState[] = []
  @Require onEnabledChange: (id: string, enabled: boolean) => void
  @Require onShowInfo: (plugin: IDEPluginState) => void

  private typeLabel(type: IDEPluginType): string {
    if (type === IDEPluginType.LANGUAGE_DIAGNOSTIC) return '语言 / 诊断插件'
    if (type === IDEPluginType.FILE_VIEWER) return '文件查看器插件'
    if (type === IDEPluginType.APPEARANCE) return '外观插件'
    return 'IDE 插件'
  }

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
        .backgroundColor(IDE_SURFACE_MESSAGE_COLOR)
        .border({ width: 1, color: IDE_BORDER_SUBTLE_COLOR })
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
                  Text(this.typeLabel(state.manifest.type))
                    .fontSize(10)
                    .fontColor('#8D96A3')
                    .maxLines(1)
                  Row({ space: 12 }) {
                    Text(state.enabled ? '已启用' : '已禁用')
                      .fontSize(10)
                      .fontColor(state.enabled ? '#A7C080' : '#8D96A3')
                    Text('检查器：' + (state.checkerStatus === IDEPluginCheckerStatus.AVAILABLE ?
                      '可用' : '不可用'))
                      .fontSize(10)
                      .fontColor(state.checkerStatus === IDEPluginCheckerStatus.AVAILABLE ? '#A7C080' : '#D3A65A')
                  }
                  if (state.lifecycleError) {
                    Text(state.lifecycleError)
                      .fontSize(10)
                      .fontColor('#E39A9A')
                      .maxLines(2)
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .onClick(() => this.onShowInfo(state))

                Toggle({ type: ToggleType.Switch, isOn: state.enabled })
                  .onChange((enabled: boolean) => this.onEnabledChange(state.manifest.id, enabled))
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .backgroundColor(state.enabled ? IDE_SURFACE_SELECTED_COLOR : IDE_SURFACE_MESSAGE_COLOR)
              .border({ width: 1, color: IDE_BORDER_SUBTLE_COLOR })
              .borderRadius(6)
            }
          }, (state: IDEPluginState): string => state.manifest.id + ':' +
            (state.enabled ? 'enabled' : 'disabled') + ':' + state.lifecycleError + ':' + state.checkerStatus)
        }
        .width('100%')
        .layoutWeight(1)
      }

    }
    .width('100%')
    .height('100%')
    .padding({ top: 6, bottom: 6 })
  }
}
