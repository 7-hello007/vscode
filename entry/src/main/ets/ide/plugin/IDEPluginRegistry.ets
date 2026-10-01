import { IDEPlugin, IDEPluginContext, IDEPluginState } from './IDEPluginContracts'

interface RegisteredPlugin {
  plugin: IDEPlugin
  enabled: boolean
}

/** In-process registry for small IDE extensions; this is not an extension host. */
export default class IDEPluginRegistry {
  private plugins: RegisteredPlugin[] = []
  private context: IDEPluginContext

  constructor(context: IDEPluginContext) {
    this.context = context
  }

  register(plugin: IDEPlugin): boolean {
    if (!plugin.manifest.id || this.findIndex(plugin.manifest.id) !== -1) {
      return false
    }
    this.plugins.push({ plugin, enabled: false })
    return true
  }

  unregister(id: string): boolean {
    const index = this.findIndex(id)
    if (index === -1) {
      return false
    }
    if (this.plugins[index].enabled) {
      this.plugins[index].plugin.deactivate()
    }
    this.plugins.splice(index, 1)
    return true
  }

  setEnabled(id: string, enabled: boolean): boolean {
    const index = this.findIndex(id)
    if (index === -1 || this.plugins[index].enabled === enabled) {
      return index !== -1
    }
    if (enabled) {
      this.plugins[index].plugin.activate(this.context)
    } else {
      this.plugins[index].plugin.deactivate()
    }
    this.plugins[index].enabled = enabled
    return true
  }

  list(): IDEPluginState[] {
    const states: IDEPluginState[] = []
    for (const registered of this.plugins) {
      states.push({ manifest: registered.plugin.manifest, enabled: registered.enabled })
    }
    return states
  }

  private findIndex(id: string): number {
    for (let index = 0; index < this.plugins.length; index++) {
      if (this.plugins[index].plugin.manifest.id === id) {
        return index
      }
    }
    return -1
  }
}
