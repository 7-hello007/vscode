export class DocumentParagraph {
  id: string
  text: string
  headingLevel: number
  bold: boolean
  italic: boolean
  list: boolean

  constructor(id: string, text: string, headingLevel: number = 0,
    bold: boolean = false, italic: boolean = false, list: boolean = false) {
    this.id = id
    this.text = text
    this.headingLevel = headingLevel
    this.bold = bold
    this.italic = italic
    this.list = list
  }
}

export class DocumentTable {
  id: string
  rows: string[][]
  constructor(id: string, rows: string[][]) { this.id = id; this.rows = rows }
}

export class SpreadsheetSheet {
  id: string
  name: string
  rows: string[][]
  truncated: boolean
  constructor(id: string, name: string, rows: string[][], truncated: boolean = false) {
    this.id = id; this.name = name; this.rows = rows; this.truncated = truncated
  }
}

export class PresentationSlide {
  id: string
  number: number
  texts: string[]
  imageUris: string[]
  constructor(id: string, number: number, texts: string[], imageUris: string[]) {
    this.id = id; this.number = number; this.texts = texts; this.imageUris = imageUris
  }
}

export class CsvPage {
  rows: string[][]
  delimiter: string
  truncated: boolean
  constructor(rows: string[][], delimiter: string, truncated: boolean) {
    this.rows = rows; this.delimiter = delimiter; this.truncated = truncated
  }
}
