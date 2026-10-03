import { CustomContentDialog } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import IDEAIService from './ai/IDEAIService'
import { ideAIProviderRegistry } from './ai/IDEAIProviderRegistry'
import { HISH_LOCAL_PROVIDER_ID, localAIProvider } from './ai/LocalAIProvider'
import { codexAgentProvider } from './agent/CodexAgentProvider'
import HiSHAgentToolBridge from './agent/HiSHAgentToolBridge'
import IDEAgentCommandRunner from './agent/IDEAgentCommandRunner'
import AIWorkspacePanel from './components/AIWorkspacePanel'
import CodeEditorPanel from './components/CodeEditorPanel'
import FileTreePanel from './components/FileTreePanel'
import IDEMenuBar from './components/IDEMenuBar'
import IDEPluginManagerPanel from './components/IDEPluginManagerPanel'
import IDEStatusBar from './components/IDEStatusBar'
import ProblemsPanel from './components/ProblemsPanel'
import TerminalPanel from './components/TerminalPanel'
import IDEFileSystem from './filesystem/IDEFileSystem'
import { IDEFileSystemError } from './filesystem/IDEFileSystemTypes'
import { IDEEditorTab } from './model/IDEEditorTab'
import {
  IDEAIContext,
  IDEAIFileContext,
  IDEAIMessage,
  IDEAIMessageRole,
  IDEAIProviderInfo,
  IDEAIRequest
} from './model/IDEAIContracts'
import { IDEPluginCheckerStatus, IDEPluginContext, IDEPluginState } from './plugin/IDEPluginContracts'
import IDEPluginRegistry from './plugin/IDEPluginRegistry'
import PythonDiagnosticPlugin from './plugin/PythonDiagnosticPlugin'
import { IDEDiagnosticResult, IDEProblem } from './problems/IDEProblemContracts'
import IDEProblemsService from './problems/IDEProblemsService'
import IDETerminalRunner from './run/IDETerminalRunner'
import IDESessionStore, { IDESessionState } from './session/IDESessionStore'
import { terminalLifecycleBridge } from '../lib/TerminalLifecycleBridge'

const IDE_TERMINAL_READY_SUBSCRIBER = 'IDE.Workbench.SessionRestore'
const IDE_SESSION_MAX_PROBE_ATTEMPTS = 8
const IDE_SESSION_INITIAL_PROBE_DELAY_MS = 5000
const IDE_SESSION_MAX_PROBE_DELAY_MS = 60000

enum IDEBottomPanelView {
  PROBLEMS = 0,
  TERMINAL = 1
}

class WorkbenchPluginContext implements IDEPluginContext {
  private activePathProvider: () => string

  constructor(activePathProvider: () => string) {
    this.activePathProvider = activePathProvider
  }

  getActiveFilePath(): string {
    return this.activePathProvider()
  }
}

@Component
export default struct IDEWorkbench {
  @Require terminalVirtualKeys: boolean
  @Prop compactLayout: boolean = false
  @Require onOpenVnc: () => void
  @Require onEmulatorManagement: () => void
  @Require onRootfsManagement: () => void
  @Require onSharedFolder: () => void
  @Require onSettings: () => void
  @Require onUserGuide: () => void

  private fileSystem: IDEFileSystem = new IDEFileSystem()
  private terminalRunner: IDETerminalRunner = new IDETerminalRunner()
  private agentCommandRunner: IDEAgentCommandRunner = new IDEAgentCommandRunner(this.terminalRunner)
  private agentToolBridge: HiSHAgentToolBridge =
    new HiSHAgentToolBridge(this.fileSystem, this.agentCommandRunner, '/')
  private aiService: IDEAIService = new IDEAIService(ideAIProviderRegistry)
  private sessionStore: IDESessionStore = new IDESessionStore()
  private pluginRegistry: IDEPluginRegistry = new IDEPluginRegistry(
    new WorkbenchPluginContext((): string => this.activeFilePath))
  private problemsService: IDEProblemsService = new IDEProblemsService(this.fileSystem, this.pluginRegistry)
  @State editorTabs: IDEEditorTab[] = []
  @State activeFilePath: string = ''
  @State editorBusy: boolean = false
  @State editorStatus: string = ''
  @State runBusy: boolean = false
  @State fileTreeVisible: boolean = true
  @State terminalVisible: boolean = true
  @State aiVisible: boolean = true
  @State terminalExtraKeysVisible: boolean = false
  @State editorWeight: number = 3
  @State terminalWeight: number = 2
  @State fileTreeWidth: number = 202
  @State aiPanelWidth: number = 280
  @State workbenchAvailableWidth: number = 0
  @State editorCommandRequest: string = ''
  @State editorCommandSequence: number = 0
  @State pluginStates: IDEPluginState[] = this.pluginRegistry.list()
  @State aiProviders: IDEAIProviderInfo[] = ideAIProviderRegistry.list()
  @State activeAIProviderId: string = ''
  @State aiMessages: IDEAIMessage[] = []
  @State aiBusy: boolean = false
  @State aiPreparing: boolean = false
  @State aiError: string = ''
  @State editorSelectedText: string = ''
  @State editorLanguage: string = 'plaintext'
  @State editorLine: number = 1
  @State editorColumn: number = 1
  @State editorEncoding: string = 'UTF-8'
  @State editorLineEnding: string = 'LF'
  @State terminalOutput: string = ''
  @State bottomPanelView: IDEBottomPanelView = IDEBottomPanelView.TERMINAL
  @State problems: IDEProblem[] = []
  @State problemsBusy: boolean = false
  @State problemsStatus: string = ''
  @State fileTreeRootPath: string = '/'
  @State fileTreeRootRevision: number = 0
  @State fileSystemReady: boolean = false
  @State openFolderPath: string = '/'
  @State openFolderError: string = ''
  @State openFolderBusy: boolean = false
  private aiMessageSequence: number = 0
  private editorBuffers: Map<string, string> = new Map<string, string>()
  private openingFilePaths: string[] = []
  private fileTreeResizeStartWidth: number = 202
  private aiPanelResizeStartWidth: number = 280
  private editorResizeStartWeight: number = 3
  private sessionRestoreCancelled: boolean = false
  private sessionRestoreInFlight: boolean = false
  private sessionRestoring: boolean = false
  private sessionRestored: boolean = false
  private sessionProbeAttempt: number = 0
  private sessionProbeTimer: number | undefined = undefined
  private sessionSaveTimer: number | undefined = undefined
  private sessionInteractionRevision: number = 0
  private pendingFileActivations: string[] = []
  private terminalReadyListener: () => void = (): void => this.onTerminalReady()
  private problemsRequestSequence: number = 0
  private sessionTimelineStartMs: number = 0
  private pluginsInitialized: boolean = false

  private pluginController: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      primaryTitle: $r('app.string.ide_plugins_title'),
      contentBuilder: () => {
        this.buildPluginManager()
      },
      buttons: [{
        value: $r('app.string.SettingComplete_label'),
        buttonStyle: ButtonStyleMode.TEXTUAL,
        action: (): void => this.pluginController.close()
      }]
    })
  })

  private openFolderController: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      primaryTitle: $r('app.string.ide_menu_open_folder'),
      contentBuilder: () => {
        this.buildOpenFolderDialog()
      },
      buttons: [
        {
          value: $r('app.string.setting_generic_cancel'),
          buttonStyle: ButtonStyleMode.TEXTUAL,
          action: (): void => this.openFolderController.close()
        },
        {
          value: $r('app.string.ide_menu_open_folder'),
          buttonStyle: ButtonStyleMode.TEXTUAL,
          action: (): void => { void this.confirmOpenFolder() }
        }
      ]
    })
  })

  aboutToAppear(): void {
    codexAgentProvider.attachToolBridge(this.agentToolBridge)
    this.agentToolBridge.setProjectRoot(this.fileTreeRootPath)
    const abilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext
    if (abilityContext) void codexAgentProvider.initialize(abilityContext)
    this.initializePlugins()
    this.sessionRestoreCancelled = false
    terminalLifecycleBridge.subscribe(IDE_TERMINAL_READY_SUBSCRIBER, this.terminalReadyListener)
    if (this.compactLayout) {
      this.fileTreeWidth = 162
      this.aiPanelWidth = 220
    }
    void this.initializeLocalAI()
  }

  private async initializeLocalAI(): Promise<void> {
    if (!ideAIProviderRegistry.find(HISH_LOCAL_PROVIDER_ID)) {
      ideAIProviderRegistry.register(localAIProvider)
    }
    this.activeAIProviderId = HISH_LOCAL_PROVIDER_ID
    this.aiProviders = ideAIProviderRegistry.list()
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext
    if (!context) {
      this.aiError = 'Application context is unavailable'
      return
    }
    this.aiPreparing = true
    this.aiError = ''
    try {
      await localAIProvider.initialize(context)
    } catch (error) {
      this.aiError = (error as Error).message || 'Local model initialization failed'
    } finally {
      this.aiPreparing = false
      this.aiProviders = ideAIProviderRegistry.list()
    }
  }

  private initializePlugins(): void {
    if (this.pluginsInitialized) return
    this.pluginRegistry.register(new PythonDiagnosticPlugin(), true)
    this.pluginsInitialized = true
    this.pluginStates = this.pluginRegistry.list()
  }

  aboutToDisappear(): void {
    this.problemsService.cancel()
    this.sessionRestoreCancelled = true
    terminalLifecycleBridge.unsubscribe(IDE_TERMINAL_READY_SUBSCRIBER)
    if (this.sessionProbeTimer !== undefined) {
      clearTimeout(this.sessionProbeTimer)
      this.sessionProbeTimer = undefined
    }
    if (this.sessionSaveTimer !== undefined) {
      clearTimeout(this.sessionSaveTimer)
      this.sessionSaveTimer = undefined
    }
    if (this.sessionRestored && !this.sessionRestoring) {
      void this.persistSession()
    }
  }

  private onTerminalReady(): void {
    if (this.sessionRestored || this.sessionRestoreInFlight || this.sessionRestoreCancelled) {
      return
    }
    this.sessionTimelineStartMs = Date.now()
    console.info('IDE session timeline: Terminal/ArkWeb ready at +0ms')
    // ArkWeb/xterm readiness is not guest-agent readiness. It only starts a
    // bounded, backoff-controlled probe schedule; elapsed time never marks the
    // filesystem ready.
    this.scheduleSessionProbe()
  }

  private async probeFileSystemAndRestore(): Promise<void> {
    if (this.sessionRestored || this.sessionRestoreInFlight || this.sessionRestoreCancelled) {
      return
    }
    this.sessionRestoreInFlight = true
    const probeStartedAt = Date.now()
    console.info('IDE session timeline: filesystem probe started at +' + this.sessionElapsedMs() + 'ms')
    try {
      // A successful real guest directory listing is the readiness condition.
      // Elapsed time alone is never treated as VM or file-system readiness.
      await this.fileSystem.listDirectory('/')
    } catch (error) {
      console.info('IDE session timeline: filesystem probe failed after ' +
        (Date.now() - probeStartedAt) + 'ms; next attempt uses configured backoff')
      this.sessionRestoreInFlight = false
      this.scheduleSessionProbe()
      return
    }
    console.info('IDE session timeline: QGA + IDEFileSystem ready after probe ' +
      (Date.now() - probeStartedAt) + 'ms, at +' + this.sessionElapsedMs() + 'ms')

    try {
      await this.restoreSession()
    } catch (error) {
      console.error('Unable to restore IDE session: ' + (error as Error).message)
    } finally {
      // A successful guest file-system probe consumes the one restore attempt.
      // Session/Preferences failures must not keep retrying or block IDE startup.
      this.fileSystemReady = true
      this.sessionRestored = true
      this.sessionRestoreInFlight = false
    }
  }

  private scheduleSessionProbe(): void {
    if (this.sessionRestoreCancelled || this.sessionRestored || this.sessionRestoreInFlight ||
      this.sessionProbeTimer !== undefined) {
      return
    }
    if (this.sessionProbeAttempt >= IDE_SESSION_MAX_PROBE_ATTEMPTS) {
      console.error('IDE session restore stopped: guest filesystem did not become ready')
      return
    }
    const delay = Math.min(IDE_SESSION_MAX_PROBE_DELAY_MS,
      IDE_SESSION_INITIAL_PROBE_DELAY_MS * Math.pow(2, this.sessionProbeAttempt))
    this.sessionProbeAttempt++
    console.info('IDE session timeline: probe attempt ' + this.sessionProbeAttempt +
      ' scheduled in ' + delay + 'ms')
    this.sessionProbeTimer = setTimeout((): void => {
      this.sessionProbeTimer = undefined
      void this.probeFileSystemAndRestore()
    }, delay)
  }

  private async restoreSession(): Promise<void> {
    this.sessionRestoring = true
    const interactionRevision = this.sessionInteractionRevision
    const activeBeforeRestore = this.activeFilePath
    const restoreStartedAt = Date.now()
    try {
      const loadStartedAt = Date.now()
      const stored = await this.sessionStore.load(this.getUIContext())
      console.info('IDE session timeline: Preferences loaded in ' + (Date.now() - loadStartedAt) +
        'ms, at +' + this.sessionElapsedMs() + 'ms')
      const session = stored || new IDESessionState()
      let restoredRoot = '/'
      if (session.rootPath !== '/') {
        try {
          const normalizedRoot = this.fileSystem.normalizePath(session.rootPath)
          const rootValidationStartedAt = Date.now()
          await this.fileSystem.listDirectory(normalizedRoot)
          console.info('IDE session timeline: saved root validated in ' +
            (Date.now() - rootValidationStartedAt) + 'ms')
          restoredRoot = normalizedRoot
        } catch (error) {
          restoredRoot = '/'
        }
      }
      console.info('IDE session timeline: root selected as ' + restoredRoot +
        ' at +' + this.sessionElapsedMs() + 'ms')

      // Do not overwrite UI state if the user already interacted while the guest
      // was becoming ready. Historical tabs are merged below instead of clearing
      // live tabs, which also prevents restore/manual-open races.
      if (this.sessionInteractionRevision === 0) {
        this.fileTreeVisible = session.fileTreeVisible
        this.terminalVisible = session.terminalVisible
        this.aiVisible = session.aiVisible
        this.fileTreeWidth = session.fileTreeWidth
        this.aiPanelWidth = this.clampAIPanelWidth(session.aiPanelWidth)
        this.editorWeight = session.editorWeight
        this.terminalWeight = session.terminalWeight
        this.fileTreeRootPath = restoredRoot
        this.agentToolBridge.setProjectRoot(restoredRoot)
        this.fileTreeRootRevision++
      }

      for (const path of session.openFiles) {
        if (this.sessionRestoreCancelled) {
          return
        }
        const fileStartedAt = Date.now()
        const opened = await this.openFile(path, true, false)
        console.info('IDE session timeline: historical file ' + (opened ? 'restored' : 'skipped') +
          ' in ' + (Date.now() - fileStartedAt) + 'ms: ' + path)
      }
      if (this.sessionInteractionRevision === interactionRevision && !activeBeforeRestore) {
        if (session.activeFilePath && this.findTab(session.activeFilePath)) {
          this.activeFilePath = session.activeFilePath
        } else if (this.editorTabs.length > 0) {
          this.activeFilePath = this.editorTabs[0].path
        }
      }
      console.info('IDE session timeline: tabs restored=' + this.editorTabs.length +
        ', active=' + (this.activeFilePath || '<none>') + ', restore duration=' +
        (Date.now() - restoreStartedAt) + 'ms, at +' + this.sessionElapsedMs() + 'ms')
      this.editorStatus = ''
    } finally {
      this.sessionRestoring = false
      if (!this.sessionRestoreCancelled) {
        this.scheduleSessionSave()
      }
    }
  }

  private sessionElapsedMs(): number {
    return this.sessionTimelineStartMs > 0 ? Date.now() - this.sessionTimelineStartMs : 0
  }

  private scheduleSessionSave(): void {
    if (this.sessionRestoring || this.sessionRestoreCancelled) {
      return
    }
    if (this.sessionSaveTimer !== undefined) {
      clearTimeout(this.sessionSaveTimer)
    }
    this.sessionSaveTimer = setTimeout((): void => {
      this.sessionSaveTimer = undefined
      void this.persistSession()
    }, 250)
  }

  private async persistSession(): Promise<void> {
    const session = new IDESessionState()
    session.rootPath = this.fileTreeRootPath
    const paths: string[] = []
    for (const tab of this.editorTabs) {
      if (tab.path && paths.indexOf(tab.path) === -1) {
        paths.push(tab.path)
      }
    }
    session.openFiles = paths
    session.activeFilePath = this.activeFilePath
    session.fileTreeVisible = this.fileTreeVisible
    session.terminalVisible = this.terminalVisible
    session.aiVisible = this.aiVisible
    session.fileTreeWidth = this.fileTreeWidth
    session.aiPanelWidth = this.aiPanelWidth
    session.editorWeight = this.editorWeight
    session.terminalWeight = this.terminalWeight
    await this.sessionStore.save(this.getUIContext(), session)
  }

  private async openFile(path: string, silent: boolean = false, activate: boolean = true): Promise<boolean> {
    if (!silent) {
      this.sessionInteractionRevision++
    }
    if (this.findTab(path)) {
      if (activate) {
        this.activeFilePath = path
      }
      this.editorStatus = ''
      this.scheduleSessionSave()
      return true
    }
    if (!path) {
      return false
    }
    if (this.isOpeningFile(path)) {
      if (!silent && this.pendingFileActivations.indexOf(path) === -1) {
        this.pendingFileActivations.push(path)
      }
      return false
    }

    this.openingFilePaths.push(path)
    this.editorBusy = true
    this.editorStatus = ''
    let opened = false
    try {
      const content = await this.fileSystem.readFile(path)
      if (!this.findTab(path)) {
        const newTabs = this.editorTabs.slice()
        newTabs.push(new IDEEditorTab(path, content))
        this.replaceEditorTabs(newTabs)
      }
      if (activate || this.pendingFileActivations.indexOf(path) !== -1) {
        this.activeFilePath = path
      }
      opened = true
      this.scheduleSessionSave()
    } catch (error) {
      this.editorStatus = silent ? '' : (error as Error).message
      if (!silent) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.ide_open_failed') })
      }
    } finally {
      this.removeOpeningFile(path)
      this.removePendingFileActivation(path)
      this.editorBusy = this.openingFilePaths.length > 0
    }
    return opened
  }

  private isOpeningFile(path: string): boolean {
    for (const openingPath of this.openingFilePaths) {
      if (openingPath === path) return true
    }
    return false
  }

  private removeOpeningFile(path: string): void {
    const index = this.openingFilePaths.indexOf(path)
    if (index !== -1) {
      this.openingFilePaths.splice(index, 1)
    }
  }

  private removePendingFileActivation(path: string): void {
    const index = this.pendingFileActivations.indexOf(path)
    if (index !== -1) {
      this.pendingFileActivations.splice(index, 1)
    }
  }

  private selectTab(path: string): void {
    if (!this.findTab(path) || path === this.activeFilePath) {
      return
    }
    this.sessionInteractionRevision++
    const activeTab = this.findTab(this.activeFilePath)
    if (activeTab?.dirty) {
      void this.saveFile(activeTab.path, activeTab.content)
    }
    this.activeFilePath = path
    this.editorStatus = ''
    this.scheduleSessionSave()
  }

  private requestCloseTab(path: string): void {
    const tab = this.findTab(path)
    if (!tab) {
      return
    }
    if (!tab.dirty) {
      this.closeTab(path)
      return
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.ide_unsaved_title'),
      message: $r('app.string.ide_unsaved_message'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      buttons: [
        {
          value: $r('app.string.setting_generic_cancel'),
          action: () => {
          }
        },
        {
          enabled: true,
          style: DialogButtonStyle.HIGHLIGHT,
          value: $r('app.string.ide_discard'),
          action: () => this.closeTab(path)
        }
      ]
    })
  }

  private closeTab(path: string): void {
    const oldIndex = this.findTabIndex(path)
    if (oldIndex === -1) {
      return
    }
    this.sessionInteractionRevision++
    const remaining: IDEEditorTab[] = []
    for (const tab of this.editorTabs) {
      if (tab.path !== path) {
        remaining.push(tab)
      }
    }
    this.replaceEditorTabs(remaining)
    if (this.activeFilePath === path) {
      if (remaining.length === 0) {
        this.activeFilePath = ''
      } else {
        const nextIndex = Math.min(oldIndex, remaining.length - 1)
        this.activeFilePath = remaining[nextIndex].path
      }
    }
    this.editorStatus = ''
    this.scheduleSessionSave()
  }

  private closeSavedFiles(): void {
    const savedPaths: string[] = []
    for (const tab of this.editorTabs) {
      if (!tab.dirty) {
        savedPaths.push(tab.path)
      }
    }
    for (const path of savedPaths) {
      this.closeTab(path)
    }
  }

  private requestCloseAllFiles(): void {
    if (this.editorTabs.length === 0) {
      return
    }
    let hasUnsavedFile: boolean = false
    for (const tab of this.editorTabs) {
      if (tab.dirty) {
        hasUnsavedFile = true
        break
      }
    }
    if (!hasUnsavedFile) {
      this.closeSavedFiles()
      return
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.ide_close_all_unsaved_title'),
      message: $r('app.string.ide_close_all_unsaved_message'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      buttons: [
        {
          value: $r('app.string.setting_generic_cancel'),
          action: () => {
          }
        },
        {
          enabled: true,
          style: DialogButtonStyle.HIGHLIGHT,
          value: $r('app.string.ide_save_and_close'),
          action: () => {
            void this.saveAndCloseAllFiles()
          }
        }
      ]
    })
  }

  private async saveAndCloseAllFiles(): Promise<void> {
    if (this.editorBusy) {
      return
    }
    const paths: string[] = []
    for (const tab of this.editorTabs) {
      paths.push(tab.path)
    }
    this.editorBusy = true
    try {
      for (const path of paths) {
        const tab = this.findTab(path)
        if (!tab) {
          continue
        }
        if (!tab.dirty || await this.saveFile(tab.path, tab.content, false)) {
          this.closeTab(path)
        }
      }
    } finally {
      this.editorBusy = false
      this.scheduleSessionSave()
    }
  }

  private updateEditorContent(path: string, content: string): void {
    const updated: IDEEditorTab[] = []
    for (const tab of this.editorTabs) {
      updated.push(tab.path === path ? new IDEEditorTab(tab.path, content, true) : tab)
    }
    this.replaceEditorTabs(updated)
    this.editorStatus = ''
    if (this.problems.length > 0) {
      this.problemsStatus = 'File changed. Run diagnostics again to refresh Problems.'
    }
  }

  private async saveFile(path: string, content: string, manageBusy: boolean = true): Promise<boolean> {
    const tab = this.findTab(path)
    if (!tab) {
      return false
    }
    if (!tab.dirty) {
      return true
    }
    if (this.editorBusy && manageBusy) {
      return false
    }
    this.updateEditorContent(path, content)
    if (manageBusy) {
      this.editorBusy = true
    }
    this.editorStatus = ''
    try {
      await this.fileSystem.writeFile(path, content)
      const updated: IDEEditorTab[] = []
      let savedCurrentContent: boolean = false
      for (const currentTab of this.editorTabs) {
        if (currentTab.path === path && currentTab.content === content) {
          updated.push(new IDEEditorTab(currentTab.path, currentTab.content, false))
          savedCurrentContent = true
        } else {
          updated.push(currentTab)
        }
      }
      this.replaceEditorTabs(updated)
      if (savedCurrentContent) {
        this.editorStatus = this.getUIContext().getHostContext()?.resourceManager
          .getStringByNameSync('ide_saved') || 'Saved'
      }
      return savedCurrentContent
    } catch (error) {
      this.editorStatus = (error as Error).message
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.ide_save_failed') })
      return false
    } finally {
      if (manageBusy) {
        this.editorBusy = false
      }
    }
  }

  private async runActiveFile(): Promise<void> {
    const tab = this.findTab(this.activeFilePath)
    if (!tab || this.editorBusy || this.runBusy) {
      return
    }

    const command = this.terminalRunner.buildCommand(tab.path)
    if (!command) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.ide_run_unsupported') })
      return
    }

    this.runBusy = true
    this.editorStatus = ''
    try {
      if (tab.dirty) {
        await this.fileSystem.writeFile(tab.path, tab.content)
        const updated: IDEEditorTab[] = []
        for (const currentTab of this.editorTabs) {
          updated.push(currentTab.path === tab.path ?
            new IDEEditorTab(currentTab.path, currentTab.content, false) : currentTab)
        }
        this.replaceEditorTabs(updated)
      }
      this.terminalRunner.send(command)
      this.bottomPanelView = IDEBottomPanelView.TERMINAL
      const prefix = this.getUIContext().getHostContext()?.resourceManager
        .getStringByNameSync('ide_running_file') || 'Running'
      this.editorStatus = prefix + ': ' + tab.name
    } catch (error) {
      this.editorStatus = (error as Error).message
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.ide_run_failed') })
    } finally {
      this.runBusy = false
    }
  }

  private saveActiveFile(): void {
    const tab = this.findTab(this.activeFilePath)
    if (tab?.dirty) {
      void this.saveFile(tab.path, tab.content)
    }
  }

  private issueEditorCommand(command: string): void {
    this.editorCommandSequence++
    this.editorCommandRequest = command + ':' + this.editorCommandSequence
  }

  private applyDiagnosticResult(result: IDEDiagnosticResult): void {
    this.problems = result.problems
    this.pluginStates = this.pluginRegistry.list()
    if (result.failureMessage) {
      this.problemsStatus = '检查失败：' + result.failureMessage
      return
    }
    if (result.unavailableMessage) {
      this.problemsStatus = result.unavailableMessage
      return
    }
    const boundary = result.truncated ? ' (limit reached)' : ''
    const skipped = result.skippedDirectories > 0 ? ', skipped directories ' + result.skippedDirectories : ''
    const failed = result.failedFiles > 0 ? ', failed files ' + result.failedFiles : ''
    this.problemsStatus = 'Checked ' + result.checkedFiles + ' file(s), ' + result.problems.length +
      ' problem(s)' + skipped + failed + boundary + '. Tools: ' + result.toolSummary
  }

  private async checkCurrentFileProblems(): Promise<void> {
    const tab = this.findTab(this.activeFilePath)
    this.terminalVisible = true
    this.bottomPanelView = IDEBottomPanelView.PROBLEMS
    if (!tab) {
      this.problems = []
      this.problemsStatus = 'No active editor file.'
      return
    }
    const request = ++this.problemsRequestSequence
    this.problemsService.cancel()
    this.problemsBusy = true
    this.problemsStatus = 'Checking ' + tab.path + '…'
    if (tab.dirty) {
      const saved = await this.saveFile(tab.path, tab.content)
      if (request !== this.problemsRequestSequence) return
      if (!saved) {
        this.problemsBusy = false
        this.problemsStatus = 'Unable to save the current file; diagnostics were not started.'
        return
      }
    }
    const result = await this.problemsService.diagnoseFile(tab.path)
    if (request !== this.problemsRequestSequence) return
    this.problemsBusy = false
    if (result.cancelled) {
      this.problemsStatus = 'Diagnostics cancelled.'
      return
    }
    this.applyDiagnosticResult(result)
  }

  private async checkProjectProblems(): Promise<void> {
    const request = ++this.problemsRequestSequence
    this.problemsService.cancel()
    this.terminalVisible = true
    this.bottomPanelView = IDEBottomPanelView.PROBLEMS
    this.problemsBusy = true
    this.problemsStatus = 'Checking ' + this.fileTreeRootPath + '…'
    const result = await this.problemsService.diagnoseProject(this.fileTreeRootPath)
    if (request !== this.problemsRequestSequence) return
    this.problemsBusy = false
    if (result.cancelled) {
      this.problemsStatus = 'Diagnostics cancelled.'
      return
    }
    this.applyDiagnosticResult(result)
  }

  private cancelProblems(): void {
    this.problemsRequestSequence++
    this.problemsService.cancel()
    this.problemsBusy = false
    this.problemsStatus = 'Diagnostics cancelled.'
  }

  private clearProblems(): void {
    this.cancelProblems()
    this.problems = []
    this.problemsStatus = ''
  }

  private async openProblem(problem: IDEProblem): Promise<void> {
    const opened = await this.openFile(problem.filePath)
    if (!opened) return
    this.bottomPanelView = IDEBottomPanelView.PROBLEMS
    this.issueEditorCommand('goTo,' + problem.line + ',' + problem.column)
  }

  private resizeEditor(delta: number): void {
    this.editorWeight = Math.max(1, Math.min(5, this.editorWeight + delta))
    this.terminalWeight = Math.max(1, Math.min(5, this.terminalWeight - delta))
    this.scheduleSessionSave()
  }

  private toggleFileTree(): void {
    this.sessionInteractionRevision++
    this.fileTreeVisible = !this.fileTreeVisible
    this.scheduleSessionSave()
  }

  private toggleTerminal(): void {
    this.sessionInteractionRevision++
    this.terminalVisible = !this.terminalVisible
    this.scheduleSessionSave()
  }

  private toggleAI(): void {
    this.sessionInteractionRevision++
    this.aiVisible = !this.aiVisible
    this.scheduleSessionSave()
  }

  private resetPanelLayout(): void {
    this.fileTreeVisible = true
    this.terminalVisible = true
    this.aiVisible = true
    this.terminalExtraKeysVisible = false
    this.editorWeight = 3
    this.terminalWeight = 2
    this.fileTreeWidth = this.compactLayout ? 162 : 202
    this.aiPanelWidth = this.clampAIPanelWidth(this.compactLayout ? 220 : 280)
    this.scheduleSessionSave()
  }

  private resizeFileTree(offset: number): void {
    const minimum = this.compactLayout ? 140 : 160
    const maximum = this.compactLayout ? 262 : 322
    this.fileTreeWidth = Math.max(minimum, Math.min(maximum, this.fileTreeResizeStartWidth + offset))
    this.scheduleSessionSave()
  }

  private resizeAIPanel(offset: number): void {
    this.aiPanelWidth = this.clampAIPanelWidth(this.aiPanelResizeStartWidth - offset)
  }

  private finishAIPanelResize(): void {
    this.scheduleSessionSave()
  }

  private clampAIPanelWidth(width: number): number {
    const preferredMinimum = this.compactLayout ? 180 : 220
    if (this.workbenchAvailableWidth <= 0) {
      return Math.max(preferredMinimum, width)
    }
    const maximum = this.workbenchAvailableWidth * 0.5
    const minimum = Math.min(preferredMinimum, maximum)
    return Math.max(minimum, Math.min(maximum, width))
  }

  private updateWorkbenchAvailableWidth(width: number): void {
    if (width <= 0 || width === this.workbenchAvailableWidth) return
    this.workbenchAvailableWidth = width
    const clamped = this.clampAIPanelWidth(this.aiPanelWidth)
    if (clamped !== this.aiPanelWidth) {
      this.aiPanelWidth = clamped
      this.scheduleSessionSave()
    }
  }

  private resizeEditorTerminal(offset: number): void {
    this.editorWeight = Math.max(1, Math.min(4, this.editorResizeStartWeight + offset / 48))
    this.terminalWeight = 5 - this.editorWeight
    this.scheduleSessionSave()
  }

  private openFolderDialog(): void {
    this.openFolderPath = this.fileTreeRootPath
    this.openFolderError = ''
    this.openFolderBusy = false
    this.openFolderController.open()
  }

  private async confirmOpenFolder(): Promise<void> {
    if (this.openFolderBusy) {
      return
    }
    this.openFolderBusy = true
    this.openFolderError = ''
    try {
      const normalized = this.fileSystem.normalizePath(this.openFolderPath.trim())
      await this.fileSystem.listDirectory(normalized)
      this.sessionInteractionRevision++
      this.fileTreeRootPath = normalized
      this.agentToolBridge.setProjectRoot(normalized)
      this.fileTreeRootRevision++
      this.fileTreeVisible = true
      this.scheduleSessionSave()
      this.openFolderController.close()
    } catch (error) {
      if (error instanceof IDEFileSystemError && error.status === 20) {
        this.openFolderError = this.getUIContext().getHostContext()?.resourceManager
          .getStringByNameSync('ide_open_folder_invalid') || 'The path does not exist or is not a directory.'
      } else {
        this.openFolderError = (error as Error).message
      }
    } finally {
      this.openFolderBusy = false
    }
  }

  private showPluginInfo(plugin: IDEPluginState): void {
    const capabilities: string[] = []
    for (const capability of plugin.manifest.capabilities) {
      capabilities.push(capability)
    }
    const enabled = plugin.enabled ? 'Enabled' : 'Disabled'
    const checker = plugin.checkerStatus === IDEPluginCheckerStatus.AVAILABLE ? 'Available' : 'Unavailable'
    const details = plugin.manifest.type + '\n' + enabled + '\nChecker: ' + checker +
      (plugin.checkerMessage ? '\n' + plugin.checkerMessage : '') + '\n\n' + plugin.manifest.version +
      '\n\n' + plugin.manifest.description +
      (capabilities.length > 0 ? '\n\n' + capabilities.join(', ') : '')
    this.getUIContext().showAlertDialog({
      title: plugin.manifest.name,
      message: details,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      buttons: [{
        value: $r('app.string.SettingComplete_label'),
        action: () => {
        }
      }]
    })
  }

  private setPluginEnabled(id: string, enabled: boolean): void {
    try {
      this.pluginRegistry.setEnabled(id, enabled)
      this.pluginStates = this.pluginRegistry.list()
      if (enabled) void this.refreshPluginAvailability()
    } catch (error) {
      this.pluginStates = this.pluginRegistry.list()
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.ide_plugin_action_failed') })
    }
  }

  private openPluginManager(): void {
    this.pluginStates = this.pluginRegistry.list()
    this.pluginController.open()
    if (!this.problemsBusy) void this.refreshPluginAvailability()
  }

  private async refreshPluginAvailability(): Promise<void> {
    await this.problemsService.refreshPluginAvailability()
    this.pluginStates = this.pluginRegistry.list()
  }

  private updateEditorSelection(selectedText: string, language: string): void {
    this.editorSelectedText = selectedText
    this.editorLanguage = language || 'plaintext'
  }

  private updateEditorStatus(line: number, column: number, encoding: string, lineEnding: string): void {
    this.editorLine = line
    this.editorColumn = column
    this.editorEncoding = encoding
    this.editorLineEnding = lineEnding
  }

  private appendTerminalOutput(output: string): void {
    const combined = this.terminalOutput + output
    this.terminalOutput = combined.length > 12000 ? combined.substring(combined.length - 12000) : combined
  }

  private languageForPath(path: string): string {
    const separator = path.lastIndexOf('.')
    const extension = separator === -1 ? '' : path.substring(separator + 1).toLowerCase()
    if (extension === 'py' || extension === 'pyw') return 'python'
    if (extension === 'sh' || extension === 'bash' || extension === 'zsh') return 'shell'
    if (extension === 'js' || extension === 'jsx' || extension === 'mjs' || extension === 'cjs') return 'javascript'
    if (extension === 'ts' || extension === 'tsx') return 'typescript'
    if (extension === 'c' || extension === 'h' || extension === 'cc' || extension === 'cpp' ||
      extension === 'cxx' || extension === 'hpp') return 'c'
    if (extension === 'java') return 'java'
    if (extension === 'kt' || extension === 'kts') return 'kotlin'
    if (extension === 'rs') return 'rust'
    if (extension === 'go') return 'go'
    if (extension === 'json' || extension === 'json5') return 'json'
    if (extension === 'md' || extension === 'markdown') return 'markdown'
    if (extension === 'html' || extension === 'htm') return 'html'
    if (extension === 'css' || extension === 'scss' || extension === 'less') return 'css'
    if (extension === 'yaml' || extension === 'yml') return 'yaml'
    if (extension === 'xml') return 'xml'
    return 'plaintext'
  }

  private buildAIContext(): IDEAIContext {
    const activeTab = this.findTab(this.activeFilePath)
    const activeBuffer = activeTab ? (this.editorBuffers.get(activeTab.path) ?? activeTab.content) : ''
    const activeLanguage = activeTab ? this.languageForPath(activeTab.path) : 'plaintext'
    const openedFiles: IDEAIFileContext[] = []
    for (const tab of this.editorTabs) {
      openedFiles.push(new IDEAIFileContext(
        tab.path,
        tab.path === this.activeFilePath ? activeLanguage : this.languageForPath(tab.path),
        tab.path === this.activeFilePath ? activeBuffer : '',
        tab.path === this.activeFilePath))
    }
    return new IDEAIContext(
      activeTab?.path || '',
      activeBuffer,
      this.editorSelectedText,
      activeLanguage,
      openedFiles,
      this.terminalOutput)
  }

  private addAIMessage(role: IDEAIMessageRole, content: string): void {
    this.aiMessageSequence++
    const updated = this.aiMessages.slice()
    updated.push(new IDEAIMessage('ai-message-' + this.aiMessageSequence, role, content))
    this.aiMessages = updated
  }

  private async sendAIRequest(prompt: string): Promise<void> {
    if (!prompt.trim() || !this.activeAIProviderId || this.aiBusy) {
      return
    }
    const context = this.buildAIContext()
    this.aiError = ''
    this.addAIMessage(IDEAIMessageRole.USER, prompt.trim())
    this.aiBusy = true
    try {
      const response = await this.aiService.send(
        this.activeAIProviderId, new IDEAIRequest(prompt.trim(), context))
      this.addAIMessage(IDEAIMessageRole.ASSISTANT, response.content)
    } catch (error) {
      const message = this.getUIContext().getHostContext()?.resourceManager
        .getStringByNameSync('ide_ai_request_failed') || 'AI request failed'
      this.aiError = message + ': ' + (error as Error).message
      this.addAIMessage(IDEAIMessageRole.SYSTEM, this.aiError)
    } finally {
      this.aiBusy = false
    }
  }

  private stopAIRequest(): void {
    if (this.aiBusy && this.activeAIProviderId === HISH_LOCAL_PROVIDER_ID) {
      localAIProvider.stop()
    }
  }

  private clearAIConversation(): void {
    if (this.aiBusy) {
      return
    }
    this.aiService.clearConversation()
    this.aiMessages = []
  }

  @Builder
  private buildPluginManager() {
    IDEPluginManagerPanel({
      plugins: this.pluginStates,
      onEnabledChange: (id: string, enabled: boolean) => this.setPluginEnabled(id, enabled),
      onShowInfo: (plugin: IDEPluginState) => this.showPluginInfo(plugin)
    })
  }

  @Builder
  private buildOpenFolderDialog() {
    Column({ space: 10 }) {
      Text($r('app.string.ide_open_folder_path_hint'))
        .fontSize(11)
        .fontColor('#8F98A6')
        .width('100%')
      TextInput({ text: this.openFolderPath, placeholder: '/' })
        .fontSize(13)
        .fontColor('#D7DAE0')
        .backgroundColor('#101216')
        .width('100%')
        .height(36)
        .onChange((value: string) => {
          this.openFolderPath = value
          this.openFolderError = ''
        })
        .onSubmit(() => { void this.confirmOpenFolder() })
      if (this.openFolderBusy) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color('#8F98A6')
      }
      if (this.openFolderError) {
        Text(this.openFolderError)
          .fontSize(11)
          .fontColor('#E5A5A5')
          .width('100%')
          .maxLines(3)
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .alignItems(HorizontalAlign.Start)
  }

  private entryDeleted(path: string): void {
    const remaining: IDEEditorTab[] = []
    let activeWasDeleted = false
    for (const tab of this.editorTabs) {
      if (tab.path === path || tab.path.startsWith(path + '/')) {
        if (tab.path === this.activeFilePath) {
          activeWasDeleted = true
        }
      } else {
        remaining.push(tab)
      }
    }
    this.replaceEditorTabs(remaining)
    if (activeWasDeleted) {
      this.activeFilePath = remaining.length > 0 ? remaining[0].path : ''
    }
    this.scheduleSessionSave()
  }

  private entryRenamed(oldPath: string, newPath: string): void {
    const updated: IDEEditorTab[] = []
    for (const tab of this.editorTabs) {
      if (tab.path === oldPath) {
        updated.push(new IDEEditorTab(newPath, tab.content, tab.dirty))
      } else if (tab.path.startsWith(oldPath + '/')) {
        updated.push(new IDEEditorTab(newPath + tab.path.substring(oldPath.length), tab.content, tab.dirty))
      } else {
        updated.push(tab)
      }
    }
    this.replaceEditorTabs(updated)
    if (this.activeFilePath === oldPath) {
      this.activeFilePath = newPath
    } else if (this.activeFilePath.startsWith(oldPath + '/')) {
      this.activeFilePath = newPath + this.activeFilePath.substring(oldPath.length)
    }
    this.scheduleSessionSave()
  }

  private findTab(path: string): IDEEditorTab | null {
    for (const tab of this.editorTabs) {
      if (tab.path === path) {
        return tab
      }
    }
    return null
  }

  private replaceEditorTabs(tabs: IDEEditorTab[]): void {
    const uniqueTabs: IDEEditorTab[] = []
    const paths: string[] = []
    for (const tab of tabs) {
      if (tab.path && paths.indexOf(tab.path) === -1) {
        paths.push(tab.path)
        uniqueTabs.push(tab)
      }
    }
    const buffers = new Map<string, string>()
    for (const tab of uniqueTabs) {
      buffers.set(tab.path, tab.content)
    }
    this.editorBuffers = buffers
    this.editorTabs = uniqueTabs
  }

  private findTabIndex(path: string): number {
    for (let index = 0; index < this.editorTabs.length; index++) {
      if (this.editorTabs[index].path === path) {
        return index
      }
    }
    return -1
  }

  @Builder
  private panelToggleButton(icon: Resource, active: boolean, label: Resource, action: () => void) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([active ? '#D9E2F2' : '#7E8794'])
    }
    .width(34)
    .height(34)
    .padding(0)
    .margin({ left: 2, right: 2, top: 2, bottom: 2 })
    .backgroundColor(Color.Transparent)
    .accessibilityText(label)
    .onClick(action)
  }

  @Builder
  private pluginButton() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
        .fontSize(18)
        .fontColor(['#8F98A6'])
    }
    .width(34)
    .height(34)
    .padding(0)
    .margin({ left: 2, right: 2, top: 8 })
    .backgroundColor(Color.Transparent)
    .accessibilityText($r('app.string.ide_plugins_title'))
    .onClick(() => this.openPluginManager())
  }

  build() {
    Column() {
      Row() {
        Column() {
          IDEMenuBar({
            fileTreeVisible: this.fileTreeVisible,
            terminalVisible: this.terminalVisible,
            aiVisible: this.aiVisible,
            terminalExtraKeysVisible: this.terminalExtraKeysVisible,
            onSave: (): void => this.saveActiveFile(),
            onOpenFolder: (): void => this.openFolderDialog(),
            onCloseSavedFiles: (): void => this.closeSavedFiles(),
            onCloseAllFiles: (): void => this.requestCloseAllFiles(),
            onPlugins: (): void => this.openPluginManager(),
            onEditorCommand: (command: string): void => this.issueEditorCommand(command),
            onRun: (): void => { void this.runActiveFile() },
            onToggleFileTree: (): void => this.toggleFileTree(),
            onToggleTerminal: (): void => this.toggleTerminal(),
            onToggleAI: (): void => this.toggleAI(),
            onToggleTerminalExtraKeys: (): void => {
              this.terminalExtraKeysVisible = !this.terminalExtraKeysVisible
            },
            onLargerEditor: (): void => this.resizeEditor(1),
            onLargerTerminal: (): void => this.resizeEditor(-1),
            onResetLayout: (): void => this.resetPanelLayout(),
            onOpenVnc: (): void => this.onOpenVnc(),
            onEmulatorManagement: (): void => this.onEmulatorManagement(),
            onRootfsManagement: (): void => this.onRootfsManagement(),
            onSharedFolder: (): void => this.onSharedFolder(),
            onSettings: (): void => this.onSettings(),
            onUserGuide: (): void => this.onUserGuide()
          })

          Column({ space: 6 }) {
            this.panelToggleButton($r('sys.symbol.folder'), this.fileTreeVisible,
              this.fileTreeVisible ? $r('app.string.ide_menu_hide_explorer') :
                $r('app.string.ide_menu_show_explorer'),
              (): void => this.toggleFileTree())
            this.panelToggleButton($r('sys.symbol.code'), this.terminalVisible,
              this.terminalVisible ? $r('app.string.ide_menu_hide_terminal') :
                $r('app.string.ide_menu_show_terminal'),
              (): void => this.toggleTerminal())
            this.panelToggleButton($r('sys.symbol.wand_and_stars'), this.aiVisible,
              this.aiVisible ? $r('app.string.ide_menu_hide_ai') : $r('app.string.ide_menu_show_ai'),
              (): void => this.toggleAI())
            this.pluginButton()
          }
          .margin({ top: 8 })
        }
        .width(38)
        .height('100%')
        .backgroundColor('#181B20')

        if (this.fileTreeVisible) {
          FileTreePanel({
            fileSystem: this.fileSystem,
            rootPath: this.fileTreeRootPath,
            rootRevision: this.fileTreeRootRevision,
            readyToLoad: this.fileSystemReady,
            onOpenFile: (path: string) => this.openFile(path),
            onEntryDeleted: (path: string) => this.entryDeleted(path),
            onEntryRenamed: (oldPath: string, newPath: string) => this.entryRenamed(oldPath, newPath)
          })
            .width(this.fileTreeWidth)

          Row()
            .width(10)
            .height('100%')
            .backgroundColor('#252930')
            .gesture(
              PanGesture({ direction: PanDirection.Horizontal, distance: 1 })
                .onActionStart(() => this.fileTreeResizeStartWidth = this.fileTreeWidth)
                .onActionUpdate((event: GestureEvent) => this.resizeFileTree(event.offsetX))
            )
        }

        Column() {
          CodeEditorPanel({
            tabs: this.editorTabs,
            activeFilePath: this.activeFilePath,
            busy: this.editorBusy,
            statusMessage: this.editorStatus,
            commandRequest: this.editorCommandRequest,
            onTabSelected: (path: string) => this.selectTab(path),
            onTabClose: (path: string) => this.requestCloseTab(path),
            onContentChange: (path: string, content: string) => this.updateEditorContent(path, content),
            onSave: (path: string, content: string) => this.saveFile(path, content),
            onRun: () => this.runActiveFile(),
            onSelectionChange: (selectedText: string, language: string) =>
              this.updateEditorSelection(selectedText, language),
            onStatusChange: (line: number, column: number, encoding: string, lineEnding: string) =>
              this.updateEditorStatus(line, column, encoding, lineEnding)
          })
            .layoutWeight(this.terminalVisible ? this.editorWeight : 1)

          if (this.terminalVisible) {
            Row()
              .width('100%')
              .height(10)
              .backgroundColor('#252930')
              .gesture(
                PanGesture({ direction: PanDirection.Vertical, distance: 1 })
                  .onActionStart(() => this.editorResizeStartWeight = this.editorWeight)
                  .onActionUpdate((event: GestureEvent) => this.resizeEditorTerminal(event.offsetY))
              )

            Column() {
              Row() {
                Column() {
                  Text((this.getUIContext().getHostContext()?.resourceManager
                    .getStringByNameSync('ide_problems_title') || 'Problems') + ' ' + this.problems.length)
                    .height(30)
                    .width('100%')
                    .fontSize(11)
                    .fontColor(this.bottomPanelView === IDEBottomPanelView.PROBLEMS ? '#E0E4EA' : '#87909D')
                    .textAlign(TextAlign.Center)
                    .maxLines(1)
                  if (this.bottomPanelView === IDEBottomPanelView.PROBLEMS) {
                    Row()
                      .width(52)
                      .height(1)
                      .backgroundColor('#767B84')
                      .borderRadius(0)
                  }
                }
                  .width(72)
                  .height(31)
                  .alignItems(HorizontalAlign.Center)
                  .margin({ right: 4 })
                  .onClick(() => this.bottomPanelView = IDEBottomPanelView.PROBLEMS)

                Column() {
                  Text($r('app.string.ide_terminal_title'))
                    .height(30)
                    .width('100%')
                    .fontSize(11)
                    .fontColor(this.bottomPanelView === IDEBottomPanelView.TERMINAL ? '#E0E4EA' : '#87909D')
                    .textAlign(TextAlign.Center)
                    .maxLines(1)
                  if (this.bottomPanelView === IDEBottomPanelView.TERMINAL) {
                    Row()
                      .width(40)
                      .height(1)
                      .backgroundColor('#767B84')
                      .borderRadius(0)
                  }
                }
                  .width(56)
                  .height(31)
                  .alignItems(HorizontalAlign.Center)
                  .onClick(() => this.bottomPanelView = IDEBottomPanelView.TERMINAL)
                Blank()
                if (this.bottomPanelView === IDEBottomPanelView.TERMINAL) {
                  Button(this.runBusy ? $r('app.string.ide_running') : $r('app.string.ide_run'))
                    .fontSize(10)
                    .height(25)
                    .enabled(this.activeFilePath.length > 0 && !this.editorBusy && !this.runBusy)
                    .margin({ right: 10 })
                    .onClick(() => { void this.runActiveFile() })
                }
              }
              .width('100%')
              .height(32)
              .padding({ left: 6, right: 6 })
              .backgroundColor('#181B20')

              Stack() {
                TerminalPanel({
                  headerVisible: false,
                  virtKeyEnabled: this.terminalVirtualKeys,
                  extraKeysVisible: this.terminalExtraKeysVisible,
                  canRun: this.activeFilePath.length > 0 && !this.editorBusy,
                  running: this.runBusy,
                  onRun: () => this.runActiveFile(),
                  onOutput: (output: string) => this.appendTerminalOutput(output)
                })
                  .visibility(this.bottomPanelView === IDEBottomPanelView.TERMINAL ?
                    Visibility.Visible : Visibility.Hidden)

                ProblemsPanel({
                  problems: this.problems,
                  busy: this.problemsBusy,
                  status: this.problemsStatus,
                  onCheckCurrent: (): void => { void this.checkCurrentFileProblems() },
                  onCheckProject: (): void => { void this.checkProjectProblems() },
                  onCancel: (): void => this.cancelProblems(),
                  onClear: (): void => this.clearProblems(),
                  onOpenProblem: (problem: IDEProblem): void => { void this.openProblem(problem) }
                })
                  .visibility(this.bottomPanelView === IDEBottomPanelView.PROBLEMS ?
                    Visibility.Visible : Visibility.Hidden)
              }
              .width('100%')
              .layoutWeight(1)
            }
              .layoutWeight(this.terminalWeight)
              .margin({ left: 6 })
          }
        }
        .height('100%')
        .layoutWeight(1)

        if (this.aiVisible) {
          Row()
            .width(10)
            .height('100%')
            .backgroundColor('#252930')
            .gesture(
              PanGesture({ direction: PanDirection.Horizontal, distance: 1 })
                .onActionStart(() => this.aiPanelResizeStartWidth = this.aiPanelWidth)
                .onActionUpdate((event: GestureEvent) => this.resizeAIPanel(event.offsetX))
                .onActionEnd(() => this.finishAIPanelResize())
                .onActionCancel(() => this.finishAIPanelResize())
            )

          AIWorkspacePanel({
            context: this.buildAIContext(),
            providers: this.aiProviders,
            selectedProviderId: this.activeAIProviderId,
            messages: this.aiMessages,
            busy: this.aiBusy,
            preparing: this.aiPreparing,
            errorText: this.aiError,
            agentProjectRoot: this.fileTreeRootPath,
            agentActiveFilePath: this.activeFilePath,
            agentActiveEditorBuffer: this.buildAIContext().activeFileContent,
            onProviderSelected: (id: string) => this.activeAIProviderId = id,
            onSend: (prompt: string) => this.sendAIRequest(prompt),
            onStop: () => this.stopAIRequest(),
            onClearConversation: () => this.clearAIConversation()
          })
            .width(this.aiPanelWidth)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .onAreaChange((_oldValue: Area, newValue: Area): void => {
        this.updateWorkbenchAvailableWidth(Number(newValue.width))
      })

      IDEStatusBar({
        activeFilePath: this.activeFilePath,
        dirty: this.findTab(this.activeFilePath)?.dirty || false,
        line: this.editorLine,
        column: this.editorColumn,
        encoding: this.editorEncoding,
        lineEnding: this.editorLineEnding
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#111318')
  }
}
