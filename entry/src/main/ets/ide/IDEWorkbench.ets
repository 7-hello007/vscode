import { CustomContentDialog } from '@kit.ArkUI'
import IDEAIService from './ai/IDEAIService'
import { ideAIProviderRegistry } from './ai/IDEAIProviderRegistry'
import AIAssistantPanel from './components/AIAssistantPanel'
import CodeEditorPanel from './components/CodeEditorPanel'
import FileTreePanel from './components/FileTreePanel'
import IDEMenuBar from './components/IDEMenuBar'
import IDEPluginManagerPanel from './components/IDEPluginManagerPanel'
import IDEStatusBar from './components/IDEStatusBar'
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
import { IDEPluginContext, IDEPluginState } from './plugin/IDEPluginContracts'
import IDEPluginRegistry from './plugin/IDEPluginRegistry'
import IDETerminalRunner from './run/IDETerminalRunner'

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
  private aiService: IDEAIService = new IDEAIService(ideAIProviderRegistry)
  private pluginRegistry: IDEPluginRegistry = new IDEPluginRegistry(
    new WorkbenchPluginContext((): string => this.activeFilePath))
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
  @State editorCommandRequest: string = ''
  @State editorCommandSequence: number = 0
  @State pluginStates: IDEPluginState[] = this.pluginRegistry.list()
  @State aiProviders: IDEAIProviderInfo[] = ideAIProviderRegistry.list()
  @State activeAIProviderId: string = ''
  @State aiMessages: IDEAIMessage[] = []
  @State aiBusy: boolean = false
  @State editorSelectedText: string = ''
  @State editorLanguage: string = 'plaintext'
  @State editorLine: number = 1
  @State editorColumn: number = 1
  @State editorEncoding: string = 'UTF-8'
  @State editorLineEnding: string = 'LF'
  @State terminalOutput: string = ''
  @State fileTreeRootPath: string = '/'
  @State openFolderPath: string = '/'
  @State openFolderError: string = ''
  @State openFolderBusy: boolean = false
  private aiMessageSequence: number = 0
  private openingFilePaths: string[] = []
  private fileTreeResizeStartWidth: number = 202
  private aiPanelResizeStartWidth: number = 280
  private editorResizeStartWeight: number = 3

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
    if (this.compactLayout) {
      this.fileTreeWidth = 162
      this.aiPanelWidth = 220
    }
    this.aiProviders = ideAIProviderRegistry.list()
    if (!this.activeAIProviderId) {
      for (const provider of this.aiProviders) {
        if (provider.available) {
          this.activeAIProviderId = provider.id
          break
        }
      }
    }
  }

  private async openFile(path: string): Promise<void> {
    if (this.findTab(path)) {
      this.activeFilePath = path
      this.editorStatus = ''
      return
    }
    if (!path || this.isOpeningFile(path)) {
      return
    }

    this.openingFilePaths.push(path)
    this.editorBusy = true
    this.editorStatus = ''
    try {
      const content = await this.fileSystem.readFile(path)
      if (!this.findTab(path)) {
        const newTabs = this.editorTabs.slice()
        newTabs.push(new IDEEditorTab(path, content))
        this.replaceEditorTabs(newTabs)
      }
      this.activeFilePath = path
    } catch (error) {
      this.editorStatus = (error as Error).message
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.ide_open_failed') })
    } finally {
      this.removeOpeningFile(path)
      this.editorBusy = this.openingFilePaths.length > 0
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

  private selectTab(path: string): void {
    if (!this.findTab(path) || path === this.activeFilePath) {
      return
    }
    const activeTab = this.findTab(this.activeFilePath)
    if (activeTab?.dirty) {
      void this.saveFile(activeTab.path, activeTab.content)
    }
    this.activeFilePath = path
    this.editorStatus = ''
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
  }

  private updateEditorContent(path: string, content: string): void {
    const updated: IDEEditorTab[] = []
    for (const tab of this.editorTabs) {
      updated.push(tab.path === path ? new IDEEditorTab(tab.path, content, true) : tab)
    }
    this.replaceEditorTabs(updated)
    this.editorStatus = ''
  }

  private async saveFile(path: string, content: string): Promise<void> {
    const tab = this.findTab(path)
    if (!tab || !tab.dirty || this.editorBusy) {
      return
    }
    this.updateEditorContent(path, content)
    this.editorBusy = true
    this.editorStatus = ''
    try {
      await this.fileSystem.writeFile(path, content)
      const updated: IDEEditorTab[] = []
      for (const tab of this.editorTabs) {
        updated.push(tab.path === path ? new IDEEditorTab(tab.path, content, false) : tab)
      }
      this.replaceEditorTabs(updated)
      this.editorStatus = this.getUIContext().getHostContext()?.resourceManager
        .getStringByNameSync('ide_saved') || 'Saved'
    } catch (error) {
      this.editorStatus = (error as Error).message
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.ide_save_failed') })
    } finally {
      this.editorBusy = false
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

  private resizeEditor(delta: number): void {
    this.editorWeight = Math.max(1, Math.min(5, this.editorWeight + delta))
    this.terminalWeight = Math.max(1, Math.min(5, this.terminalWeight - delta))
  }

  private resetPanelLayout(): void {
    this.fileTreeVisible = true
    this.terminalVisible = true
    this.aiVisible = true
    this.terminalExtraKeysVisible = false
    this.editorWeight = 3
    this.terminalWeight = 2
    this.fileTreeWidth = this.compactLayout ? 162 : 202
    this.aiPanelWidth = this.compactLayout ? 220 : 280
  }

  private resizeFileTree(offset: number): void {
    const minimum = this.compactLayout ? 140 : 160
    const maximum = this.compactLayout ? 262 : 322
    this.fileTreeWidth = Math.max(minimum, Math.min(maximum, this.fileTreeResizeStartWidth + offset))
  }

  private resizeAIPanel(offset: number): void {
    const minimum = this.compactLayout ? 180 : 220
    const maximum = this.compactLayout ? 320 : 360
    this.aiPanelWidth = Math.max(minimum, Math.min(maximum, this.aiPanelResizeStartWidth - offset))
  }

  private resizeEditorTerminal(offset: number): void {
    this.editorWeight = Math.max(1, Math.min(4, this.editorResizeStartWeight + offset / 48))
    this.terminalWeight = 5 - this.editorWeight
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
      this.fileTreeRootPath = normalized
      this.fileTreeVisible = true
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
    const details = plugin.manifest.version + '\n\n' + plugin.manifest.description +
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
    } catch (error) {
      this.pluginStates = this.pluginRegistry.list()
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.ide_plugin_action_failed') })
    }
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
    const openedFiles: IDEAIFileContext[] = []
    for (const tab of this.editorTabs) {
      openedFiles.push(new IDEAIFileContext(
        tab.path,
        tab.path === this.activeFilePath ? this.editorLanguage : this.languageForPath(tab.path),
        tab.content,
        tab.path === this.activeFilePath))
    }
    return new IDEAIContext(
      activeTab?.path || '',
      activeTab?.content || '',
      this.editorSelectedText,
      activeTab ? this.editorLanguage : 'plaintext',
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
    this.addAIMessage(IDEAIMessageRole.USER, prompt.trim())
    this.aiBusy = true
    try {
      const response = await this.aiService.send(
        this.activeAIProviderId, new IDEAIRequest(prompt.trim(), context))
      this.addAIMessage(IDEAIMessageRole.ASSISTANT, response.content)
    } catch (error) {
      const message = this.getUIContext().getHostContext()?.resourceManager
        .getStringByNameSync('ide_ai_request_failed') || 'AI request failed'
      this.addAIMessage(IDEAIMessageRole.SYSTEM, message + ': ' + (error as Error).message)
    } finally {
      this.aiBusy = false
    }
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
    .onClick(() => this.pluginController.open())
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
            onPlugins: (): void => this.pluginController.open(),
            onEditorCommand: (command: string): void => this.issueEditorCommand(command),
            onRun: (): void => { void this.runActiveFile() },
            onToggleFileTree: (): void => { this.fileTreeVisible = !this.fileTreeVisible },
            onToggleTerminal: (): void => { this.terminalVisible = !this.terminalVisible },
            onToggleAI: (): void => { this.aiVisible = !this.aiVisible },
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
              (): void => { this.fileTreeVisible = !this.fileTreeVisible })
            this.panelToggleButton($r('sys.symbol.code'), this.terminalVisible,
              this.terminalVisible ? $r('app.string.ide_menu_hide_terminal') :
                $r('app.string.ide_menu_show_terminal'),
              (): void => { this.terminalVisible = !this.terminalVisible })
            this.panelToggleButton($r('sys.symbol.wand_and_stars'), this.aiVisible,
              this.aiVisible ? $r('app.string.ide_menu_hide_ai') : $r('app.string.ide_menu_show_ai'),
              (): void => { this.aiVisible = !this.aiVisible })
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

            TerminalPanel({
              virtKeyEnabled: this.terminalVirtualKeys,
              extraKeysVisible: this.terminalExtraKeysVisible,
              canRun: this.activeFilePath.length > 0 && !this.editorBusy,
              running: this.runBusy,
              onRun: () => this.runActiveFile(),
              onOutput: (output: string) => this.appendTerminalOutput(output)
            })
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
            )

          AIAssistantPanel({
            context: this.buildAIContext(),
            providers: this.aiProviders,
            selectedProviderId: this.activeAIProviderId,
            messages: this.aiMessages,
            busy: this.aiBusy,
            onProviderSelected: (id: string) => this.activeAIProviderId = id,
            onSend: (prompt: string) => this.sendAIRequest(prompt)
          })
            .width(this.aiPanelWidth)
        }
      }
      .width('100%')
      .layoutWeight(1)

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
