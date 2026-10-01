import preference from '@ohos.data.preferences'

const SESSION_PREFERENCE_NAME = 'hish_ide_session'
const SESSION_KEY = 'session_v1'

export class IDESessionState {
  version: number = 1
  rootPath: string = '/'
  openFiles: string[] = []
  activeFilePath: string = ''
  fileTreeVisible: boolean = true
  terminalVisible: boolean = true
  aiVisible: boolean = true
  fileTreeWidth: number = 202
  aiPanelWidth: number = 280
  editorWeight: number = 3
  terminalWeight: number = 2
}

/** HarmonyOS Preferences-backed IDE session storage in the application sandbox. */
export default class IDESessionStore {
  async load(uiContext: UIContext): Promise<IDESessionState | null> {
    try {
      const applicationContext = uiContext.getHostContext()!!.getApplicationContext()
      const store = await preference.getPreferences(applicationContext, SESSION_PREFERENCE_NAME)
      const value = await store.get(SESSION_KEY, '')
      if (typeof value !== 'string' || !value) {
        return null
      }
      return this.sanitize(JSON.parse(value) as IDESessionState)
    } catch (error) {
      console.error('Unable to load IDE session: ' + (error as Error).message)
      return null
    }
  }

  async save(uiContext: UIContext, session: IDESessionState): Promise<void> {
    try {
      const applicationContext = uiContext.getHostContext()!!.getApplicationContext()
      const store = await preference.getPreferences(applicationContext, SESSION_PREFERENCE_NAME)
      await store.put(SESSION_KEY, JSON.stringify(session))
      await store.flush()
    } catch (error) {
      console.error('Unable to save IDE session: ' + (error as Error).message)
    }
  }

  private sanitize(value: IDESessionState): IDESessionState {
    const session = new IDESessionState()
    if (!value || value.version !== 1) {
      return session
    }
    session.rootPath = typeof value.rootPath === 'string' && value.rootPath.startsWith('/') ? value.rootPath : '/'
    if (Array.isArray(value.openFiles)) {
      const uniquePaths: string[] = []
      for (const path of value.openFiles) {
        if (typeof path === 'string' && path.startsWith('/') && uniquePaths.indexOf(path) === -1) {
          uniquePaths.push(path)
        }
      }
      session.openFiles = uniquePaths
    }
    session.activeFilePath = typeof value.activeFilePath === 'string' ? value.activeFilePath : ''
    session.fileTreeVisible = typeof value.fileTreeVisible === 'boolean' ? value.fileTreeVisible : true
    session.terminalVisible = typeof value.terminalVisible === 'boolean' ? value.terminalVisible : true
    session.aiVisible = typeof value.aiVisible === 'boolean' ? value.aiVisible : true
    session.fileTreeWidth = this.numberInRange(value.fileTreeWidth, 140, 360, 202)
    session.aiPanelWidth = this.numberInRange(value.aiPanelWidth, 180, 400, 280)
    session.editorWeight = this.numberInRange(value.editorWeight, 1, 4, 3)
    session.terminalWeight = this.numberInRange(value.terminalWeight, 1, 4, 2)
    return session
  }

  private numberInRange(value: number, minimum: number, maximum: number, fallback: number): number {
    if (typeof value !== 'number' || !Number.isFinite(value)) {
      return fallback
    }
    return Math.max(minimum, Math.min(maximum, value))
  }
}
