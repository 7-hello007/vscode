export class IDEEditorTab {
  path: string
  name: string
  content: string
  dirty: boolean

  constructor(path: string, content?: string | null, dirty: boolean = false) {
    this.path = path || ''
    this.name = this.path.substring(this.path.lastIndexOf('/') + 1)
    this.content = content || ''
    this.dirty = dirty
  }
}
