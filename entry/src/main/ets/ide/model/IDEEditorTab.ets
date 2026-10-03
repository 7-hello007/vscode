export enum IDEEditorViewerType {
  TEXT = 'text',
  BINARY = 'binary',
  MARKDOWN = 'markdown',
  PDF = 'pdf',
  DOCUMENT = 'document',
  SPREADSHEET = 'spreadsheet',
  CSV = 'csv',
  PRESENTATION = 'presentation'
}

export class IDEEditorTab {
  path: string
  name: string
  content: string
  dirty: boolean
  viewerType: IDEEditorViewerType
  closable: boolean
  detectedType: string

  constructor(path: string, content?: string | null, dirty: boolean = false,
    viewerType: IDEEditorViewerType = IDEEditorViewerType.TEXT, closable: boolean = true,
    detectedType: string = 'Text') {
    this.path = path || ''
    this.name = this.path.substring(this.path.lastIndexOf('/') + 1)
    this.content = content || ''
    this.dirty = dirty
    this.viewerType = viewerType
    this.closable = closable
    this.detectedType = detectedType
  }
}
