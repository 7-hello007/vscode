import { connection } from '@kit.NetworkKit'
import { wifiManager } from '@kit.ConnectivityKit'
import IDEHostStatusAdapter from '../system/IDEHostStatusAdapter'
import { IDE_STATUS_SURFACE_COLOR } from '../theme/IDEBackgroundSurfaces'

@Component
export default struct IDEStatusBar {
  @Prop activeFilePath: string = ''
  @Prop dirty: boolean = false
  @Prop line: number = 1
  @Prop column: number = 1
  @Prop encoding: string = 'UTF-8'
  @Prop lineEnding: string = 'LF'
  @State currentTime: string = '--:--:--'
  @State networkName: string = 'Network unavailable'
  @State networkColor: string = '#7E8794'
  @State networkQualityAvailable: boolean = false
  @State batteryPercentage: number = -1
  private hostStatusAdapter: IDEHostStatusAdapter = new IDEHostStatusAdapter()
  private clockTimer: number = -1
  private networkTimer: number = -1

  aboutToAppear(): void {
    this.refreshClock()
    void this.refreshNetwork()
    this.clockTimer = setInterval((): void => this.refreshClock(), 1000)
    this.networkTimer = setInterval((): void => {
      void this.refreshNetwork()
    }, 30000)
    this.hostStatusAdapter.start((percentage: number): void => {
      this.batteryPercentage = percentage
    })
  }

  aboutToDisappear(): void {
    if (this.clockTimer !== -1) {
      clearInterval(this.clockTimer)
      this.clockTimer = -1
    }
    if (this.networkTimer !== -1) {
      clearInterval(this.networkTimer)
      this.networkTimer = -1
    }
    this.hostStatusAdapter.stop()
  }

  private refreshClock(): void {
    const now = new Date()
    const hours = now.getHours().toString().padStart(2, '0')
    const minutes = now.getMinutes().toString().padStart(2, '0')
    const seconds = now.getSeconds().toString().padStart(2, '0')
    this.currentTime = hours + ':' + minutes + ':' + seconds
  }

  private async refreshNetwork(): Promise<void> {
    try {
      const netHandle = await connection.getDefaultNet()
      const capabilities = await connection.getNetCapabilities(netHandle)
      if (this.hasBearer(capabilities.bearerTypes, connection.NetBearType.BEARER_WIFI)) {
        try {
          const linkedInfo = await wifiManager.getLinkedInfo()
          this.networkName = linkedInfo.ssid || 'Wi-Fi name unavailable'
          const signalLevel = wifiManager.getSignalLevel(linkedInfo.rssi, linkedInfo.band)
          this.applyWifiSignalLevel(signalLevel)
          return
        } catch (error) {
          this.networkName = 'Wi-Fi name unavailable'
        }
      } else {
        this.networkName = this.bearerFallbackName(capabilities.bearerTypes)
      }
      const bandwidth = Math.max(capabilities.linkDownBandwidthKbps || 0,
        capabilities.linkUpBandwidthKbps || 0)
      if (bandwidth <= 0) {
        this.networkName += ' · quality unavailable'
        this.networkColor = '#7E8794'
        this.networkQualityAvailable = false
      } else if (bandwidth < 1000) {
        this.networkColor = '#E35D6A'
        this.networkQualityAvailable = true
      } else if (bandwidth < 10000) {
        this.networkColor = '#E8C547'
        this.networkQualityAvailable = true
      } else if (bandwidth < 50000) {
        this.networkColor = '#5AA9E6'
        this.networkQualityAvailable = true
      } else {
        this.networkColor = '#55C271'
        this.networkQualityAvailable = true
      }
    } catch (error) {
      this.networkName = 'Network unavailable'
      this.networkColor = '#7E8794'
      this.networkQualityAvailable = false
    }
  }

  private hasBearer(bearerTypes: connection.NetBearType[], expected: connection.NetBearType): boolean {
    for (const bearer of bearerTypes) {
      if (bearer === expected) return true
    }
    return false
  }

  private bearerFallbackName(bearerTypes: connection.NetBearType[]): string {
    for (const bearer of bearerTypes) {
      if (bearer === connection.NetBearType.BEARER_ETHERNET) return 'Ethernet · name unavailable'
      if (bearer === connection.NetBearType.BEARER_CELLULAR) return 'Cellular · name unavailable'
      if (bearer === connection.NetBearType.BEARER_BLUETOOTH) return 'Bluetooth · name unavailable'
      if (bearer === connection.NetBearType.BEARER_VPN) return 'VPN · name unavailable'
    }
    return 'Network name unavailable'
  }

  private applyWifiSignalLevel(signalLevel: number): void {
    this.networkQualityAvailable = true
    if (signalLevel <= 1) {
      this.networkColor = '#E35D6A'
    } else if (signalLevel === 2) {
      this.networkColor = '#E8C547'
    } else if (signalLevel === 3) {
      this.networkColor = '#5AA9E6'
    } else {
      this.networkColor = '#55C271'
    }
  }

  private visualPath(): string {
    if (!this.activeFilePath) {
      return this.getUIContext().getHostContext()?.resourceManager
        .getStringByNameSync('ide_status_no_file') || 'No file'
    }
    const parts = this.activeFilePath.split('/').filter((part: string) => part.length > 0)
    return parts.join(' > ')
  }

  private batteryColor(): string {
    if (this.batteryPercentage < 0) return '#7E8794'
    if (this.batteryPercentage > 50) return '#55C271'
    if (this.batteryPercentage > 20) return '#E8C547'
    if (this.batteryPercentage > 10) return '#E59A45'
    return '#E35D6A'
  }

  build() {
    Row() {
      Row({ space: 12 }) {
        Text(this.visualPath())
          .fontSize(10)
          .fontColor('#D9E2F2')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 240 })
        Text('行 ' + this.line + '，列 ' + this.column)
          .fontSize(10)
          .fontColor('#B7C1CE')
          .maxLines(1)
        Text(this.encoding)
          .fontSize(10)
          .fontColor('#B7C1CE')
        Text(this.lineEnding)
          .fontSize(10)
          .fontColor('#B7C1CE')
      }
      .layoutWeight(1)
      .clip(true)

      Row({ space: 12 }) {
        Row({ space: 3 }) {
          Text(this.networkName)
            .fontSize(10)
            .fontColor('#B7C1CE')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 180 })
          Text(this.networkQualityAvailable ? '●' : '○')
            .fontSize(10)
            .fontColor(this.networkColor)
        }
        Text(this.currentTime)
          .fontSize(10)
          .fontColor('#B7C1CE')
        Text(this.dirty ? $r('app.string.ide_status_modified') : $r('app.string.ide_status_saved'))
          .fontSize(10)
          .fontColor(this.dirty ? '#F6C177' : '#B7C1CE')
        Text('HiSH Editor')
          .fontSize(10)
          .fontColor('#B7C1CE')
        Text('●')
          .fontSize(10)
          .fontColor(this.batteryColor())
      }
    }
    .width('100%')
    .height(24)
    .padding({ left: 10, right: 10 })
    .backgroundColor(IDE_STATUS_SURFACE_COLOR)
  }
}
