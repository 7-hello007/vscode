import {
  IDE_BORDER_SUBTLE_COLOR,
  IDE_SURFACE_POPUP_COLOR,
  IDE_SURFACE_TOOLBAR_COLOR
} from '../theme/IDEBackgroundSurfaces'

enum IDEMainMenuSection {
  FILE = 0,
  EDIT = 1,
  SELECTION = 2,
  VIEW = 3,
  GO = 4,
  RUN = 5,
  TERMINAL = 6,
  HELP = 7
}

@Component
export default struct IDEMenuBar {
  @Prop fileTreeVisible: boolean = true
  @Prop terminalVisible: boolean = true
  @Prop aiVisible: boolean = true
  @Prop terminalExtraKeysVisible: boolean = false
  @Require onSave: () => void
  @Require onOpenFolder: () => void
  @Require onCloseSavedFiles: () => void
  @Require onCloseAllFiles: () => void
  @Require onPlugins: () => void
  @Require onEditorCommand: (command: string) => void
  @Require onRun: () => void
  @Require onToggleFileTree: () => void
  @Require onToggleTerminal: () => void
  @Require onToggleAI: () => void
  @Require onToggleTerminalExtraKeys: () => void
  @Require onLargerEditor: () => void
  @Require onLargerTerminal: () => void
  @Require onResetLayout: () => void
  @Require onOpenVnc: () => void
  @Require onEmulatorManagement: () => void
  @Require onRootfsManagement: () => void
  @Require onSharedFolder: () => void
  @Require onSettings: () => void
  @Require onUserGuide: () => void
  @State popupVisible: boolean = false
  @State activeSection: IDEMainMenuSection = IDEMainMenuSection.FILE
  @State actionsVisible: boolean = false

  private invoke(action: () => void): void {
    this.popupVisible = false
    this.actionsVisible = false
    action()
  }

  private openSection(section: IDEMainMenuSection): void {
    this.activeSection = section
    this.actionsVisible = true
  }

  private sectionLabel(section: IDEMainMenuSection): Resource {
    if (section === IDEMainMenuSection.FILE) return $r('app.string.ide_menu_file')
    if (section === IDEMainMenuSection.EDIT) return $r('app.string.ide_menu_edit')
    if (section === IDEMainMenuSection.SELECTION) return $r('app.string.ide_menu_selection')
    if (section === IDEMainMenuSection.VIEW) return $r('app.string.ide_menu_view')
    if (section === IDEMainMenuSection.GO) return $r('app.string.ide_menu_go')
    if (section === IDEMainMenuSection.RUN) return $r('app.string.ide_menu_run')
    if (section === IDEMainMenuSection.TERMINAL) return $r('app.string.ide_menu_terminal')
    return $r('app.string.ide_menu_help')
  }

  private actionCount(): number {
    if (this.activeSection === IDEMainMenuSection.FILE) return 5
    if (this.activeSection === IDEMainMenuSection.EDIT) return 4
    if (this.activeSection === IDEMainMenuSection.SELECTION) return 1
    if (this.activeSection === IDEMainMenuSection.VIEW) return 6
    if (this.activeSection === IDEMainMenuSection.GO) return 2
    if (this.activeSection === IDEMainMenuSection.RUN) return 1
    if (this.activeSection === IDEMainMenuSection.TERMINAL) return 7
    return 1
  }

  private popupWidth(): number {
    if (!this.actionsVisible) return 160
    if (this.activeSection === IDEMainMenuSection.TERMINAL ||
      this.activeSection === IDEMainMenuSection.VIEW) return 240
    if (this.activeSection === IDEMainMenuSection.SELECTION ||
      this.activeSection === IDEMainMenuSection.RUN ||
      this.activeSection === IDEMainMenuSection.HELP) return 200
    return 220
  }

  private popupHeight(): number {
    if (!this.actionsVisible) {
      return 280
    }
    return Math.min(280, 39 + this.actionCount() * 34)
  }

  @Builder
  private sectionButton(label: Resource, section: IDEMainMenuSection) {
    Button(label, { buttonStyle: ButtonStyleMode.TEXTUAL })
      .width('100%')
      .height(34)
      .fontSize(12)
      .fontColor('#D7DAE0')
      .backgroundColor(Color.Transparent)
      .stateEffect(true)
      .hoverEffect(HoverEffect.Auto)
      .onClick(() => this.openSection(section))
  }

  @Builder
  private actionButton(label: ResourceStr, action: () => void) {
    Button(label, { buttonStyle: ButtonStyleMode.TEXTUAL })
      .width('100%')
      .height(34)
      .fontSize(11)
      .fontColor('#D7DAE0')
      .backgroundColor(Color.Transparent)
      .stateEffect(true)
      .hoverEffect(HoverEffect.Auto)
      .onClick(() => this.invoke(action))
  }

  @Builder
  private actionPanel() {
    Column() {
      if (this.activeSection === IDEMainMenuSection.FILE) {
        this.actionButton($r('app.string.ide_menu_save'), () => this.onSave())
        this.actionButton($r('app.string.ide_menu_open_folder'), () => this.onOpenFolder())
        this.actionButton($r('app.string.ide_menu_close_saved_files'), () => this.onCloseSavedFiles())
        this.actionButton($r('app.string.ide_menu_close_all_files'), () => this.onCloseAllFiles())
        this.actionButton($r('app.string.ide_menu_plugins'), () => this.onPlugins())
      } else if (this.activeSection === IDEMainMenuSection.EDIT) {
        this.actionButton($r('app.string.ide_menu_undo'), () => this.onEditorCommand('undo'))
        this.actionButton($r('app.string.ide_menu_redo'), () => this.onEditorCommand('redo'))
        this.actionButton($r('app.string.ide_menu_find'), () => this.onEditorCommand('find'))
        this.actionButton($r('app.string.ide_menu_replace'), () => this.onEditorCommand('replace'))
      } else if (this.activeSection === IDEMainMenuSection.SELECTION) {
        this.actionButton($r('app.string.ide_menu_select_all'), () => this.onEditorCommand('selectAll'))
      } else if (this.activeSection === IDEMainMenuSection.VIEW) {
        this.actionButton(this.fileTreeVisible ? $r('app.string.ide_menu_hide_explorer') :
          $r('app.string.ide_menu_show_explorer'), () => this.onToggleFileTree())
        this.actionButton(this.terminalVisible ? $r('app.string.ide_menu_hide_terminal') :
          $r('app.string.ide_menu_show_terminal'), () => this.onToggleTerminal())
        this.actionButton(this.aiVisible ? $r('app.string.ide_menu_hide_ai') :
          $r('app.string.ide_menu_show_ai'), () => this.onToggleAI())
        this.actionButton($r('app.string.ide_menu_larger_editor'), () => this.onLargerEditor())
        this.actionButton($r('app.string.ide_menu_larger_terminal'), () => this.onLargerTerminal())
        this.actionButton($r('app.string.ide_menu_reset_layout'), () => this.onResetLayout())
      } else if (this.activeSection === IDEMainMenuSection.GO) {
        this.actionButton($r('app.string.ide_menu_go_start'), () => this.onEditorCommand('goStart'))
        this.actionButton($r('app.string.ide_menu_go_end'), () => this.onEditorCommand('goEnd'))
      } else if (this.activeSection === IDEMainMenuSection.RUN) {
        this.actionButton($r('app.string.ide_menu_run_file'), () => this.onRun())
      } else if (this.activeSection === IDEMainMenuSection.TERMINAL) {
        this.actionButton(this.terminalExtraKeysVisible ? $r('app.string.ide_menu_hide_extra_keys') :
          $r('app.string.ide_menu_show_extra_keys'), () => this.onToggleTerminalExtraKeys())
        this.actionButton($r('app.string.vnc_console_title'), () => this.onOpenVnc())
        this.actionButton($r('app.string.emulator_management_title'), () => this.onEmulatorManagement())
        this.actionButton($r('app.string.image_management_title'), () => this.onRootfsManagement())
        this.actionButton($r('app.string.setting_shared_folder'), () => this.onSharedFolder())
        this.actionButton($r('app.string.Setting_title'), () => this.onSettings())
        this.actionButton($r('app.string.user_guide_title'), () => this.onUserGuide())
      } else if (this.activeSection === IDEMainMenuSection.HELP) {
        this.actionButton($r('app.string.ide_menu_user_guide'), () => this.onUserGuide())
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private popupBuilder() {
    Column() {
      if (!this.actionsVisible) {
        Column() {
          this.sectionButton($r('app.string.ide_menu_file'), IDEMainMenuSection.FILE)
          this.sectionButton($r('app.string.ide_menu_edit'), IDEMainMenuSection.EDIT)
          this.sectionButton($r('app.string.ide_menu_selection'), IDEMainMenuSection.SELECTION)
          this.sectionButton($r('app.string.ide_menu_view'), IDEMainMenuSection.VIEW)
          this.sectionButton($r('app.string.ide_menu_go'), IDEMainMenuSection.GO)
          this.sectionButton($r('app.string.ide_menu_run'), IDEMainMenuSection.RUN)
          this.sectionButton($r('app.string.ide_menu_terminal'), IDEMainMenuSection.TERMINAL)
          this.sectionButton($r('app.string.ide_menu_help'), IDEMainMenuSection.HELP)
        }
        .width('100%')
        .padding(4)
        .backgroundColor(IDE_SURFACE_POPUP_COLOR)
      } else {
        Row({ space: 8 }) {
          Button('‹', { buttonStyle: ButtonStyleMode.TEXTUAL })
            .width(34)
            .height(34)
            .fontSize(22)
            .fontColor('#D7DAE0')
            .padding(0)
            .backgroundColor(Color.Transparent)
            .onClick(() => this.actionsVisible = false)
          Text(this.sectionLabel(this.activeSection))
            .fontSize(12)
            .fontColor('#D7DAE0')
            .layoutWeight(1)
        }
        .width('100%')
        .height(38)
        .padding({ left: 4, right: 8 })
        .backgroundColor(IDE_SURFACE_TOOLBAR_COLOR)

        Divider().color(IDE_BORDER_SUBTLE_COLOR)

        Scroll() {
          this.actionPanel()
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .backgroundColor(IDE_SURFACE_POPUP_COLOR)
      }
    }
    .width(this.popupWidth())
    .height(this.popupHeight())
    .backgroundColor(IDE_SURFACE_POPUP_COLOR)
    .border({ width: 1, color: IDE_BORDER_SUBTLE_COLOR })
    .borderRadius(6)
  }

  build() {
    Button('☰', { buttonStyle: ButtonStyleMode.TEXTUAL })
      .fontSize(20)
      .fontColor('#D7DAE0')
      .height(32)
      .width(34)
      .margin({ left: 2, right: 2, top: 2, bottom: 2 })
      .padding(0)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        if (!this.popupVisible) {
          this.actionsVisible = false
        }
        this.popupVisible = !this.popupVisible
      })
      .bindPopup(this.popupVisible, {
        builder: this.popupBuilder,
        placement: Placement.BottomLeft,
        popupColor: IDE_SURFACE_POPUP_COLOR,
        enableArrow: false,
        onStateChange: (event: PopupStateChangeParam) => {
          this.popupVisible = event.isVisible
          if (!event.isVisible) {
            this.actionsVisible = false
          }
        }
      })
  }
}
