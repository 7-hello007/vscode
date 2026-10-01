import IDEFileSystem from '../filesystem/IDEFileSystem'
import { IDEFileEntry, IDEFileType } from '../filesystem/IDEFileSystemTypes'
import IDEMenuBar from './IDEMenuBar'

enum FileTreeAction {
  NONE = 0,
  CREATE_FILE = 1,
  CREATE_DIRECTORY = 2,
  RENAME = 3
}

@Component
export default struct FileTreePanel {
  @Require fileSystem: IDEFileSystem
  @Require onOpenFile: (path: string) => void
  @Require onEntryDeleted: (path: string) => void
  @Require onEntryRenamed: (oldPath: string, newPath: string) => void
  @Prop aiVisible: boolean = true
  @Require onSave: () => void
  @Require onPlugins: () => void
  @Require onEditorCommand: (command: string) => void
  @Require onRun: () => void
  @Require onToggleAI: () => void
  @Require onLargerEditor: () => void
  @Require onLargerTerminal: () => void
  @Require onResetLayout: () => void
  @Require onOpenVnc: () => void
  @Require onEmulatorManagement: () => void
  @Require onRootfsManagement: () => void
  @Require onSharedFolder: () => void
  @Require onSettings: () => void
  @Require onUserGuide: () => void

  @State entries: IDEFileEntry[] = []
  @State currentDirectory: string = '/root'
  @State pathInput: string = '/root'
  @State loading: boolean = true
  @State errorMessage: string = ''
  @State action: FileTreeAction = FileTreeAction.NONE
  @State actionName: string = ''
  @State actionTarget: string = ''

  aboutToAppear(): void {
    this.initialize()
  }

  private async initialize(): Promise<void> {
    try {
      this.currentDirectory = await this.fileSystem.resolveHomeDirectory()
      this.pathInput = this.currentDirectory
    } catch (error) {
      this.currentDirectory = '/root'
      this.pathInput = '/root'
    }
    await this.refreshDirectory()
  }

  private async refreshDirectory(): Promise<void> {
    this.loading = true
    this.errorMessage = ''
    try {
      this.entries = await this.fileSystem.listDirectory(this.currentDirectory)
      this.pathInput = this.currentDirectory
    } catch (error) {
      this.entries = []
      this.errorMessage = (error as Error).message
    } finally {
      this.loading = false
    }
  }

  private async openPath(path: string): Promise<void> {
    try {
      this.currentDirectory = this.fileSystem.normalizePath(path)
      this.pathInput = this.currentDirectory
      this.cancelAction()
      await this.refreshDirectory()
    } catch (error) {
      this.errorMessage = (error as Error).message
    }
  }

  private async activateEntry(entry: IDEFileEntry): Promise<void> {
    if (entry.type === IDEFileType.DIRECTORY) {
      await this.openPath(entry.path)
      return
    }
    if (entry.type === IDEFileType.FILE || entry.type === IDEFileType.SYMBOLIC_LINK) {
      this.onOpenFile(entry.path)
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
        await this.refreshDirectory()
        this.onOpenFile(newFilePath)
      } else if (this.action === FileTreeAction.CREATE_DIRECTORY) {
        await this.fileSystem.createDirectory(this.currentDirectory, this.actionName)
        this.cancelAction()
        await this.refreshDirectory()
      } else if (this.action === FileTreeAction.RENAME) {
        const oldPath = this.actionTarget
        const newPath = await this.fileSystem.renameEntry(oldPath, this.actionName)
        this.cancelAction()
        await this.refreshDirectory()
        this.onEntryRenamed(oldPath, newPath)
      }
    } catch (error) {
      this.errorMessage = (error as Error).message
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
      await this.fileSystem.deleteEntry(entry.path)
      this.onEntryDeleted(entry.path)
      await this.refreshDirectory()
    } catch (error) {
      this.errorMessage = (error as Error).message
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
        IDEMenuBar({
          aiVisible: this.aiVisible,
          onSave: () => this.onSave(),
          onPlugins: () => this.onPlugins(),
          onEditorCommand: (command: string) => this.onEditorCommand(command),
          onRun: () => this.onRun(),
          onToggleAI: () => this.onToggleAI(),
          onLargerEditor: () => this.onLargerEditor(),
          onLargerTerminal: () => this.onLargerTerminal(),
          onResetLayout: () => this.onResetLayout(),
          onOpenVnc: () => this.onOpenVnc(),
          onEmulatorManagement: () => this.onEmulatorManagement(),
          onRootfsManagement: () => this.onRootfsManagement(),
          onSharedFolder: () => this.onSharedFolder(),
          onSettings: () => this.onSettings(),
          onUserGuide: () => this.onUserGuide()
        })
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
          .onClick(() => this.refreshDirectory())
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
          .enabled(this.currentDirectory !== '/')
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
      } else if (this.errorMessage) {
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
            .onClick(() => this.refreshDirectory())
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 14, right: 14 })
        .justifyContent(FlexAlign.Center)
      } else if (this.entries.length === 0) {
        Column({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.folder'))
            .fontSize(28)
            .fontColor(['#7E8794'])
          Text($r('app.string.ide_empty_directory'))
            .fontSize(12)
            .fontColor('#8F98A6')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.entries, (entry: IDEFileEntry) => {
            ListItem() {
              Row({ space: 8 }) {
                SymbolGlyph(entry.type === IDEFileType.DIRECTORY ?
                  $r('sys.symbol.folder_fill') : $r('sys.symbol.doc'))
                  .fontSize(19)
                  .fontColor([entry.type === IDEFileType.DIRECTORY ? '#D5B46A' : '#9AA5B5'])

                Column({ space: 2 }) {
                  Text(entry.name)
                    .fontSize(12)
                    .fontColor('#D7DAE0')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.fileTypeLabel(entry))
                    .fontSize(9)
                    .fontColor('#747E8C')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Text('⋮')
                  .fontSize(18)
                  .fontColor('#8F98A6')
                  .padding({ left: 5, right: 5 })
                  .bindMenu([
                    {
                      value: $r('app.string.btn_rename'),
                      action: () => this.startRename(entry)
                    },
                    {
                      value: $r('app.string.delete_this'),
                      action: () => this.confirmDelete(entry)
                    }
                  ])
              }
              .width('100%')
              .height(44)
              .padding({ left: 10, right: 5 })
              .onClick(() => this.activateEntry(entry))
            }
          }, (entry: IDEFileEntry): string => entry.path)
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
