import { CustomContentDialog } from '@kit.ArkUI'
import IDEAIService from './ai/IDEAIService'
import { ideAIProviderRegistry } from './ai/IDEAIProviderRegistry'
import AIAssistantPanel from './components/AIAssistantPanel'
import CodeEditorPanel from './components/CodeEditorPanel'
import FileTreePanel from './components/FileTreePanel'
import IDEPluginManagerPanel from './components/IDEPluginManagerPanel'
import IDEStatusBar from './components/IDEStatusBar'
import TerminalPanel from './components/TerminalPanel'
import IDEFileSystem from './filesystem/IDEFileSystem'
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
  @State aiVisible: boolean = true
  @State editorWeight: number = 3
  @State terminalWeight: number = 2
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
  private aiMessageSequence: number = 0

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

  aboutToAppear(): void {
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

    this.editorBusy = true
    this.editorStatus = ''
    try {
      const content = await this.fileSystem.readFile(path)
      const newTabs = this.editorTabs.slice()
      newTabs.push(new IDEEditorTab(path, content))
      this.editorTabs = newTabs
      this.activeFilePath = path
    } catch (error) {
      this.editorStatus = (error as Error).message
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.ide_open_failed') })
    } finally {
      this.editorBusy = false
    }
  }

  private selectTab(path: string): void {
    if (this.findTab(path)) {
      this.activeFilePath = path
      this.editorStatus = ''
    }
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
    this.editorTabs = remaining
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
    this.editorTabs = updated
    this.editorStatus = ''
  }

  private async saveFile(path: string, content: string): Promise<void> {
    if (!this.findTab(path) || this.editorBusy) {
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
      this.editorTabs = updated
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
        this.editorTabs = updated
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
    this.aiVisible = true
    this.editorWeight = 3
    this.terminalWeight = 2
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
      onEnabledChange: (id: string, enabled: boolean) => this.setPluginEnabled(id, enabled)
    })
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
    this.editorTabs = remaining
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
    this.editorTabs = updated
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

  private findTabIndex(path: string): number {
    for (let index = 0; index < this.editorTabs.length; index++) {
      if (this.editorTabs[index].path === path) {
        return index
      }
    }
    return -1
  }

  build() {
    Column() {
      Row() {
        FileTreePanel({
          fileSystem: this.fileSystem,
          onOpenFile: (path: string) => this.openFile(path),
          onEntryDeleted: (path: string) => this.entryDeleted(path),
          onEntryRenamed: (oldPath: string, newPath: string) => this.entryRenamed(oldPath, newPath),
          aiVisible: this.aiVisible,
          onSave: (): void => this.saveActiveFile(),
          onPlugins: (): void => this.pluginController.open(),
          onEditorCommand: (command: string): void => this.issueEditorCommand(command),
          onRun: (): void => { void this.runActiveFile() },
          onToggleAI: (): void => { this.aiVisible = !this.aiVisible },
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
          .width(this.compactLayout ? 200 : 240)

        Row()
          .width(1)
          .height('100%')
          .backgroundColor('#30343B')

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
            .layoutWeight(this.editorWeight)

          Row()
            .width('100%')
            .height(1)
            .backgroundColor('#30343B')

          TerminalPanel({
            virtKeyEnabled: this.terminalVirtualKeys,
            canRun: this.activeFilePath.length > 0 && !this.editorBusy,
            running: this.runBusy,
            onRun: () => this.runActiveFile(),
            onOutput: (output: string) => this.appendTerminalOutput(output)
          })
            .layoutWeight(this.terminalWeight)
        }
        .height('100%')
        .layoutWeight(1)

        if (this.aiVisible) {
          Row()
            .width(1)
            .height('100%')
            .backgroundColor('#30343B')

          AIAssistantPanel({
            context: this.buildAIContext(),
            providers: this.aiProviders,
            selectedProviderId: this.activeAIProviderId,
            messages: this.aiMessages,
            busy: this.aiBusy,
            onProviderSelected: (id: string) => this.activeAIProviderId = id,
            onSend: (prompt: string) => this.sendAIRequest(prompt)
          })
            .width(this.compactLayout ? 220 : 280)
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
