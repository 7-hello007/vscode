import { batteryInfo, commonEventManager } from '@kit.BasicServicesKit'

export type IDEBatteryListener = (percentage: number) => void

/**
 * Event-driven battery status boundary for the IDE chrome.
 */
export default class IDEHostStatusAdapter {
  private batterySubscriber: commonEventManager.CommonEventSubscriber | null = null
  private started: boolean = false
  private lifecycleRevision: number = 0
  private batteryListener: IDEBatteryListener = (_percentage: number): void => {}

  start(batteryListener: IDEBatteryListener): void {
    this.batteryListener = batteryListener
    if (this.started) {
      this.publishBattery()
      return
    }
    this.started = true
    const revision = ++this.lifecycleRevision
    this.publishBattery()
    void this.subscribeBatteryChanges(revision)
  }

  stop(): void {
    this.started = false
    ++this.lifecycleRevision
    const subscriber = this.batterySubscriber
    this.batterySubscriber = null
    if (subscriber) {
      try {
        commonEventManager.unsubscribe(subscriber)
      } catch (error) {
        console.warn('HiSH battery event unsubscribe failed: ' + (error as Error).message)
      }
    }
  }

  private publishBattery(): void {
    if (!this.started) return
    try {
      const percentage = batteryInfo.isBatteryPresent ? batteryInfo.batterySOC : -1
      this.batteryListener(percentage >= 0 && percentage <= 100 ? percentage : -1)
    } catch (error) {
      this.batteryListener(-1)
    }
  }

  private async subscribeBatteryChanges(revision: number): Promise<void> {
    try {
      const subscriber = await commonEventManager.createSubscriber({
        events: [commonEventManager.Support.COMMON_EVENT_BATTERY_CHANGED]
      })
      if (!this.started || revision !== this.lifecycleRevision) {
        commonEventManager.unsubscribe(subscriber)
        return
      }
      this.batterySubscriber = subscriber
      commonEventManager.subscribe(subscriber, (error): void => {
        if (!error && this.started && revision === this.lifecycleRevision) {
          this.publishBattery()
        }
      })
    } catch (error) {
      if (revision === this.lifecycleRevision) {
        this.batterySubscriber = null
        this.publishBattery()
      }
    }
  }
}
