import { util } from '@kit.ArkTS'
import { webview } from '@kit.ArkWeb'
import { IDEEditorTab } from '../model/IDEEditorTab'
import { IDE_SURFACE_DARK_COLOR, IDE_SURFACE_RAISED_COLOR } from '../theme/IDEBackgroundSurfaces'

@Component
export default struct CodeEditorPanel {
  @Watch('onTabsChanged') @Prop tabs: IDEEditorTab[] = []
  @Watch('onActiveFileChanged') @Prop activeFilePath: string = ''
  @Prop busy: boolean = false
  @Watch('onStatusMessageChanged') @Prop statusMessage: string = ''
  @Watch('onCommandRequestChanged') @Prop commandRequest: string = ''
  @Prop tabBarVisible: boolean = true
  @Require onTabSelected: (path: string) => void
  @Require onTabClose: (path: string) => void
  @Require onContentChange: (path: string, content: string) => void
  @Require onSave: (path: string, content: string) => void
  @Require onRun: () => void
  @Require onSelectionChange: (selectedText: string, language: string) => void
  @Require onStatusChange: (line: number, column: number, encoding: string, lineEnding: string) => void

  private webController: WebviewController = new webview.WebviewController()
  private webReady: boolean = false
  private syncedFilePath: string = ''

  private onActiveFileChanged(): void {
    this.syncActiveDocument()
  }

  private onTabsChanged(): void {
    // Parent props can arrive in separate update steps. Only resync when the
    // active document identity has not reached ArkWeb yet; ordinary content
    // edits must not reset the caret on every keystroke.
    if (this.syncedFilePath !== this.activeFilePath) {
      this.syncActiveDocument()
    }
  }

  private onStatusMessageChanged(): void {
    if (!this.webReady || !this.statusMessage) {
      return
    }
    const encodedMessage = this.encodeBase64(this.statusMessage)
    this.runEditorScript(
      "window.hishEditor && window.hishEditor.setErrorBase64('" + encodedMessage + "')")
  }

  private onCommandRequestChanged(): void {
    if (!this.webReady || !this.commandRequest) {
      return
    }
    const separator = this.commandRequest.lastIndexOf(':')
    const command = separator === -1 ? this.commandRequest : this.commandRequest.substring(0, separator)
    if (command === 'undo') {
      this.runEditorScript('window.hishEditor && window.hishEditor.undo()')
    } else if (command === 'redo') {
      this.runEditorScript('window.hishEditor && window.hishEditor.redo()')
    } else if (command === 'find') {
      this.runEditorScript('window.hishEditor && window.hishEditor.openFind()')
    } else if (command === 'replace') {
      this.runEditorScript('window.hishEditor && window.hishEditor.openReplace()')
    } else if (command === 'focus') {
      this.runEditorScript('window.hishEditor && window.hishEditor.focus()')
    } else if (command === 'selectAll') {
      this.runEditorScript('window.hishEditor && window.hishEditor.selectAll()')
    } else if (command === 'goStart') {
      this.runEditorScript('window.hishEditor && window.hishEditor.goStart()')
    } else if (command === 'goEnd') {
      this.runEditorScript('window.hishEditor && window.hishEditor.goEnd()')
    } else if (command.startsWith('goTo,')) {
      const parts = command.split(',')
      const line = parts.length > 1 ? Math.max(1, parseInt(parts[1]) || 1) : 1
      const column = parts.length > 2 ? Math.max(1, parseInt(parts[2]) || 1) : 1
      this.runEditorScript('window.hishEditor && window.hishEditor.goTo(' + line + ',' + column + ')')
    }
  }

  private activeTab(): IDEEditorTab | null {
    for (const tab of this.tabs) {
      if (tab.path === this.activeFilePath) {
        return tab
      }
    }
    return null
  }

  private syncActiveDocument(): void {
    if (!this.webReady) {
      return
    }
    if (!this.activeFilePath) {
      this.runEditorScript('window.hishEditor && window.hishEditor.clearDocument()')
      this.syncedFilePath = ''
      return
    }

    const tab = this.activeTab()
    if (!tab) {
      // A watched active path can temporarily arrive before the corresponding
      // tabs prop. onTabsChanged() retries once the document is available.
      return
    }

    const safePath = tab.path || ''
    if (!safePath) {
      return
    }
    const safeContent = tab.content || ''
    const encodedPath = this.encodeBase64(safePath)
    const encodedContent = this.encodeBase64(safeContent)
    this.runEditorScript(
      "window.hishEditor && window.hishEditor.setDocumentBase64('" + encodedPath + "','" + encodedContent + "')")
    this.syncedFilePath = safePath
  }

  onEditorReady(): void {
    this.webReady = true
    this.syncActiveDocument()
  }

  onEditorContentChanged(encodedPath: string, encodedContent: string): void {
    try {
      const path = this.decodeBase64(encodedPath)
      if (!path) {
        return
      }
      this.onContentChange(path, this.decodeBase64(encodedContent))
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.ide_editor_sync_failed') })
    }
  }

  onEditorSaveRequested(encodedPath: string, encodedContent: string): void {
    try {
      const path = this.decodeBase64(encodedPath)
      if (!path) {
        return
      }
      this.onSave(path, this.decodeBase64(encodedContent))
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.ide_save_failed') })
    }
  }

  onEditorBlurred(encodedPath: string, encodedContent: string): void {
    try {
      const path = this.decodeBase64(encodedPath)
      if (!path || this.busy) {
        return
      }
      for (const tab of this.tabs) {
        if (tab.path === path) {
          if (tab.dirty) {
            this.onSave(path, this.decodeBase64(encodedContent))
          }
          return
        }
      }
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.ide_save_failed') })
    }
  }

  onEditorRunRequested(): void {
    this.onRun()
  }

  onEditorSelectionChanged(encodedSelection: string, encodedLanguage: string): void {
    try {
      this.onSelectionChange(this.decodeBase64(encodedSelection), this.decodeBase64(encodedLanguage) || 'plaintext')
    } catch (error) {
      this.onSelectionChange('', 'plaintext')
    }
  }

  onEditorStatusChanged(line: number, column: number, encodedEncoding: string, encodedLineEnding: string): void {
    const safeLine = Math.max(1, line)
    const safeColumn = Math.max(1, column)
    try {
      this.onStatusChange(safeLine, safeColumn, this.decodeBase64(encodedEncoding) || 'UTF-8',
        this.decodeBase64(encodedLineEnding) || 'LF')
    } catch (error) {
      this.onStatusChange(safeLine, safeColumn, 'UTF-8', 'LF')
    }
  }

  private encodeBase64(value?: string | null): string {
    if (!value || value.length === 0) {
      return ''
    }
    const bytes = util.TextEncoder.create().encodeInto(value)
    if (bytes.length === 0) {
      return ''
    }
    return new util.Base64Helper().encodeToStringSync(bytes)
  }

  private decodeBase64(value?: string | null): string {
    if (!value || value.length === 0) {
      return ''
    }
    const bytes = new util.Base64Helper().decodeSync(value)
    if (bytes.length === 0) {
      return ''
    }
    return util.TextDecoder.create('utf-8').decodeToString(bytes)
  }

  private runEditorScript(script: string): void {
    try {
      this.webController.runJavaScript(script).catch((error: Error) => {
        console.error('HiSH editor JavaScript execution failed: ' + error.message)
      })
    } catch (error) {
      console.error('HiSH editor JavaScript dispatch failed: ' + (error as Error).message)
    }
  }

  build() {
    Column() {
      if (this.tabBarVisible) {
        Row() {
          List({ space: 1 }) {
            ForEach(this.tabs, (tab: IDEEditorTab) => {
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
                  Text('×')
                    .fontSize(15)
                    .fontColor('#8F98A6')
                    .padding({ left: 3, right: 3 })
                    .onClick(() => this.onTabClose(tab.path))
                }
                .height(34)
                .padding({ left: 10, right: 6 })
                .backgroundColor(tab.path === this.activeFilePath ? IDE_SURFACE_RAISED_COLOR : IDE_SURFACE_DARK_COLOR)
                .border({
                  width: { bottom: tab.path === this.activeFilePath ? 2 : 0 },
                  color: '#7AA2F7'
                })
                .onClick(() => this.onTabSelected(tab.path))
              }
            }, (tab: IDEEditorTab): string => tab.path)
          }
          .listDirection(Axis.Horizontal)
          .layoutWeight(1)
          .height(34)
        }
        .width('100%')
        .height(35)
        .backgroundColor(IDE_SURFACE_DARK_COLOR)
      }

      Web({
        src: $rawfile('ide/editor.html'),
        controller: this.webController
      })
        .javaScriptProxy({
          object: this,
          name: 'editorBridge',
          methodList: ['onEditorReady', 'onEditorContentChanged', 'onEditorSaveRequested', 'onEditorBlurred',
            'onEditorRunRequested', 'onEditorSelectionChanged', 'onEditorStatusChanged'],
          asyncMethodList: [],
          controller: this.webController,
          permission: `{
            "javascriptProxyPermission": {
              "urlPermissionList": [
                {
                  "scheme": "resource",
                  "host": "rawfile",
                  "port": "",
                  "path": ""
                }
              ]
            }
          }`
        })
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
