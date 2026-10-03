import { IDEPlugin, IDEPluginState } from './IDEPluginContracts'
import IDEPluginRegistry from './IDEPluginRegistry'
import PluginStateStore, { PluginEnabledState, PluginPersistedState } from './PluginStateStore'

class PluginDefaultState {
  id: string
  enabled: boolean

  constructor(id: string, enabled: boolean) {
    this.id = id
    this.enabled = enabled
  }
}

/** Coordinates immediate lifecycle changes with best-effort sandbox persistence. */
export default class PluginManager {
  private registry: IDEPluginRegistry
  private store: PluginStateStore
  private defaults: PluginDefaultState[] = []
  private persisted: PluginPersistedState = new PluginPersistedState()

  constructor(registry: IDEPluginRegistry, store: PluginStateStore = new PluginStateStore()) {
    this.registry = registry
    this.store = store
  }

  register(plugin: IDEPlugin, enabledByDefault: boolean): boolean {
    const registered = this.registry.register(plugin, enabledByDefault)
    if (registered) this.defaults.push(new PluginDefaultState(plugin.manifest.id, enabledByDefault))
    return registered
  }

  async restore(uiContext: UIContext): Promise<PluginPersistedState> {
    this.persisted = await this.store.load(uiContext)
    for (const item of this.defaults) {
      const saved = this.findPersisted(item.id)
      this.registry.setEnabled(item.id, saved === null ? item.enabled : saved)
    }
    return this.persisted
  }

  setEnabled(id: string, enabled: boolean, uiContext: UIContext): boolean {
    const changed = this.registry.setEnabled(id, enabled)
    if (changed) void this.persist(uiContext)
    return changed
  }

  isEnabled(id: string): boolean {
    return this.registry.isEnabled(id)
  }

  getPlugins(): IDEPluginState[] {
    return this.registry.list()
  }

  updateBackground(uiContext: UIContext, imagePath: string, opacity: number): void {
    this.persisted.backgroundImagePath = imagePath
    this.persisted.backgroundOpacity = Math.max(0, Math.min(100, Math.round(opacity)))
    void this.persist(uiContext)
  }

  backgroundState(): PluginPersistedState {
    return this.persisted
  }

  private async persist(uiContext: UIContext): Promise<void> {
    const enabledStates: PluginEnabledState[] = []
    for (const state of this.registry.list()) {
      enabledStates.push(new PluginEnabledState(state.manifest.id, state.enabled))
    }
    this.persisted.plugins = enabledStates
    await this.store.save(uiContext, this.persisted)
  }

  private findPersisted(id: string): boolean | null {
    for (const item of this.persisted.plugins) {
      if (item.id === id) return item.enabled
    }
    return null
  }
}
