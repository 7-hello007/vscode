import preference from '@ohos.data.preferences'

const PREFERENCE_NAME = 'hish_ide_plugins'
const STATE_KEY = 'plugin_state_v1'

export class PluginEnabledState {
  id: string = ''
  enabled: boolean = false

  constructor(id: string, enabled: boolean) {
    this.id = id
    this.enabled = enabled
  }
}

export class PluginPersistedState {
  version: number = 1
  plugins: PluginEnabledState[] = []
  backgroundImagePath: string = ''
  backgroundOpacity: number = 50
}

export default class PluginStateStore {
  async load(uiContext: UIContext): Promise<PluginPersistedState> {
    try {
      const context = uiContext.getHostContext()!!.getApplicationContext()
      const store = await preference.getPreferences(context, PREFERENCE_NAME)
      const value = await store.get(STATE_KEY, '')
      if (typeof value !== 'string' || !value) return new PluginPersistedState()
      return this.sanitize(JSON.parse(value) as PluginPersistedState)
    } catch (error) {
      console.error('Unable to load plugin state: ' + (error as Error).message)
      return new PluginPersistedState()
    }
  }

  async save(uiContext: UIContext, state: PluginPersistedState): Promise<void> {
    try {
      const context = uiContext.getHostContext()!!.getApplicationContext()
      const store = await preference.getPreferences(context, PREFERENCE_NAME)
      await store.put(STATE_KEY, JSON.stringify(state))
      await store.flush()
    } catch (error) {
      console.error('Unable to save plugin state: ' + (error as Error).message)
    }
  }

  private sanitize(value: PluginPersistedState): PluginPersistedState {
    const state = new PluginPersistedState()
    if (!value || value.version !== 1) return state
    if (Array.isArray(value.plugins)) {
      for (const item of value.plugins) {
        if (item && typeof item.id === 'string' && item.id && typeof item.enabled === 'boolean') {
          state.plugins.push(new PluginEnabledState(item.id, item.enabled))
        }
      }
    }
    state.backgroundImagePath = typeof value.backgroundImagePath === 'string' ? value.backgroundImagePath : ''
    const opacity = typeof value.backgroundOpacity === 'number' ? value.backgroundOpacity : 50
    state.backgroundOpacity = Math.max(0, Math.min(100, Math.round(opacity)))
    return state
  }
}
