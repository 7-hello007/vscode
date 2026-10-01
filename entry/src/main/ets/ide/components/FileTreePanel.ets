import IDEFileSystem from '../filesystem/IDEFileSystem'
import { IDEFileEntry, IDEFileType } from '../filesystem/IDEFileSystemTypes'

enum FileTreeAction {
  NONE = 0,
  CREATE_FILE = 1,
  CREATE_DIRECTORY = 2,
  RENAME = 3
}

class FileNode {
  entry: IDEFileEntry
  depth: number
  expanded: boolean = false
  loaded: boolean = false
  loading: boolean = false
  children: FileNode[] = []

  constructor(entry: IDEFileEntry, depth: number) {
    this.entry = entry
    this.depth = depth
  }
}

@Component
export default struct FileTreePanel {
  @Require fileSystem: IDEFileSystem
  @Watch('onRootPathChanged') @Prop rootPath: string = '/'
  @Require onOpenFile: (path: string) => void
  @Require onEntryDeleted: (path: string) => void
  @Require onEntryRenamed: (oldPath: string, newPath: string) => void

  @State visibleNodes: FileNode[] = []
  @State currentDirectory: string = '/'
  @State pathInput: string = '/'
  @State loading: boolean = true
  @State errorMessage: string = ''
  @State action: FileTreeAction = FileTreeAction.NONE
  @State actionName: string = ''
  @State actionTarget: string = ''
  private rootNode: FileNode = new FileNode({
    name: '/',
    path: '/',
    type: IDEFileType.DIRECTORY,
    size: 0
  }, 0)

  aboutToAppear(): void {
    void this.initialize()
  }

  private onRootPathChanged(): void {
    void this.initialize()
  }

  private async initialize(): Promise<void> {
    const normalizedRoot = this.fileSystem.normalizePath(this.rootPath)
    this.rootNode = new FileNode({
      name: this.fileSystem.baseName(normalizedRoot),
      path: normalizedRoot,
      type: IDEFileType.DIRECTORY,
      size: 0
    }, 0)
    this.currentDirectory = normalizedRoot
    this.pathInput = normalizedRoot
    this.rootNode.expanded = true
    this.loading = true
    this.errorMessage = ''
    try {
      await this.loadChildren(this.rootNode, true)
      this.rebuildVisibleNodes()
    } catch (error) {
      this.errorMessage = (error as Error).message
    } finally {
      this.loading = false
    }
  }

  private rebuildVisibleNodes(): void {
    const result: FileNode[] = []
    this.appendVisibleNode(this.rootNode, result)
    this.visibleNodes = result
  }

  private appendVisibleNode(node: FileNode, result: FileNode[]): void {
    result.push(node)
    if (!node.expanded) {
      return
    }
    for (const child of node.children) {
      this.appendVisibleNode(child, result)
    }
  }

  private findNode(path: string, node: FileNode = this.rootNode): FileNode | null {
    if (node.entry.path === path) {
      return node
    }
    for (const child of node.children) {
      const match = this.findNode(path, child)
      if (match) {
        return match
      }
    }
    return null
  }

  private findChild(node: FileNode, path: string): FileNode | null {
    for (const child of node.children) {
      if (child.entry.path === path) {
        return child
      }
    }
    return null
  }

  private mergeChildren(parent: FileNode, entries: IDEFileEntry[]): FileNode[] {
    const merged: FileNode[] = []
    for (const entry of entries) {
      const existing = this.findChild(parent, entry.path)
      if (existing) {
        existing.entry = entry
        existing.depth = parent.depth + 1
        merged.push(existing)
      } else {
        merged.push(new FileNode(entry, parent.depth + 1))
      }
    }
    return merged
  }

  private async loadChildren(node: FileNode, force: boolean = false): Promise<void> {
    if (node.entry.type !== IDEFileType.DIRECTORY || (node.loaded && !force)) {
      return
    }
    node.loading = true
    this.rebuildVisibleNodes()
    try {
      const entries = await this.fileSystem.listDirectory(node.entry.path)
      node.children = this.mergeChildren(node, entries)
      node.loaded = true
    } finally {
      node.loading = false
      this.rebuildVisibleNodes()
    }
  }

  private async refreshLoadedNode(node: FileNode): Promise<void> {
    if (!node.loaded || node.entry.type !== IDEFileType.DIRECTORY) {
      return
    }
    await this.loadChildren(node, true)
    for (const child of node.children) {
      if (child.loaded) {
        await this.refreshLoadedNode(child)
      }
    }
  }

  private async refreshTree(): Promise<void> {
    this.loading = true
    this.errorMessage = ''
    try {
      await this.refreshLoadedNode(this.rootNode)
      this.rebuildVisibleNodes()
    } catch (error) {
      this.errorMessage = (error as Error).message
    } finally {
      this.loading = false
    }
  }

  private async revealDirectory(path: string): Promise<void> {
    const normalized = this.fileSystem.normalizePath(path)
    const rootPath = this.rootNode.entry.path
    if (!this.isWithinRoot(normalized)) {
      throw new Error('Path is outside the opened folder: ' + rootPath)
    }
    let current = this.rootNode
    current.expanded = true
    await this.loadChildren(current)
    if (normalized !== rootPath) {
      const relativePath = normalized.substring(rootPath === '/' ? 1 : rootPath.length + 1)
      const parts = relativePath.split('/')
      let currentPath = rootPath === '/' ? '' : rootPath
      for (const part of parts) {
        if (!part) {
          continue
        }
        currentPath += '/' + part
        const child = this.findChild(current, currentPath)
        if (!child || child.entry.type !== IDEFileType.DIRECTORY) {
          throw new Error('Directory not found: ' + normalized)
        }
        current = child
        current.expanded = true
        await this.loadChildren(current)
      }
    }
    this.currentDirectory = normalized
    this.pathInput = normalized
    this.cancelAction()
    this.rebuildVisibleNodes()
  }

  private isWithinRoot(path: string): boolean {
    const rootPath = this.rootNode.entry.path
    return rootPath === '/' || path === rootPath || path.startsWith(rootPath + '/')
  }

  private async openPath(path: string): Promise<void> {
    this.errorMessage = ''
    try {
      await this.revealDirectory(path)
    } catch (error) {
      this.errorMessage = (error as Error).message
    }
  }

  private async activateNode(node: FileNode): Promise<void> {
    if (node.entry.type === IDEFileType.DIRECTORY) {
      this.currentDirectory = node.entry.path
      this.pathInput = node.entry.path
      this.cancelAction()
      if (node.expanded) {
        node.expanded = false
        this.rebuildVisibleNodes()
        return
      }
      this.errorMessage = ''
      try {
        await this.loadChildren(node)
        node.expanded = true
        this.rebuildVisibleNodes()
      } catch (error) {
        this.errorMessage = (error as Error).message
      }
      return
    }
    if (node.entry.type === IDEFileType.FILE || node.entry.type === IDEFileType.SYMBOLIC_LINK) {
      this.onOpenFile(node.entry.path)
    }
  }

  private startCreateFile(): void {
    this.action = FileTreeAction.CREATE_FILE
    this.actionName = ''
    this.actionTarget = ''
  }

  private startCreateDirectory(): void {
    this.action = FileTreeAction.CREATE_DIRECTORY
    this.actionName = ''
    this.actionTarget = ''
  }

  private startRename(entry: IDEFileEntry): void {
    this.action = FileTreeAction.RENAME
    this.actionName = entry.name
    this.actionTarget = entry.path
  }

  private cancelAction(): void {
    this.action = FileTreeAction.NONE
    this.actionName = ''
    this.actionTarget = ''
  }

  private async refreshNode(path: string): Promise<void> {
    const node = this.findNode(path)
    if (node && node.entry.type === IDEFileType.DIRECTORY) {
      await this.loadChildren(node, true)
      this.rebuildVisibleNodes()
      return
    }
    await this.refreshTree()
  }

  private async confirmAction(): Promise<void> {
    if (!this.actionName.trim()) {
      return
    }
    this.loading = true
    this.errorMessage = ''
    try {
      if (this.action === FileTreeAction.CREATE_FILE) {
        const newFilePath = await this.fileSystem.createFile(this.currentDirectory, this.actionName)
        this.cancelAction()
        await this.refreshNode(this.currentDirectory)
        this.onOpenFile(newFilePath)
      } else if (this.action === FileTreeAction.CREATE_DIRECTORY) {
        await this.fileSystem.createDirectory(this.currentDirectory, this.actionName)
        this.cancelAction()
        await this.refreshNode(this.currentDirectory)
      } else if (this.action === FileTreeAction.RENAME) {
        const oldPath = this.actionTarget
        const parentPath = this.fileSystem.parentPath(oldPath)
        const newPath = await this.fileSystem.renameEntry(oldPath, this.actionName)
        if (this.currentDirectory === oldPath || this.currentDirectory.startsWith(oldPath + '/')) {
          this.currentDirectory = newPath + this.currentDirectory.substring(oldPath.length)
          this.pathInput = this.currentDirectory
        }
        this.cancelAction()
        await this.refreshNode(parentPath)
        this.onEntryRenamed(oldPath, newPath)
      }
    } catch (error) {
      this.errorMessage = (error as Error).message
    } finally {
      this.loading = false
    }
  }

  private confirmDelete(entry: IDEFileEntry): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.ide_delete_title'),
      message: $r('app.string.ide_delete_message'),
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
          backgroundColor: $r('sys.color.warning'),
          value: $r('app.string.confirm_remove'),
          action: async () => {
            await this.deleteEntry(entry)
          }
        }
      ]
    })
  }

  private async deleteEntry(entry: IDEFileEntry): Promise<void> {
    this.loading = true
    this.errorMessage = ''
    try {
      const parentPath = this.fileSystem.parentPath(entry.path)
      await this.fileSystem.deleteEntry(entry.path)
      if (this.currentDirectory === entry.path || this.currentDirectory.startsWith(entry.path + '/')) {
        this.currentDirectory = parentPath
        this.pathInput = parentPath
      }
      this.onEntryDeleted(entry.path)
      await this.refreshNode(parentPath)
    } catch (error) {
      this.errorMessage = (error as Error).message
    } finally {
      this.loading = false
    }
  }

  private fileTypeLabel(entry: IDEFileEntry): ResourceStr {
    if (entry.type === IDEFileType.DIRECTORY) {
      return $r('app.string.ide_directory_label')
    }
    if (entry.type === IDEFileType.SYMBOLIC_LINK) {
      return $r('app.string.ide_link_label')
    }
    return this.formatSize(entry.size)
  }

  private formatSize(size: number): string {
    if (size < 1024) {
      return size + ' B'
    }
    if (size < 1024 * 1024) {
      return (size / 1024).toFixed(1) + ' KB'
    }
    return (size / (1024 * 1024)).toFixed(1) + ' MB'
  }

  build() {
    Column() {
      Row() {
        Blank()
        Button($r('app.string.ide_new_file_short'))
          .fontSize(11)
          .fontColor('#D7DAE0')
          .backgroundColor(Color.Transparent)
          .padding({ left: 5, right: 5 })
          .onClick(() => this.startCreateFile())
        Button($r('app.string.ide_new_folder_short'))
          .fontSize(11)
          .fontColor('#D7DAE0')
          .backgroundColor(Color.Transparent)
          .padding({ left: 5, right: 5 })
          .onClick(() => this.startCreateDirectory())
        Button($r('app.string.ide_refresh_short'))
          .fontSize(13)
          .fontColor('#D7DAE0')
          .backgroundColor(Color.Transparent)
          .padding({ left: 5, right: 5 })
          .onClick(() => this.refreshTree())
      }
      .width('100%')
      .height(36)
      .padding({ left: 12, right: 6 })

      Divider()
        .strokeWidth(1)
        .color('#30343B')

      Row({ space: 4 }) {
        Button('..')
          .fontSize(12)
          .fontColor('#D7DAE0')
          .backgroundColor('#292D35')
          .height(28)
          .padding({ left: 8, right: 8 })
          .enabled(this.currentDirectory !== this.rootNode.entry.path)
          .onClick(() => this.openPath(this.fileSystem.parentPath(this.currentDirectory)))

        TextInput({ text: this.pathInput })
          .fontSize(11)
          .fontColor('#D7DAE0')
          .backgroundColor('#101216')
          .height(28)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.pathInput = value
          })
          .onSubmit(() => this.openPath(this.pathInput))
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 7, bottom: 7 })

      if (this.action !== FileTreeAction.NONE) {
        Row({ space: 4 }) {
          TextInput({
            text: this.actionName,
            placeholder: this.action === FileTreeAction.RENAME ?
              $r('app.string.ide_rename_placeholder') : $r('app.string.ide_name_placeholder')
          })
            .fontSize(12)
            .fontColor('#D7DAE0')
            .backgroundColor('#101216')
            .height(30)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.actionName = value
            })
            .onSubmit(() => this.confirmAction())

          Button($r('app.string.ide_confirm_short'))
            .fontSize(11)
            .height(30)
            .padding({ left: 7, right: 7 })
            .enabled(this.actionName.trim().length > 0)
            .onClick(() => this.confirmAction())

          Button($r('app.string.ide_cancel_short'))
            .fontSize(11)
            .height(30)
            .padding({ left: 7, right: 7 })
            .onClick(() => this.cancelAction())
        }
        .width('100%')
        .padding({ left: 8, right: 8, bottom: 7 })
      }

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(28)
            .height(28)
            .color('#7AA2F7')
          Text($r('app.string.ide_loading_files'))
            .fontSize(12)
            .fontColor('#8F98A6')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMessage && this.visibleNodes.length === 0) {
        Column({ space: 10 }) {
          Text($r('app.string.ide_file_service_unavailable'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#E5A5A5')
          Text(this.errorMessage)
            .fontSize(11)
            .fontColor('#9BA3AF')
            .textAlign(TextAlign.Center)
            .maxLines(4)
          Button($r('app.string.btn_retry'))
            .onClick(() => this.initialize())
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 14, right: 14 })
        .justifyContent(FlexAlign.Center)
      } else {
        if (this.errorMessage) {
          Text(this.errorMessage)
            .fontSize(10)
            .fontColor('#E5A5A5')
            .maxLines(2)
            .padding({ left: 8, right: 8, bottom: 4 })
        }
        List() {
          ForEach(this.visibleNodes, (node: FileNode) => {
            ListItem() {
              Row({ space: 5 }) {
                if (node.entry.type === IDEFileType.DIRECTORY) {
                  if (node.loading) {
                    LoadingProgress()
                      .width(13)
                      .height(13)
                      .color('#8F98A6')
                  } else {
                    Text(node.expanded ? '⌄' : '›')
                      .width(13)
                      .fontSize(15)
                      .fontColor('#8F98A6')
                      .textAlign(TextAlign.Center)
                  }
                } else {
                  Blank().width(13)
                }

                SymbolGlyph(node.entry.type === IDEFileType.DIRECTORY ?
                  (node.expanded ? $r('sys.symbol.folder_fill') : $r('sys.symbol.folder')) :
                  $r('sys.symbol.doc'))
                  .fontSize(17)
                  .fontColor([node.entry.type === IDEFileType.DIRECTORY ? '#D5B46A' : '#9AA5B5'])

                Column({ space: 1 }) {
                  Text(node.entry.name)
                    .fontSize(12)
                    .fontColor('#D7DAE0')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.fileTypeLabel(node.entry))
                    .fontSize(9)
                    .fontColor('#747E8C')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                if (node.entry.path !== this.rootNode.entry.path) {
                  Text('⋮')
                    .fontSize(18)
                    .fontColor('#8F98A6')
                    .padding({ left: 5, right: 5 })
                    .bindMenu([
                      {
                        value: $r('app.string.btn_rename'),
                        action: () => this.startRename(node.entry)
                      },
                      {
                        value: $r('app.string.delete_this'),
                        action: () => this.confirmDelete(node.entry)
                      }
                    ])
                }
              }
              .width('100%')
              .height(40)
              .padding({ left: 7 + node.depth * 14, right: 5 })
              .backgroundColor(node.entry.path === this.currentDirectory ? '#222831' : Color.Transparent)
              .onClick(() => this.activateNode(node))
            }
          }, (node: FileNode): string => node.entry.path)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#181B20')
  }
}
