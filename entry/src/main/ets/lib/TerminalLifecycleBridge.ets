export type TerminalReadyListener = () => void

class TerminalReadySubscription {
  id: string
  listener: TerminalReadyListener

  constructor(id: string, listener: TerminalReadyListener) {
    this.id = id
    this.listener = listener
  }
}

/** Non-reactive readiness signal emitted after ArkWeb has initialized xterm.js. */
class TerminalLifecycleBridge {
  private ready: boolean = false
  private subscriptions: TerminalReadySubscription[] = []

  subscribe(id: string, listener: TerminalReadyListener): void {
    this.unsubscribe(id)
    this.subscriptions.push(new TerminalReadySubscription(id, listener))
    if (this.ready) {
      listener()
    }
  }

  unsubscribe(id: string): void {
    const remaining: TerminalReadySubscription[] = []
    for (const subscription of this.subscriptions) {
      if (subscription.id !== id) {
        remaining.push(subscription)
      }
    }
    this.subscriptions = remaining
  }

  markReady(): void {
    if (this.ready) {
      return
    }
    this.ready = true
    const snapshot = this.subscriptions.slice()
    for (const subscription of snapshot) {
      try {
        subscription.listener()
      } catch (error) {
        console.error('Terminal ready listener failed: ' + (error as Error).message)
      }
    }
  }
}

export const terminalLifecycleBridge: TerminalLifecycleBridge = new TerminalLifecycleBridge()
