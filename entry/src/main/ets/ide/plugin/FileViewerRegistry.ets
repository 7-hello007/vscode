export enum IDEFileViewerKind {
  TEXT = 0,
  MARKDOWN = 1,
  BINARY = 2,
  PDF = 3,
  DOCUMENT = 4,
  SPREADSHEET = 5,
  CSV = 6,
  PRESENTATION = 7
}

export class IDEFileViewerOptions {
  markdownEnabled: boolean = false
  pdfEnabled: boolean = false
  officeEnabled: boolean = false
  csvEnabled: boolean = false
}

export class IDEFileViewerResolution {
  kind: IDEFileViewerKind
  detectedType: string

  constructor(kind: IDEFileViewerKind, detectedType: string = 'text') {
    this.kind = kind
    this.detectedType = detectedType
  }
}

/** Routes by strong magic/content evidence first and extension second. */
export default class FileViewerRegistry {
  resolve(path: string, sample: Uint8Array, options: IDEFileViewerOptions): IDEFileViewerResolution {
    const extension = this.extensionOf(path)
    const magic = this.detectMagic(sample)
    if (options.pdfEnabled && extension === 'pdf' && magic === 'PDF') {
      return new IDEFileViewerResolution(IDEFileViewerKind.PDF, 'PDF')
    }
    if (options.officeEnabled && magic === 'ZIP') {
      if (extension === 'docx') return new IDEFileViewerResolution(IDEFileViewerKind.DOCUMENT, 'DOCX')
      if (extension === 'xlsx') return new IDEFileViewerResolution(IDEFileViewerKind.SPREADSHEET, 'XLSX')
      if (extension === 'pptx') return new IDEFileViewerResolution(IDEFileViewerKind.PRESENTATION, 'PPTX')
    }
    if (options.officeEnabled && magic === 'OLE Compound Document') {
      if (extension === 'doc') return new IDEFileViewerResolution(IDEFileViewerKind.DOCUMENT, 'DOC')
      if (extension === 'xls') return new IDEFileViewerResolution(IDEFileViewerKind.SPREADSHEET, 'XLS')
      if (extension === 'ppt') return new IDEFileViewerResolution(IDEFileViewerKind.PRESENTATION, 'PPT')
    }
    if (magic) return new IDEFileViewerResolution(IDEFileViewerKind.BINARY, magic)
    if (!this.isLikelyText(sample)) return new IDEFileViewerResolution(IDEFileViewerKind.BINARY, 'Binary')
    if (options.csvEnabled && extension === 'csv') {
      return new IDEFileViewerResolution(IDEFileViewerKind.CSV, 'CSV')
    }
    if (options.markdownEnabled && (extension === 'md' || extension === 'markdown')) {
      return new IDEFileViewerResolution(IDEFileViewerKind.MARKDOWN, 'Markdown')
    }
    return new IDEFileViewerResolution(IDEFileViewerKind.TEXT, 'Text')
  }

  detectMagic(bytes: Uint8Array): string {
    if (this.matches(bytes, [0x7f, 0x45, 0x4c, 0x46])) return 'ELF'
    if (this.matches(bytes, [0x50, 0x4b, 0x03, 0x04]) || this.matches(bytes, [0x50, 0x4b, 0x05, 0x06]) ||
      this.matches(bytes, [0x50, 0x4b, 0x07, 0x08])) return 'ZIP'
    if (this.matches(bytes, [0x25, 0x50, 0x44, 0x46, 0x2d])) return 'PDF'
    if (this.matches(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return 'PNG'
    if (this.matches(bytes, [0xff, 0xd8, 0xff])) return 'JPEG'
    if (this.matches(bytes, [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) ||
      this.matches(bytes, [0x47, 0x49, 0x46, 0x38, 0x39, 0x61])) return 'GIF'
    if (this.matches(bytes, [0x1f, 0x8b])) return 'GZIP'
    if (this.matches(bytes, [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])) return 'OLE Compound Document'
    return ''
  }

  isLikelyText(bytes: Uint8Array): boolean {
    if (bytes.length === 0) return true
    let controls = 0
    for (let index = 0; index < bytes.length; index++) {
      const value = bytes[index]
      if (value === 0) return false
      if (value < 0x09 || (value > 0x0d && value < 0x20) || value === 0x7f) controls++
    }
    return controls * 20 <= bytes.length
  }

  private matches(bytes: Uint8Array, signature: number[]): boolean {
    if (bytes.length < signature.length) return false
    for (let index = 0; index < signature.length; index++) {
      if (bytes[index] !== signature[index]) return false
    }
    return true
  }

  private extensionOf(path: string): string {
    const dot = path.lastIndexOf('.')
    const slash = path.lastIndexOf('/')
    return dot > slash ? path.substring(dot + 1).toLowerCase() : ''
  }
}
