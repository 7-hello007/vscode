import { CustomContentDialog } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { fileIo as hostFs, fileUri, picker } from '@kit.CoreFileKit'
import copyFile from '../lib/copyFile'
import IDEAIService from './ai/IDEAIService'
import { ideAIProviderRegistry } from './ai/IDEAIProviderRegistry'
import { HISH_LOCAL_PROVIDER_ID, localAIProvider } from './ai/LocalAIProvider'
import { codexAgentProvider } from './agent/CodexAgentProvider'
import HiSHAgentToolBridge from './agent/HiSHAgentToolBridge'
import IDEAgentCommandRunner from './agent/IDEAgentCommandRunner'
import AIWorkspacePanel from './components/AIWorkspacePanel'
import BinaryViewerPanel from './components/BinaryViewerPanel'
import CSVViewerPanel from './components/CSVViewerPanel'
import CodeEditorPanel from './components/CodeEditorPanel'
import DocumentViewerPanel from './components/DocumentViewerPanel'
import FileTreePanel from './components/FileTreePanel'
import IDEMenuBar from './components/IDEMenuBar'
import IDEPluginManagerPanel from './components/IDEPluginManagerPanel'
import IDEStatusBar from './components/IDEStatusBar'
import MarkdownViewerPanel from './components/MarkdownViewerPanel'
import PDFViewerPanel from './components/PDFViewerPanel'
import PresentationViewerPanel from './components/PresentationViewerPanel'
import ProblemsPanel from './components/ProblemsPanel'
import SpreadsheetViewerPanel from './components/SpreadsheetViewerPanel'
import TerminalPanel from './components/TerminalPanel'
import IDEDocumentRuntime from './document/IDEDocumentRuntime'
import IDEFileSystem from './filesystem/IDEFileSystem'
import { IDEFileSystemError } from './filesystem/IDEFileSystemTypes'
import BinaryEditSessionStore from './model/BinaryEditSessionStore'
import { IDEEditorTab, IDEEditorViewerType } from './model/IDEEditorTab'
import {
  IDEAIContext,
  IDEAIFileContext,
  IDEAIMessage,
  IDEAIMessageRole,
  IDEAIProviderInfo,
  IDEAIRequest
} from './model/IDEAIContracts'
import { IDEPluginCheckerStatus, IDEPluginContext, IDEPluginState } from './plugin/IDEPluginContracts'
import {
  BINARY_VIEWER_PLUGIN_ID,
  BinaryViewerPlugin,
  CSV_VIEWER_PLUGIN_ID,
  CSVViewerPlugin,
  GLOBAL_BACKGROUND_PLUGIN_ID,
  GlobalBackgroundPlugin,
  MARKDOWN_VIEWER_PLUGIN_ID,
  MarkdownViewerPlugin,
  OFFICE_VIEWER_PLUGIN_ID,
  OfficeViewerPlugin,
  PDF_VIEWER_PLUGIN_ID,
  PDFViewerPlugin
} from './plugin/BuiltInViewerPlugins'
import FileViewerRegistry, { IDEFileViewerKind, IDEFileViewerOptions } from './plugin/FileViewerRegistry'
import PluginManager from './plugin/PluginManager'
import IDEPluginRegistry from './plugin/IDEPluginRegistry'
import PythonDiagnosticPlugin from './plugin/PythonDiagnosticPlugin'
import { IDEDiagnosticResult, IDEProblem } from './problems/IDEProblemContracts'
import IDEProblemsService from './problems/IDEProblemsService'
import IDETerminalRunner from './run/IDETerminalRunner'
import IDESessionStore, { IDESessionState } from './session/IDESessionStore'
import { terminalLifecycleBridge } from '../lib/TerminalLifecycleBridge'
import IDEWebUploadFileAdapter from './webai/IDEWebUploadFileAdapter'
import {
  IDE_BORDER_SUBTLE_COLOR,
  IDE_SPLITTER_COLOR,
  IDE_SURFACE_COLOR,
  IDE_SURFACE_DARK_COLOR,
  IDE_SURFACE_HOVER_COLOR,
  IDE_SURFACE_POPUP_COLOR,
  IDE_SURFACE_RAISED_COLOR,
  IDE_SURFACE_SELECTED_COLOR
} from './theme/IDEBackgroundSurfaces'

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
  private pluginManager: PluginManager = new PluginManager(this.pluginRegistry)
  private fileViewerRegistry: FileViewerRegistry = new FileViewerRegistry()
  private documentRuntime: IDEDocumentRuntime = new IDEDocumentRuntime(this.fileSystem)
  private binaryEditStore: BinaryEditSessionStore = new BinaryEditSessionStore()
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
  @State pluginsVisible: boolean = false
  @State activeViewerKind: IDEFileViewerKind = IDEFileViewerKind.TEXT
  @State activeViewerType: string = 'Text'
  @State markdownPreview: boolean = true
  @State csvTextPaths: string[] = []
  @State backgroundImagePath: string = ''
  @State backgroundImageUri: string = ''
  @State backgroundOpacity: number = 50
  @State binaryRevision: number = 0
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
  private webUploadAdapter: IDEWebUploadFileAdapter | null = null
  private pendingWebUploadSelection: ((files: string[]) => void) | null = null
  @State webUploadBusy: boolean = false
  @State webUploadError: string = ''

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

  private backgroundSettingsController: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      primaryTitle: '全局背景',
      contentBuilder: () => {
        this.buildGlobalBackgroundSettings()
      },
      buttons: [{
        value: $r('app.string.SettingComplete_label'),
        buttonStyle: ButtonStyleMode.TEXTUAL,
        action: (): void => this.backgroundSettingsController.close()
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

  private webUploadFileController: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      primaryTitle: 'Choose HiSH File',
      contentBuilder: () => {
        this.buildHiSHUploadFileChooser()
      },
      buttons: [{
        value: $r('app.string.setting_generic_cancel'),
        buttonStyle: ButtonStyleMode.TEXTUAL,
        action: (): void => this.completeHiSHUploadSelection([])
      }]
    }),
    autoCancel: false
  })

  aboutToAppear(): void {
    codexAgentProvider.attachToolBridge(this.agentToolBridge)
    this.agentToolBridge.setProjectRoot(this.fileTreeRootPath)
    const abilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext
    if (abilityContext) this.documentRuntime.setContext(abilityContext)
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
    this.pluginManager.register(new PythonDiagnosticPlugin(), true)
    this.pluginManager.register(new BinaryViewerPlugin(), true)
    this.pluginManager.register(new MarkdownViewerPlugin(), true)
    this.pluginManager.register(new GlobalBackgroundPlugin(), false)
    this.pluginManager.register(new PDFViewerPlugin(), true)
    this.pluginManager.register(new OfficeViewerPlugin(), true)
    this.pluginManager.register(new CSVViewerPlugin(), true)
    this.pluginsInitialized = true
    this.pluginStates = this.pluginManager.getPlugins()
    void this.restorePluginState()
  }

  private async restorePluginState(): Promise<void> {
    const persisted = await this.pluginManager.restore(this.getUIContext())
    this.pluginStates = this.pluginManager.getPlugins()
    this.backgroundOpacity = persisted.backgroundOpacity
    if (persisted.backgroundImagePath && hostFs.accessSync(persisted.backgroundImagePath, hostFs.AccessModeType.EXIST)) {
      this.backgroundImagePath = persisted.backgroundImagePath
      this.backgroundImageUri = fileUri.getUriFromPath(persisted.backgroundImagePath)
    } else {
      this.backgroundImagePath = ''
      this.backgroundImageUri = ''
    }
    this.reconcileActiveViewer()
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
    if (this.pendingWebUploadSelection) this.completeHiSHUploadSelection([])
    if (this.webUploadAdapter) void this.webUploadAdapter.cleanup()
    this.documentRuntime.releaseAll()
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
        if (this.activeFilePath) this.activateViewerForTextPath(this.activeFilePath)
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
        this.activateViewerForTextPath(path)
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
      const sample = await this.fileSystem.readBinary(path, 0, 512)
      const viewerOptions = new IDEFileViewerOptions()
      viewerOptions.markdownEnabled = this.pluginManager.isEnabled(MARKDOWN_VIEWER_PLUGIN_ID)
      viewerOptions.pdfEnabled = this.pluginManager.isEnabled(PDF_VIEWER_PLUGIN_ID)
      viewerOptions.officeEnabled = this.pluginManager.isEnabled(OFFICE_VIEWER_PLUGIN_ID)
      viewerOptions.csvEnabled = this.pluginManager.isEnabled(CSV_VIEWER_PLUGIN_ID)
      const resolution = this.fileViewerRegistry.resolve(path, sample, viewerOptions)
      if (resolution.kind === IDEFileViewerKind.BINARY || resolution.kind === IDEFileViewerKind.PDF ||
        resolution.kind === IDEFileViewerKind.DOCUMENT || resolution.kind === IDEFileViewerKind.SPREADSHEET ||
        resolution.kind === IDEFileViewerKind.PRESENTATION) {
        if (!this.pluginManager.isEnabled(BINARY_VIEWER_PLUGIN_ID)) {
          if (resolution.kind === IDEFileViewerKind.BINARY) throw new Error('Binary Viewer plugin is disabled')
        }
        if (!this.findTab(path)) {
          const newTabs = this.editorTabs.slice()
          let viewerType = IDEEditorViewerType.BINARY
          if (resolution.kind === IDEFileViewerKind.PDF) viewerType = IDEEditorViewerType.PDF
          else if (resolution.kind === IDEFileViewerKind.DOCUMENT) viewerType = IDEEditorViewerType.DOCUMENT
          else if (resolution.kind === IDEFileViewerKind.SPREADSHEET) viewerType = IDEEditorViewerType.SPREADSHEET
          else if (resolution.kind === IDEFileViewerKind.PRESENTATION) viewerType = IDEEditorViewerType.PRESENTATION
          newTabs.push(new IDEEditorTab(path, '', false, viewerType, true, resolution.detectedType))
          this.replaceEditorTabs(newTabs)
        }
        if (activate || this.pendingFileActivations.indexOf(path) !== -1) {
          this.activeFilePath = path
          this.activeViewerKind = resolution.kind
          this.activeViewerType = resolution.detectedType
        }
        opened = true
        this.scheduleSessionSave()
        return opened
      }
      const content = await this.fileSystem.readFile(path)
      if (!this.findTab(path)) {
        const newTabs = this.editorTabs.slice()
        const viewerType = resolution.kind === IDEFileViewerKind.MARKDOWN ?
          IDEEditorViewerType.MARKDOWN : (resolution.kind === IDEFileViewerKind.CSV ?
            IDEEditorViewerType.CSV : IDEEditorViewerType.TEXT)
        newTabs.push(new IDEEditorTab(path, content, false, viewerType, true, resolution.detectedType))
        this.replaceEditorTabs(newTabs)
      }
      if (activate || this.pendingFileActivations.indexOf(path) !== -1) {
        this.activeFilePath = path
        this.activeViewerKind = resolution.kind
        this.activeViewerType = resolution.detectedType
        this.markdownPreview = resolution.kind === IDEFileViewerKind.MARKDOWN
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

  private activateViewerForTextPath(path: string): void {
    const tab = this.findTab(path)
    if (!tab) return
    this.activeViewerType = tab.detectedType
    if (tab?.viewerType === IDEEditorViewerType.BINARY) {
      this.activeViewerKind = IDEFileViewerKind.BINARY
      return
    }
    if (tab.viewerType === IDEEditorViewerType.PDF) {
      this.activeViewerKind = this.pluginManager.isEnabled(PDF_VIEWER_PLUGIN_ID) ?
        IDEFileViewerKind.PDF : IDEFileViewerKind.BINARY
      return
    }
    if (tab.viewerType === IDEEditorViewerType.DOCUMENT) {
      this.activeViewerKind = this.pluginManager.isEnabled(OFFICE_VIEWER_PLUGIN_ID) ?
        IDEFileViewerKind.DOCUMENT : IDEFileViewerKind.BINARY
      return
    }
    if (tab.viewerType === IDEEditorViewerType.SPREADSHEET) {
      this.activeViewerKind = this.pluginManager.isEnabled(OFFICE_VIEWER_PLUGIN_ID) ?
        IDEFileViewerKind.SPREADSHEET : IDEFileViewerKind.BINARY
      return
    }
    if (tab.viewerType === IDEEditorViewerType.PRESENTATION) {
      this.activeViewerKind = this.pluginManager.isEnabled(OFFICE_VIEWER_PLUGIN_ID) ?
        IDEFileViewerKind.PRESENTATION : IDEFileViewerKind.BINARY
      return
    }
    if (tab.viewerType === IDEEditorViewerType.CSV) {
      this.activeViewerKind = this.pluginManager.isEnabled(CSV_VIEWER_PLUGIN_ID) ?
        IDEFileViewerKind.CSV : IDEFileViewerKind.TEXT
      return
    }
    if (tab?.viewerType === IDEEditorViewerType.MARKDOWN) {
      this.activeViewerKind = this.pluginManager.isEnabled(MARKDOWN_VIEWER_PLUGIN_ID) ?
        IDEFileViewerKind.MARKDOWN : IDEFileViewerKind.TEXT
      this.markdownPreview = this.activeViewerKind === IDEFileViewerKind.MARKDOWN
      return
    }
    const lower = path.toLowerCase()
    const markdown = (lower.endsWith('.md') || lower.endsWith('.markdown')) &&
      this.pluginManager.isEnabled(MARKDOWN_VIEWER_PLUGIN_ID)
    this.activeViewerKind = markdown ? IDEFileViewerKind.MARKDOWN : IDEFileViewerKind.TEXT
    this.activeViewerType = markdown ? 'Markdown' : tab.detectedType
    this.markdownPreview = markdown
  }

  private reconcileActiveViewer(): void {
    if (this.activeFilePath && this.findTab(this.activeFilePath)) {
      this.activateViewerForTextPath(this.activeFilePath)
    }
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
      if (activeTab.viewerType === IDEEditorViewerType.BINARY) {
        void this.saveBinaryFile(activeTab.path)
      } else {
        void this.saveFile(activeTab.path, activeTab.content)
      }
    }
    this.activeFilePath = path
    this.activateViewerForTextPath(path)
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
          value: $r('app.string.ide_discard'),
          action: () => this.closeTab(path)
        },
        {
          enabled: true,
          style: DialogButtonStyle.HIGHLIGHT,
          value: $r('app.string.ide_save_and_close'),
          action: () => { void this.saveTabAndClose(path) }
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
    this.csvTextPaths = this.csvTextPaths.filter((value: string): boolean =>
      value !== path && !value.startsWith(path + '/'))
    this.binaryEditStore.clear(path)
    this.documentRuntime.release(path)
    if (this.activeFilePath === path) {
      if (remaining.length === 0) {
        this.activeFilePath = ''
        this.activeViewerKind = IDEFileViewerKind.TEXT
      } else {
        const nextIndex = Math.min(oldIndex, remaining.length - 1)
        this.activeFilePath = remaining[nextIndex].path
        this.activateViewerForTextPath(this.activeFilePath)
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
        const saved = !tab.dirty || (tab.viewerType === IDEEditorViewerType.BINARY ?
          await this.saveBinaryFile(tab.path, false) : await this.saveFile(tab.path, tab.content, false))
        if (saved) {
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
      updated.push(tab.path === path ?
        new IDEEditorTab(tab.path, content, true, tab.viewerType, tab.closable, tab.detectedType) : tab)
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
          updated.push(new IDEEditorTab(currentTab.path, currentTab.content, false,
            currentTab.viewerType, currentTab.closable, currentTab.detectedType))
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

  private markBinaryDirty(path: string, dirty: boolean): void {
    const updated: IDEEditorTab[] = []
    for (const tab of this.editorTabs) {
      updated.push(tab.path === path ? new IDEEditorTab(tab.path, tab.content, dirty,
        tab.viewerType, tab.closable, tab.detectedType) : tab)
    }
    this.replaceEditorTabs(updated)
    this.editorStatus = ''
  }

  private async saveBinaryFile(path: string, manageBusy: boolean = true): Promise<boolean> {
    const tab = this.findTab(path)
    if (!tab || tab.viewerType !== IDEEditorViewerType.BINARY) return false
    if (!tab.dirty) return true
    if (this.editorBusy && manageBusy) return false
    if (manageBusy) this.editorBusy = true
    this.editorStatus = ''
    try {
      const patches = this.binaryEditStore.buildPatches(path)
      for (const patch of patches) {
        await this.fileSystem.writeBinary(path, patch.offset, patch.bytes)
      }
      this.binaryEditStore.clear(path)
      this.markBinaryDirty(path, false)
      this.binaryRevision++
      this.editorStatus = this.getUIContext().getHostContext()?.resourceManager
        .getStringByNameSync('ide_saved') || 'Saved'
      return true
    } catch (error) {
      this.editorStatus = (error as Error).message
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.ide_save_failed') })
      return false
    } finally {
      if (manageBusy) this.editorBusy = false
    }
  }

  private async saveTabAndClose(path: string): Promise<void> {
    const tab = this.findTab(path)
    if (!tab) return
    const saved = tab.viewerType === IDEEditorViewerType.BINARY ?
      await this.saveBinaryFile(path) : await this.saveFile(path, tab.content)
    if (saved) this.closeTab(path)
  }

  private async runActiveFile(): Promise<void> {
    const tab = this.findTab(this.activeFilePath)
    if (!tab || this.editorBusy || this.runBusy) {
      return
    }

    if (tab.viewerType !== IDEEditorViewerType.TEXT && tab.viewerType !== IDEEditorViewerType.MARKDOWN) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.ide_run_unsupported') })
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
            new IDEEditorTab(currentTab.path, currentTab.content, false,
              currentTab.viewerType, currentTab.closable, currentTab.detectedType) : currentTab)
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
      if (tab.viewerType === IDEEditorViewerType.BINARY) {
        void this.saveBinaryFile(tab.path)
      } else {
        void this.saveFile(tab.path, tab.content)
      }
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
    if (this.pluginsVisible) {
      this.pluginsVisible = false
      this.fileTreeVisible = true
      this.scheduleSessionSave()
      return
    }
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
    if (plugin.manifest.id === GLOBAL_BACKGROUND_PLUGIN_ID) {
      this.backgroundSettingsController.open()
      return
    }
    const capabilities: string[] = []
    for (const capability of plugin.manifest.capabilities) {
      capabilities.push(capability)
    }
    const enabled = plugin.enabled ? '已启用' : '已禁用'
    const checker = plugin.checkerStatus === IDEPluginCheckerStatus.AVAILABLE ? '可用' : '不可用'
    const details = plugin.manifest.type + '\n' + enabled + '\n检查器：' + checker +
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
      const changed = this.pluginManager.setEnabled(id, enabled, this.getUIContext())
      if (!changed) throw new Error('Plugin lifecycle failed')
      this.pluginStates = this.pluginManager.getPlugins()
      this.reconcileActiveViewer()
      if (enabled) void this.refreshPluginAvailability()
    } catch (error) {
      this.pluginStates = this.pluginManager.getPlugins()
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.ide_plugin_action_failed') })
    }
  }

  private openPluginManager(): void {
    this.pluginStates = this.pluginManager.getPlugins()
    this.pluginsVisible = !this.pluginsVisible
    this.fileTreeVisible = true
    if (!this.problemsBusy) void this.refreshPluginAvailability()
  }

  private async refreshPluginAvailability(): Promise<void> {
    await this.problemsService.refreshPluginAvailability()
    this.pluginStates = this.pluginManager.getPlugins()
  }

  private backgroundVisible(): boolean {
    for (const state of this.pluginStates) {
      if (state.manifest.id === GLOBAL_BACKGROUND_PLUGIN_ID) {
        return state.enabled && !!this.backgroundImageUri
      }
    }
    return false
  }

  private platformPluginStates(): IDEPluginState[] {
    const states: IDEPluginState[] = []
    for (const state of this.pluginStates) {
      if (state.manifest.id === BINARY_VIEWER_PLUGIN_ID || state.manifest.id === MARKDOWN_VIEWER_PLUGIN_ID ||
        state.manifest.id === GLOBAL_BACKGROUND_PLUGIN_ID || state.manifest.id === PDF_VIEWER_PLUGIN_ID ||
        state.manifest.id === OFFICE_VIEWER_PLUGIN_ID || state.manifest.id === CSV_VIEWER_PLUGIN_ID) {
        states.push(state)
      }
    }
    return states
  }

  private async chooseBackgroundImage(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext
      const options = new picker.DocumentSelectOptions()
      options.fileSuffixFilters = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp']
      options.maxSelectNumber = 1
      const uris = await new picker.DocumentViewPicker(context).select(options)
      if (uris.length === 0) return
      const cleanUri = uris[0].split('?')[0]
      const dot = cleanUri.lastIndexOf('.')
      let extension = dot === -1 ? '.image' : cleanUri.substring(dot).toLowerCase()
      if (extension.length > 8 || extension.indexOf('/') !== -1) extension = '.image'
      const applicationContext = context.getApplicationContext()
      const target = applicationContext.filesDir + '/hish-global-background-' + Date.now() + extension
      const temporary = target + '.tmp'
      if (hostFs.accessSync(temporary, hostFs.AccessModeType.EXIST)) await hostFs.unlink(temporary)
      await copyFile(uris[0], temporary)
      const copied = await hostFs.stat(temporary)
      if (copied.size <= 0) throw new Error('Selected image is empty')
      await hostFs.rename(temporary, target)
      const previous = this.backgroundImagePath
      this.backgroundImagePath = target
      this.backgroundImageUri = fileUri.getUriFromPath(target)
      this.pluginManager.updateBackground(this.getUIContext(), target, this.backgroundOpacity)
      if (previous && previous !== target && hostFs.accessSync(previous, hostFs.AccessModeType.EXIST)) {
        try { await hostFs.unlink(previous) } catch (error) {}
      }
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: 'Unable to use the selected background image' })
    }
  }

  private updateBackgroundOpacity(value: number): void {
    this.backgroundOpacity = Math.max(0, Math.min(100, Math.round(value)))
    this.pluginManager.updateBackground(this.getUIContext(), this.backgroundImagePath, this.backgroundOpacity)
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

  private chooseHiSHUploadFiles(): Promise<string[]> {
    if (!this.fileSystemReady) {
      this.getUIContext().getPromptAction().showToast({ message: 'HiSH file service is not ready' })
      return Promise.resolve([])
    }
    if (this.pendingWebUploadSelection) {
      this.completeHiSHUploadSelection([])
    }
    this.webUploadBusy = false
    this.webUploadError = ''
    return new Promise<string[]>((resolve: (files: string[]) => void): void => {
      this.pendingWebUploadSelection = resolve
      this.webUploadFileController.open()
    })
  }

  private completeHiSHUploadSelection(files: string[]): void {
    const completion = this.pendingWebUploadSelection
    this.pendingWebUploadSelection = null
    this.webUploadBusy = false
    this.webUploadFileController.close()
    if (completion) completion(files)
  }

  private async selectHiSHUploadFile(path: string): Promise<void> {
    if (this.webUploadBusy || !this.pendingWebUploadSelection) return
    this.webUploadBusy = true
    this.webUploadError = ''
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext
      if (!this.webUploadAdapter) {
        this.webUploadAdapter = new IDEWebUploadFileAdapter(this.fileSystem, context)
      }
      const uri = await this.webUploadAdapter.stageHiSHFile(path)
      this.completeHiSHUploadSelection([uri])
    } catch (error) {
      this.webUploadError = (error as Error).message || 'Unable to prepare the selected file'
      this.webUploadBusy = false
    }
  }

  @Builder
  private buildPluginManager() {
    IDEPluginManagerPanel({
      plugins: this.platformPluginStates(),
      onEnabledChange: (id: string, enabled: boolean) => this.setPluginEnabled(id, enabled),
      onShowInfo: (plugin: IDEPluginState) => this.showPluginInfo(plugin)
    })
  }

  @Builder
  private buildGlobalBackgroundSettings() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text('背景图片')
            .fontSize(12)
            .fontColor('#D7DAE0')
          Text(this.backgroundImagePath ? '已选择图片' : '未选择图片')
            .fontSize(10)
            .fontColor('#8D96A3')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button('选择图片')
          .height(30)
          .fontSize(11)
          .backgroundColor(IDE_SURFACE_HOVER_COLOR)
          .onClick(() => { void this.chooseBackgroundImage() })
      }
      .width('100%')

      Row({ space: 8 }) {
        Text('透明度')
          .fontSize(11)
          .fontColor('#AAB2BD')
          .width(52)
        Slider({ value: this.backgroundOpacity, min: 0, max: 100, step: 1 })
          .layoutWeight(1)
          .onChange((value: number) => this.updateBackgroundOpacity(value))
        Text(Math.round(this.backgroundOpacity) + '%')
          .fontSize(10)
          .fontColor('#AAB2BD')
          .width(36)
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(IDE_SURFACE_POPUP_COLOR)
    .border({ width: 1, color: IDE_BORDER_SUBTLE_COLOR })
    .borderRadius(6)
  }

  @Builder
  private buildHiSHUploadFileChooser() {
    Column({ space: 6 }) {
      if (this.webUploadError) {
        Text(this.webUploadError)
          .width('100%')
          .fontSize(10)
          .fontColor('#E5A5A5')
          .maxLines(2)
      }
      if (this.webUploadBusy) {
        Row({ space: 8 }) {
          LoadingProgress().width(18).height(18).color('#8F98A6')
          Text('Preparing file for upload…')
            .fontSize(10)
            .fontColor('#AAB2BD')
        }
        .width('100%')
      }
      FileTreePanel({
        fileSystem: this.fileSystem,
        rootPath: this.fileTreeRootPath,
        rootRevision: this.fileTreeRootRevision,
        readyToLoad: this.fileSystemReady,
        selectionMode: true,
        onOpenFile: (path: string): void => { void this.selectHiSHUploadFile(path) },
        onEntryDeleted: (_path: string): void => {},
        onEntryRenamed: (_oldPath: string, _newPath: string): void => {}
      })
        .width('100%')
        .height(420)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  private buildEditorTabBar() {
    Row() {
      List({ space: 1 }) {
        ForEach(this.editorTabs, (tab: IDEEditorTab) => {
          ListItem() {
            Row({ space: 7 }) {
              SymbolGlyph($r('sys.symbol.doc_text'))
                .fontSize(13)
                .fontColor([tab.path === this.activeFilePath ? '#C5CCD6' : '#7E8794'])
              Text(tab.name + (tab.dirty ? ' ●' : ''))
                .fontSize(11)
                .fontColor(tab.path === this.activeFilePath ? '#E2E5EA' : '#939CAA')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (tab.closable) {
                Text('×')
                  .fontSize(15)
                  .fontColor('#8F98A6')
                  .padding({ left: 3, right: 3 })
                  .onClick(() => this.requestCloseTab(tab.path))
              }
            }
            .height(34)
            .padding({ left: 10, right: 6 })
            .backgroundColor(tab.path === this.activeFilePath ? IDE_SURFACE_SELECTED_COLOR : IDE_SURFACE_DARK_COLOR)
            .border({
              width: { bottom: tab.path === this.activeFilePath ? 2 : 0 },
              color: '#7AA2F7'
            })
            .onClick(() => this.selectTab(tab.path))
          }
        }, (tab: IDEEditorTab): string => tab.path + ':' + (tab.dirty ? 'dirty' : 'saved') + ':' + tab.viewerType)
      }
      .listDirection(Axis.Horizontal)
      .layoutWeight(1)
      .height(34)
    }
    .width('100%')
    .height(35)
    .backgroundColor(IDE_SURFACE_DARK_COLOR)
  }

  @Builder
  private buildCodeEditor() {
    CodeEditorPanel({
      tabs: this.editorTabs,
      activeFilePath: this.activeFilePath,
      busy: this.editorBusy,
      statusMessage: this.editorStatus,
      commandRequest: this.editorCommandRequest,
      tabBarVisible: false,
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
  }

  @Builder
  private buildEditorViewer() {
    Column() {
      this.buildEditorTabBar()
      if (this.activeViewerKind === IDEFileViewerKind.BINARY && this.activeFilePath) {
        if (this.pluginManager.isEnabled(BINARY_VIEWER_PLUGIN_ID)) {
          BinaryViewerPanel({
            fileSystem: this.fileSystem,
            editStore: this.binaryEditStore,
            path: this.activeFilePath,
            detectedType: this.activeViewerType,
            revision: this.binaryRevision,
            onDirtyChange: (path: string, dirty: boolean) => this.markBinaryDirty(path, dirty)
          })
            .layoutWeight(1)
        } else {
          Text('Binary Viewer plugin is disabled')
            .fontSize(12)
            .fontColor('#AAB2BD')
            .padding(16)
            .width('100%')
            .layoutWeight(1)
        }
      } else if (this.activeViewerKind === IDEFileViewerKind.MARKDOWN && this.activeFilePath) {
        Row({ space: 4 }) {
          Button('Edit')
            .fontSize(10)
            .height(28)
            .backgroundColor(this.markdownPreview ? Color.Transparent : IDE_SURFACE_SELECTED_COLOR)
            .onClick(() => this.markdownPreview = false)
          Button('Preview')
            .fontSize(10)
            .height(28)
            .backgroundColor(this.markdownPreview ? IDE_SURFACE_SELECTED_COLOR : Color.Transparent)
            .onClick(() => this.markdownPreview = true)
          Blank()
          Text(this.activeFilePath)
            .fontSize(10)
            .fontColor('#89929F')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .height(34)
        .padding({ left: 8, right: 10 })
        .backgroundColor(IDE_SURFACE_RAISED_COLOR)

        if (this.markdownPreview) {
          MarkdownViewerPanel({
            path: this.activeFilePath,
            content: this.editorBuffers.get(this.activeFilePath) ?? this.findTab(this.activeFilePath)?.content ?? ''
          })
            .layoutWeight(1)
        } else {
          Column() {
            this.buildCodeEditor()
          }
          .layoutWeight(1)
        }
      } else if (this.activeViewerKind === IDEFileViewerKind.PDF && this.activeFilePath) {
        PDFViewerPanel({
          path: this.activeFilePath,
          runtime: this.documentRuntime
        })
          .layoutWeight(1)
      } else if (this.activeViewerKind === IDEFileViewerKind.DOCUMENT && this.activeFilePath) {
        DocumentViewerPanel({
          path: this.activeFilePath,
          legacy: this.activeViewerType === 'DOC',
          runtime: this.documentRuntime
        })
          .layoutWeight(1)
      } else if (this.activeViewerKind === IDEFileViewerKind.SPREADSHEET && this.activeFilePath) {
        SpreadsheetViewerPanel({
          path: this.activeFilePath,
          legacy: this.activeViewerType === 'XLS',
          runtime: this.documentRuntime
        })
          .layoutWeight(1)
      } else if (this.activeViewerKind === IDEFileViewerKind.CSV && this.activeFilePath) {
        if (this.isCsvTextMode(this.activeFilePath)) {
          Row({ space: 8 }) {
            Button('View Table', { buttonStyle: ButtonStyleMode.TEXTUAL })
              .fontSize(10).height(28).backgroundColor(Color.Transparent)
              .onClick(() => this.viewCsvAsTable(this.activeFilePath))
            Text('View Text').fontSize(11).fontColor('#E1E5EA').fontWeight(FontWeight.Medium)
          }
          .width('100%').height(36).padding({ left: 12 }).backgroundColor(IDE_SURFACE_RAISED_COLOR)
          Column() { this.buildCodeEditor() }.layoutWeight(1)
        } else {
          CSVViewerPanel({
            path: this.activeFilePath,
            content: this.editorBuffers.get(this.activeFilePath) ?? this.findTab(this.activeFilePath)?.content ?? '',
            runtime: this.documentRuntime,
            onViewText: (path: string) => this.viewCsvAsText(path)
          })
            .layoutWeight(1)
        }
      } else if (this.activeViewerKind === IDEFileViewerKind.PRESENTATION && this.activeFilePath) {
        PresentationViewerPanel({
          path: this.activeFilePath,
          legacy: this.activeViewerType === 'PPT',
          runtime: this.documentRuntime
        })
          .layoutWeight(1)
      } else {
        Column() {
          this.buildCodeEditor()
        }
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }

  private viewCsvAsText(path: string): void {
    if (this.csvTextPaths.indexOf(path) === -1) this.csvTextPaths = this.csvTextPaths.concat([path])
  }

  private viewCsvAsTable(path: string): void {
    this.csvTextPaths = this.csvTextPaths.filter((value: string): boolean => value !== path)
  }

  private isCsvTextMode(path: string): boolean {
    return this.csvTextPaths.indexOf(path) !== -1
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
        this.binaryEditStore.clear(tab.path)
        this.documentRuntime.release(tab.path)
        if (tab.path === this.activeFilePath) {
          activeWasDeleted = true
        }
      } else {
        remaining.push(tab)
      }
    }
    this.replaceEditorTabs(remaining)
    this.csvTextPaths = this.csvTextPaths.filter((value: string): boolean =>
      value !== path && !value.startsWith(path + '/'))
    if (activeWasDeleted) {
      this.activeFilePath = remaining.length > 0 ? remaining[0].path : ''
    }
    this.scheduleSessionSave()
  }

  private entryRenamed(oldPath: string, newPath: string): void {
    const updated: IDEEditorTab[] = []
    for (const tab of this.editorTabs) {
      if (tab.path === oldPath) {
        this.binaryEditStore.rename(tab.path, newPath)
        this.documentRuntime.release(tab.path)
        updated.push(new IDEEditorTab(newPath, tab.content, tab.dirty, tab.viewerType, tab.closable, tab.detectedType))
      } else if (tab.path.startsWith(oldPath + '/')) {
        const renamedPath = newPath + tab.path.substring(oldPath.length)
        this.binaryEditStore.rename(tab.path, renamedPath)
        this.documentRuntime.release(tab.path)
        updated.push(new IDEEditorTab(renamedPath, tab.content, tab.dirty, tab.viewerType, tab.closable,
          tab.detectedType))
      } else {
        updated.push(tab)
      }
    }
    this.replaceEditorTabs(updated)
    const csvPaths: string[] = []
    for (const path of this.csvTextPaths) {
      if (path === oldPath) csvPaths.push(newPath)
      else if (path.startsWith(oldPath + '/')) csvPaths.push(newPath + path.substring(oldPath.length))
      else csvPaths.push(path)
    }
    this.csvTextPaths = csvPaths
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
        .fontColor([this.pluginsVisible ? '#D9E2F2' : '#8F98A6'])
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
    Stack() {
      if (this.backgroundVisible()) {
        Image(this.backgroundImageUri)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.backgroundOpacity / 100)
          .hitTestBehavior(HitTestMode.None)
          .zIndex(0)
      }

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
        .backgroundColor(IDE_SURFACE_COLOR)
        .border({ width: { right: 1 }, color: '#59616D' })

        if (this.fileTreeVisible) {
          if (this.pluginsVisible) {
            Column() {
              Row() {
                Text('插件')
                  .fontSize(11)
                  .fontColor('#BFC5CF')
                  .fontWeight(FontWeight.Medium)
                Blank()
              }
              .width('100%')
              .height(36)
              .padding({ left: 12, right: 8 })
              .backgroundColor(IDE_SURFACE_RAISED_COLOR)
              Column() {
                this.buildPluginManager()
              }
              .layoutWeight(1)
              .padding({ left: 8, right: 8 })
            }
            .width(this.fileTreeWidth)
            .height('100%')
            .backgroundColor(IDE_SURFACE_COLOR)
          } else {
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
          }

          Row()
            .width(10)
            .height('100%')
            .backgroundColor(IDE_SPLITTER_COLOR)
            .gesture(
              PanGesture({ direction: PanDirection.Horizontal, distance: 1 })
                .onActionStart(() => this.fileTreeResizeStartWidth = this.fileTreeWidth)
                .onActionUpdate((event: GestureEvent) => this.resizeFileTree(event.offsetX))
            )
        }

        Column() {
          Column() {
            this.buildEditorViewer()
          }
          .layoutWeight(this.terminalVisible ? this.editorWeight : 1)

          if (this.terminalVisible) {
            Row()
              .width('100%')
              .height(10)
              .backgroundColor(IDE_SPLITTER_COLOR)
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
                    .fontColor('#D7DAE0')
                    .height(25)
                    .backgroundColor(IDE_SURFACE_HOVER_COLOR)
                    .enabled(this.activeFilePath.length > 0 && !this.editorBusy && !this.runBusy)
                    .margin({ right: 10 })
                    .onClick(() => { void this.runActiveFile() })
                }
              }
              .width('100%')
              .height(32)
              .padding({ left: 6, right: 6 })
              .backgroundColor(IDE_SURFACE_RAISED_COLOR)

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
        .backgroundColor(IDE_SURFACE_DARK_COLOR)

        if (this.aiVisible) {
          Row()
            .width(10)
            .height('100%')
            .backgroundColor(IDE_SPLITTER_COLOR)
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
            onClearConversation: () => this.clearAIConversation(),
            onChooseHiSHUploadFiles: (): Promise<string[]> => this.chooseHiSHUploadFiles()
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
      .backgroundColor(this.backgroundVisible() ? Color.Transparent : '#111318')
      .zIndex(1)
    }
    .width('100%')
    .height('100%')
  }
}
