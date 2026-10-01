import { connection } from '@kit.NetworkKit'

@Component
export default struct IDEStatusBar {
  @Prop activeFilePath: string = ''
  @Prop dirty: boolean = false
  @Prop line: number = 1
  @Prop column: number = 1
  @Prop encoding: string = 'UTF-8'
  @Prop lineEnding: string = 'LF'
  @State currentTime: string = '--:--'
  @State networkName: string = 'Network unavailable'
  @State networkColor: string = '#7E8794'
  private refreshTimer: number = -1

  aboutToAppear(): void {
    this.refreshClock()
    void this.refreshNetwork()
    this.refreshTimer = setInterval((): void => {
      this.refreshClock()
      void this.refreshNetwork()
    }, 30000)
  }

  aboutToDisappear(): void {
    if (this.refreshTimer !== -1) {
      clearInterval(this.refreshTimer)
      this.refreshTimer = -1
    }
  }

  private refreshClock(): void {
    const now = new Date()
    const hours = now.getHours().toString().padStart(2, '0')
    const minutes = now.getMinutes().toString().padStart(2, '0')
    this.currentTime = hours + ':' + minutes
  }

  private async refreshNetwork(): Promise<void> {
    try {
      const netHandle = await connection.getDefaultNet()
      const capabilities = await connection.getNetCapabilities(netHandle)
      this.networkName = this.bearerName(capabilities.bearerTypes)
      const bandwidth = Math.max(capabilities.linkDownBandwidthKbps || 0,
        capabilities.linkUpBandwidthKbps || 0)
      if (bandwidth <= 0) {
        this.networkName += ' · quality unavailable'
        this.networkColor = '#7E8794'
      } else if (bandwidth < 1000) {
        this.networkColor = '#E35D6A'
      } else if (bandwidth < 10000) {
        this.networkColor = '#E8C547'
      } else if (bandwidth < 50000) {
        this.networkColor = '#5AA9E6'
      } else {
        this.networkColor = '#55C271'
      }
    } catch (error) {
      this.networkName = 'Network unavailable'
      this.networkColor = '#7E8794'
    }
  }

  private bearerName(bearerTypes: connection.NetBearType[]): string {
    for (const bearer of bearerTypes) {
      if (bearer === connection.NetBearType.BEARER_WIFI) return 'Wi-Fi'
      if (bearer === connection.NetBearType.BEARER_ETHERNET) return 'Ethernet'
      if (bearer === connection.NetBearType.BEARER_CELLULAR) return 'Cellular'
      if (bearer === connection.NetBearType.BEARER_BLUETOOTH) return 'Bluetooth'
      if (bearer === connection.NetBearType.BEARER_VPN) return 'VPN'
    }
    return 'Network type unavailable'
  }

  private visualPath(): string {
    if (!this.activeFilePath) {
      return this.getUIContext().getHostContext()?.resourceManager
        .getStringByNameSync('ide_status_no_file') || 'No file'
    }
    const parts = this.activeFilePath.split('/').filter((part: string) => part.length > 0)
    return parts.join(' > ')
  }

  build() {
    Row({ space: 8 }) {
      Text(this.visualPath())
        .fontSize(10)
        .fontColor('#D9E2F2')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('| Ln ' + this.line + ', Col ' + this.column + ' | ' + this.encoding + ' | ' + this.lineEnding)
        .fontSize(10)
        .fontColor('#B7C1CE')
        .maxLines(1)
      Text(this.networkName)
        .fontSize(10)
        .fontColor('#B7C1CE')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('●')
        .fontSize(10)
        .fontColor(this.networkColor)
      Text(this.currentTime)
        .fontSize(10)
        .fontColor('#B7C1CE')
      Text(this.dirty ? $r('app.string.ide_status_modified') : $r('app.string.ide_status_saved'))
        .fontSize(10)
        .fontColor(this.dirty ? '#F6C177' : '#B7C1CE')
      Text($r('app.string.ide_status_linux'))
        .fontSize(10)
        .fontColor('#B7C1CE')
    }
    .width('100%')
    .height(24)
    .padding({ left: 10, right: 10 })
    .backgroundColor('#243B63')
  }
}
