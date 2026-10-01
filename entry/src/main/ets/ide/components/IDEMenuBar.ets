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
  @State popupVisible: boolean = false
  @State activeSection: IDEMainMenuSection = IDEMainMenuSection.FILE

  private invoke(action: () => void): void {
    this.popupVisible = false
    action()
  }

  @Builder
  private sectionButton(label: Resource, section: IDEMainMenuSection) {
    Button(label, { buttonStyle: ButtonStyleMode.TEXTUAL })
      .width('100%')
      .height(34)
      .fontSize(12)
      .fontColor(section === this.activeSection ? '#FFFFFF' : '#B7C1CE')
      .backgroundColor(section === this.activeSection ? '#243B63' : Color.Transparent)
      .onClick(() => this.activeSection = section)
  }

  @Builder
  private actionButton(label: ResourceStr, action: () => void) {
    Button(label, { buttonStyle: ButtonStyleMode.TEXTUAL })
      .width('100%')
      .height(34)
      .fontSize(11)
      .fontColor('#D7DAE0')
      .backgroundColor(Color.Transparent)
      .onClick(() => this.invoke(action))
  }

  @Builder
  private actionPanel() {
    Column() {
      if (this.activeSection === IDEMainMenuSection.FILE) {
        this.actionButton($r('app.string.ide_menu_save'), () => this.onSave())
        this.actionButton($r('app.string.ide_menu_plugins'), () => this.onPlugins())
      } else if (this.activeSection === IDEMainMenuSection.EDIT) {
        this.actionButton($r('app.string.ide_menu_undo'), () => this.onEditorCommand('undo'))
        this.actionButton($r('app.string.ide_menu_redo'), () => this.onEditorCommand('redo'))
        this.actionButton($r('app.string.ide_menu_find'), () => this.onEditorCommand('find'))
        this.actionButton($r('app.string.ide_menu_replace'), () => this.onEditorCommand('replace'))
      } else if (this.activeSection === IDEMainMenuSection.SELECTION) {
        this.actionButton($r('app.string.ide_menu_select_all'), () => this.onEditorCommand('selectAll'))
      } else if (this.activeSection === IDEMainMenuSection.VIEW) {
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
    .width(220)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private popupBuilder() {
    Row() {
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
      .width(112)
      .padding(4)
      .backgroundColor('#181B20')

      Divider().vertical(true).height('100%').color('#30343B')

      Scroll() {
        this.actionPanel()
      }
      .width(220)
      .height(280)
      .scrollBar(BarState.Auto)
      .backgroundColor('#20242B')
    }
    .height(280)
    .border({ width: 1, color: '#3B414B' })
    .borderRadius(6)
  }

  build() {
    Button('☰', { buttonStyle: ButtonStyleMode.TEXTUAL })
      .fontSize(20)
      .fontColor('#D7DAE0')
      .height(32)
      .width(38)
      .padding(0)
      .onClick(() => this.popupVisible = !this.popupVisible)
      .bindPopup(this.popupVisible, {
        builder: this.popupBuilder,
        placement: Placement.BottomLeft,
        popupColor: '#20242B',
        enableArrow: false,
        onStateChange: (event: PopupStateChangeParam) => this.popupVisible = event.isVisible
      })
  }
}
