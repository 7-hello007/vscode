export type TerminalOutputListener = (text: string) => void

class TerminalOutputSubscription {
  id: string
  listener: TerminalOutputListener

  constructor(id: string, listener: TerminalOutputListener) {
    this.id = id
    this.listener = listener
  }
}

/**
 * Non-reactive event bridge for observing terminal output without placing
 * function values in ArkUI state-managed properties.
 */
class TerminalOutputBridge {
  private subscriptions: TerminalOutputSubscription[] = []

  subscribe(id: string, listener: TerminalOutputListener): void {
    this.unsubscribe(id)
    this.subscriptions.push(new TerminalOutputSubscription(id, listener))
  }

  unsubscribe(id: string): void {
    const remaining: TerminalOutputSubscription[] = []
    for (const subscription of this.subscriptions) {
      if (subscription.id !== id) {
        remaining.push(subscription)
      }
    }
    this.subscriptions = remaining
  }

  publish(text: string): void {
    if (!text) {
      return
    }
    const snapshot = this.subscriptions.slice()
    for (const subscription of snapshot) {
      try {
        subscription.listener(text)
      } catch (error) {
        console.error('Terminal output listener failed: ' + (error as Error).message)
      }
    }
  }
}

export const terminalOutputBridge: TerminalOutputBridge = new TerminalOutputBridge()
