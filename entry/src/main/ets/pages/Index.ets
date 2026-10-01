import { CustomContentDialog } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import WebTerminal from '../components/WebTerminal'
import SettingsContent from '../components/SettingsContent';
import { SharedFolderContent } from '../components/SharedFolderContent';
import appOption from "../model/appOption";
import { util } from "@kit.ArkTS";
import EmulatorListGrid from "../components/EmulatorListGrid";
import EditEmulatorContent from "../components/EditEmulatorContent";
import { Emulator } from "../model/Emulator";
import RootfsManagementContent from "../components/RootfsManagementContent";
import UserGuide from "../components/UserGuide";
import { webview } from "@kit.ArkWeb";
import VmStatusBar from '../components/VmStatusBar';
import IDEWorkbench from '../ide/IDEWorkbench';

@Component
struct PcIndex {
  @Require terminalVirtualKeys: boolean
  @Prop compactLayout: boolean = false
  @StorageProp(appOption.sharedHost) sharedHost?: string = undefined
  @StorageProp(appOption.sharedGuest) sharedGuest?: string = undefined
  @StorageProp(appOption.displayStatusBar) displayStatusBar: boolean = false
  emulatorManagementController: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      primaryTitle: $r('app.string.emulator_management_title'),
      contentBuilder: () => {
        this.buildSimulatorManagement();
      }
    })
  })
  rootfsManagementController: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      primaryTitle: $r('app.string.image_management_title'),
      contentBuilder: () => {
        this.buildRootfsManagement();
      }
    })
  })
  sharedFolderController: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      primaryTitle: $r('app.string.setting_shared_folder'),
      contentBuilder: () => {
        this.buildSharedFolder();
      }
    })
  })
  settingController: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      primaryTitle: $r('app.string.Setting_title'),
      contentBuilder: () => {
        this.buildSettings();
      }
    })
  })
  userGuideController: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      primaryTitle: $r('app.string.user_guide_title'),
      contentBuilder: () => {
        this.buildGuideList();
      }
    })
  })
  webController = new webview.WebviewController()

  private openVncConsole(): void {
    const vncEnabled = AppStorage.get<boolean>(appOption.vncEnabled)!!
    if (vncEnabled) {
      void this.getUIContext().getRouter().pushUrl({ url: 'pages/VncPage' })
    } else {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.vnc_service_not_started') })
    }
  }

  build() {
    Column() {
      IDEWorkbench({
        terminalVirtualKeys: this.terminalVirtualKeys,
        compactLayout: this.compactLayout,
        onOpenVnc: (): void => this.openVncConsole(),
        onEmulatorManagement: (): void => this.emulatorManagementController.open(),
        onRootfsManagement: (): void => this.rootfsManagementController.open(),
        onSharedFolder: (): void => this.sharedFolderController.open(),
        onSettings: (): void => this.settingController.open(),
        onUserGuide: (): void => this.userGuideController.open()
      })
        .height('100%')
    }
    .width("100%")
    .height('100%')
  }

  @Builder
  buildSimulatorManagement() {
    Column() {
      EmulatorListGrid({
        onEditEmulator: (item, edit) => {
          this.openEditEmulatorDialog(item, edit);
        },
        specifiedBreak: 'xs'
      })
      Button($r('app.string.btn_add'))
        .width('100%')
        .onClick(() => {
          const id = util.generateRandomUUID()
          const emulatorToEdit: Emulator = {
            id,
            name: '',
            init: '/init',
            cpu: 1,
            memory: 512,
            portMapping: [],
            rootVda: '/dev/sda',
            rootFilesystem: '',
            sharedFolderReadonly: false
          }
          this.openEditEmulatorDialog(emulatorToEdit, true)
        })
    }
  }

  private openEditEmulatorDialog(item: Emulator, edit: boolean) {
    const emulatorToEdit: Emulator = {
      id: item.id,
      name: item.name,
      init: item.init,
      cpu: item.cpu,
      memory: item.memory,
      portMapping: item.portMapping,
      rootVda: item.rootVda,
      rootFilesystem: item.rootFilesystem,
      sharedFolderReadonly: item.sharedFolderReadonly
    };
    const controller = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: edit ? $r('app.string.edit_emulator_title') : item.name,
        contentBuilder: () => {
          this.buildEditEmulator(emulatorToEdit, edit, (): void => controller.close());
        }
      })
    });
    controller.open();
  }

  @Builder
  buildRootfsManagement() {
    Column() {
      RootfsManagementContent({
        toolBar: false,
        specifiedBreak: 'xs'
      })
    }
  }

  @Builder
  buildEditEmulator(emulator: Emulator, edit: boolean, onFinished: (item: Emulator) => void) {
    EditEmulatorContent({
      emulator: emulator,
      onFinished: onFinished,
      specifiedBreak: 'xs',
      titleBar: false,
      editing: edit
    })
  }

  @Builder
  buildGuideList() {
    UserGuide({
      openPage: (title: string | Resource, url: string) => {
        const controller = new CustomDialogController({
          builder: CustomContentDialog({
            primaryTitle: title,
            contentBuilder: () => {
              this.buildGuideWebView(url);
            }
          })
        })
        controller.open()
      }
    })
  }

  @Builder
  private buildGuideWebView(url: string) {
    Web({
      src: $rawfile(url),
      controller: this.webController
    }).javaScriptProxy({
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
        }`,
      object: this,
      name: 'native',
      methodList: [],
      controller: this.webController
    })
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.black'));
  }

  @Builder
  buildSettings() {
    SettingsContent()
  }

  @Builder
  buildSharedFolder() {
    Row() {
      if (this.sharedHost) {
        SharedFolderContent({
          host: this.sharedHost,
          guest: this.sharedGuest
        })
      }
    }
  }
}

@Component
struct PhoneOrTablet {
  @StorageProp(appOption.displayStatusBar) displayStatusBar: boolean = false

  build() {
    Column() {
      if (this.displayStatusBar) {
        // 虚拟机状态监控条
        Row() {
          VmStatusBar({ reactive: true })
            .layoutWeight(1)
        }
        .width('100%')
        .height(28)
        .padding({ left: 6, right: 6 })
        .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
      }

      WebTerminal({ virtKeyEnabled: true })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}

@Entry
@Component
struct Index {
  isWorkbenchDevice: boolean = deviceInfo.deviceType === '2in1' || deviceInfo.deviceType === 'tablet'
  isTablet: boolean = deviceInfo.deviceType === 'tablet'

  aboutToAppear(): void {
    // webview.WebviewController.setWebDebuggingAccess(true)
  }

  build() {
    Column() {
      if (this.isWorkbenchDevice) {
        PcIndex({
          terminalVirtualKeys: this.isTablet,
          compactLayout: this.isTablet
        })
      } else {
        PhoneOrTablet()
      }
    }
    .width('100%')
    .height('100%')
  }
}
