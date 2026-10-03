import {
  IDEPlugin,
  IDEPluginCapability,
  IDEPluginCheckerStatus,
  IDEPluginContext,
  IDEPluginManifest,
  IDEPluginType
} from './IDEPluginContracts'

export const BINARY_VIEWER_PLUGIN_ID = 'hish.binary-viewer'
export const MARKDOWN_VIEWER_PLUGIN_ID = 'hish.markdown-viewer'
export const GLOBAL_BACKGROUND_PLUGIN_ID = 'hish.global-background'
export const PDF_VIEWER_PLUGIN_ID = 'hish.pdf-viewer'
export const OFFICE_VIEWER_PLUGIN_ID = 'hish.office-viewer'
export const CSV_VIEWER_PLUGIN_ID = 'hish.csv-viewer'

abstract class BuiltInPlugin implements IDEPlugin {
  abstract manifest: IDEPluginManifest
  checkerStatus: IDEPluginCheckerStatus = IDEPluginCheckerStatus.AVAILABLE
  checkerMessage: string = '内置插件'
  protected active: boolean = false

  activate(context: IDEPluginContext): void {
    this.active = true
  }

  deactivate(): void {
    this.active = false
  }
}

export class BinaryViewerPlugin extends BuiltInPlugin {
  manifest: IDEPluginManifest = {
    id: BINARY_VIEWER_PLUGIN_ID,
    name: '二进制查看器',
    version: '1.0.0',
    description: '支持分页、二进制安全读取的 OFFSET、HEX 和 ASCII 查看器。',
    type: IDEPluginType.FILE_VIEWER,
    capabilities: [IDEPluginCapability.FILE_VIEWER]
  }
}

export class MarkdownViewerPlugin extends BuiltInPlugin {
  manifest: IDEPluginManifest = {
    id: MARKDOWN_VIEWER_PLUGIN_ID,
    name: 'Markdown 查看器',
    version: '1.0.0',
    description: '提供编辑和安全预览模式的 Markdown 查看器。',
    type: IDEPluginType.FILE_VIEWER,
    capabilities: [IDEPluginCapability.FILE_VIEWER]
  }
}

export class GlobalBackgroundPlugin extends BuiltInPlugin {
  manifest: IDEPluginManifest = {
    id: GLOBAL_BACKGROUND_PLUGIN_ID,
    name: '全局背景',
    version: '1.0.0',
    description: '支持持久化本地图片和透明度调节的全局背景。',
    type: IDEPluginType.APPEARANCE,
    capabilities: [IDEPluginCapability.GLOBAL_BACKGROUND]
  }
}

export class PDFViewerPlugin extends BuiltInPlugin {
  manifest: IDEPluginManifest = {
    id: PDF_VIEWER_PLUGIN_ID,
    name: 'PDF 查看器',
    version: '1.0.0',
    description: '使用内置 PDF.js 显示层进行本地多页 PDF 预览。',
    type: IDEPluginType.FILE_VIEWER,
    capabilities: [IDEPluginCapability.FILE_VIEWER]
  }
}

export class OfficeViewerPlugin extends BuiltInPlugin {
  manifest: IDEPluginManifest = {
    id: OFFICE_VIEWER_PLUGIN_ID,
    name: 'Office 查看器',
    version: '1.0.0',
    description: '本地预览 DOCX、XLSX 和 PPTX，并安全识别旧版 Office 格式。',
    type: IDEPluginType.FILE_VIEWER,
    capabilities: [IDEPluginCapability.FILE_VIEWER]
  }
}

export class CSVViewerPlugin extends BuiltInPlugin {
  manifest: IDEPluginManifest = {
    id: CSV_VIEWER_PLUGIN_ID,
    name: 'CSV 查看器',
    version: '1.0.0',
    description: '支持引号字段的本地表格预览，并可切换至文本编辑。',
    type: IDEPluginType.FILE_VIEWER,
    capabilities: [IDEPluginCapability.FILE_VIEWER]
  }
}
