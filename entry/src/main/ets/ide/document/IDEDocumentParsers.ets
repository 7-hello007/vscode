import {
  CsvPage,
  DocumentParagraph,
  DocumentTable,
  PresentationSlide,
  SpreadsheetSheet
} from './IDEDocumentModels'
import IDEDocumentRuntime, { IDEPreparedDocument } from './IDEDocumentRuntime'

const MAX_TABLE_ROWS = 2000
const MAX_TABLE_COLUMNS = 100

export class ParsedDocx {
  paragraphs: DocumentParagraph[] = []
  tables: DocumentTable[] = []
  imageUris: string[] = []
}

export class OOXMLParser {
  private runtime: IDEDocumentRuntime
  constructor(runtime: IDEDocumentRuntime) { this.runtime = runtime }

  parseDocx(document: IDEPreparedDocument): ParsedDocx {
    const result = new ParsedDocx()
    const xml = this.runtime.readXml(document, 'word/document.xml')
    if (!xml) throw new Error('DOCX document.xml is missing')
    const tableMatches = xml.match(/<w:tbl[\s\S]*?<\/w:tbl>/g) || []
    for (let index = 0; index < tableMatches.length; index++) {
      const rows: string[][] = []
      const rowMatches = tableMatches[index].match(/<w:tr[\s\S]*?<\/w:tr>/g) || []
      for (const rowXml of rowMatches) {
        const cells: string[] = []
        const cellMatches = rowXml.match(/<w:tc[\s\S]*?<\/w:tc>/g) || []
        for (const cellXml of cellMatches) cells.push(this.textNodes(cellXml).join(''))
        rows.push(cells)
      }
      result.tables.push(new DocumentTable('docx-table-' + index, rows))
    }
    const withoutTables = xml.replace(/<w:tbl[\s\S]*?<\/w:tbl>/g, '')
    const paragraphs = withoutTables.match(/<w:p(?:\s[^>]*)?>[\s\S]*?<\/w:p>/g) || []
    for (let index = 0; index < paragraphs.length; index++) {
      const paragraph = paragraphs[index]
      const text = this.textNodes(paragraph).join('')
      if (!text.trim()) continue
      const style = this.attributeValue(paragraph, 'w:pStyle', 'w:val')
      let heading = 0
      const headingMatch = style.match(/heading\s*([1-6])/i)
      if (headingMatch) heading = parseInt(headingMatch[1])
      result.paragraphs.push(new DocumentParagraph('docx-paragraph-' + index, text, heading,
        /<w:b(?:\s|\/|>)/.test(paragraph), /<w:i(?:\s|\/|>)/.test(paragraph),
        /<w:numPr(?:\s|>)/.test(paragraph)))
    }
    for (const file of this.runtime.listFiles(document, 'word/media')) {
      const uri = this.runtime.assetUri(document, 'word/media/' + file)
      if (uri) result.imageUris.push(uri)
    }
    return result
  }

  parseXlsx(document: IDEPreparedDocument): SpreadsheetSheet[] {
    const sharedStrings = this.parseSharedStrings(this.runtime.readXml(document, 'xl/sharedStrings.xml'))
    const workbook = this.runtime.readXml(document, 'xl/workbook.xml')
    if (!workbook) throw new Error('XLSX workbook.xml is missing')
    const relationships = this.relationships(this.runtime.readXml(document, 'xl/_rels/workbook.xml.rels'))
    const sheets: SpreadsheetSheet[] = []
    const matches = workbook.match(/<sheet\b[^>]*\/?\s*>/g) || []
    for (let index = 0; index < matches.length; index++) {
      const name = this.decodeXml(this.rawAttribute(matches[index], 'name')) || 'Sheet ' + (index + 1)
      const relationId = this.rawAttribute(matches[index], 'r:id')
      let target = relationships.get(relationId) || ('worksheets/sheet' + (index + 1) + '.xml')
      target = target.replace(/^\/+/, '').replace(/^xl\//, '')
      const xml = this.runtime.readXml(document, 'xl/' + target)
      const parsed = this.parseSheet(xml, sharedStrings)
      sheets.push(new SpreadsheetSheet('xlsx-sheet-' + index, name, parsed.rows, parsed.truncated))
    }
    return sheets
  }

  parsePptx(document: IDEPreparedDocument): PresentationSlide[] {
    const names = this.runtime.listFiles(document, 'ppt/slides')
      .filter((name: string): boolean => /^slide\d+\.xml$/.test(name))
      .sort((left: string, right: string): number => this.slideNumber(left) - this.slideNumber(right))
    if (names.length === 0) throw new Error('PPTX contains no slides')
    const slides: PresentationSlide[] = []
    for (let index = 0; index < names.length; index++) {
      const xml = this.runtime.readXml(document, 'ppt/slides/' + names[index])
      const texts = this.namedTextNodes(xml, 'a:t')
      const imageUris: string[] = []
      const slideBase = names[index].substring(0, names[index].length - 4)
      const relationXml = this.runtime.readXml(document, 'ppt/slides/_rels/' + slideBase + '.xml.rels')
      const relationships = this.relationships(relationXml)
      const relationIds = this.imageRelationIds(xml)
      for (const relationId of relationIds) {
        const target = relationships.get(relationId) || ''
        if (!target || target.indexOf('..') === -1) continue
        const relative = target.replace(/^\.\.\//, '')
        const uri = this.runtime.assetUri(document, 'ppt/' + relative)
        if (uri && imageUris.indexOf(uri) === -1 && imageUris.length < 8) imageUris.push(uri)
      }
      slides.push(new PresentationSlide('pptx-slide-' + index, index + 1, texts, imageUris))
    }
    return slides
  }

  parseCsv(content: string): CsvPage {
    const normalized = content.replace(/\r\n/g, '\n').replace(/\r/g, '\n')
    const firstLineEnd = normalized.indexOf('\n')
    const firstLine = firstLineEnd === -1 ? normalized : normalized.substring(0, firstLineEnd)
    const candidates = [',', '\t', ';', '|']
    let delimiter = ','
    let best = -1
    for (const candidate of candidates) {
      const score = this.delimiterCount(firstLine, candidate)
      if (score > best) { best = score; delimiter = candidate }
    }
    const rows: string[][] = []
    let row: string[] = []
    let field = ''
    let quoted = false
    let truncated = false
    for (let index = 0; index < normalized.length; index++) {
      const character = normalized[index]
      if (character === '"') {
        if (quoted && index + 1 < normalized.length && normalized[index + 1] === '"') {
          field += '"'; index++
        } else {
          quoted = !quoted
        }
      } else if (character === delimiter && !quoted) {
        if (row.length < MAX_TABLE_COLUMNS) row.push(field)
        field = ''
      } else if (character === '\n' && !quoted) {
        if (row.length < MAX_TABLE_COLUMNS) row.push(field)
        rows.push(row)
        row = []; field = ''
        if (rows.length >= MAX_TABLE_ROWS) { truncated = index + 1 < normalized.length; break }
      } else {
        field += character
      }
    }
    if (!truncated && (field.length > 0 || row.length > 0)) { row.push(field); rows.push(row) }
    return new CsvPage(rows, delimiter, truncated)
  }

  private parseSharedStrings(xml: string): string[] {
    if (!xml) return []
    const values: string[] = []
    const items = xml.match(/<si(?:\s[^>]*)?>[\s\S]*?<\/si>/g) || []
    for (const item of items) values.push(this.textNodes(item).join(''))
    return values
  }

  private parseSheet(xml: string, sharedStrings: string[]): SpreadsheetSheet {
    const rows: string[][] = []
    let truncated = false
    const rowMatches = xml.match(/<row(?:\s[^>]*)?>[\s\S]*?<\/row>/g) || []
    for (let rowIndex = 0; rowIndex < rowMatches.length; rowIndex++) {
      if (rows.length >= MAX_TABLE_ROWS) { truncated = true; break }
      const values: string[] = []
      const cells = rowMatches[rowIndex].match(/<c(?:\s[^>]*)?>[\s\S]*?<\/c>/g) || []
      for (const cell of cells) {
        const reference = this.rawAttribute(cell.substring(0, cell.indexOf('>') + 1), 'r')
        const column = Math.min(MAX_TABLE_COLUMNS - 1, this.columnIndex(reference))
        while (values.length < column) values.push('')
        const type = this.rawAttribute(cell.substring(0, cell.indexOf('>') + 1), 't')
        const raw = this.firstTagText(cell, type === 'inlineStr' ? 't' : 'v')
        const sharedIndex = parseInt(raw)
        const value = type === 's' && Number.isFinite(sharedIndex) ? (sharedStrings[sharedIndex] || '') : raw
        if (values.length < MAX_TABLE_COLUMNS) values.push(this.decodeXml(value))
      }
      rows.push(values)
    }
    return new SpreadsheetSheet('parsed', '', rows, truncated)
  }

  private relationships(xml: string): Map<string, string> {
    const result = new Map<string, string>()
    const matches = xml.match(/<Relationship\b[^>]*\/?\s*>/g) || []
    for (const match of matches) result.set(this.rawAttribute(match, 'Id'), this.rawAttribute(match, 'Target'))
    return result
  }

  private imageRelationIds(xml: string): string[] {
    const result: string[] = []
    const matches = xml.match(/<a:blip\b[^>]*r:embed="[^"]+"[^>]*\/?\s*>/g) || []
    for (const match of matches) {
      const relationId = this.rawAttribute(match, 'r:embed')
      if (relationId && result.indexOf(relationId) === -1) result.push(relationId)
    }
    return result
  }

  private textNodes(xml: string): string[] { return this.namedTextNodes(xml, 'w:t') }

  private namedTextNodes(xml: string, name: string): string[] {
    const result: string[] = []
    const expression = new RegExp('<' + name + '(?:\\s[^>]*)?>([\\s\\S]*?)<\\/' + name + '>', 'g')
    let match: RegExpExecArray | null = expression.exec(xml)
    while (match) { result.push(this.decodeXml(match[1])); match = expression.exec(xml) }
    return result
  }

  private firstTagText(xml: string, name: string): string {
    const expression = new RegExp('<' + name + '(?:\\s[^>]*)?>([\\s\\S]*?)<\\/' + name + '>')
    const match = expression.exec(xml)
    return match ? match[1] : ''
  }

  private attributeValue(xml: string, tag: string, attribute: string): string {
    const expression = new RegExp('<' + tag + '\\b[^>]*' + attribute + '="([^"]*)"[^>]*\/?>')
    const match = expression.exec(xml)
    return match ? this.decodeXml(match[1]) : ''
  }

  private rawAttribute(tag: string, attribute: string): string {
    const expression = new RegExp('(?:^|\\s)' + attribute.replace(':', '\\:') + '="([^"]*)"')
    const match = expression.exec(tag)
    return match ? match[1] : ''
  }

  private decodeXml(value: string): string {
    return value.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'").replace(/&amp;/g, '&')
  }

  private columnIndex(reference: string): number {
    let result = 0
    for (let index = 0; index < reference.length; index++) {
      const code = reference.charCodeAt(index)
      if (code < 65 || code > 90) break
      result = result * 26 + code - 64
    }
    return Math.max(0, result - 1)
  }

  private slideNumber(name: string): number {
    const match = /slide(\d+)\.xml/.exec(name)
    return match ? parseInt(match[1]) : 0
  }

  private delimiterCount(line: string, delimiter: string): number {
    let count = 0; let quoted = false
    for (let index = 0; index < line.length; index++) {
      if (line[index] === '"') quoted = !quoted
      else if (line[index] === delimiter && !quoted) count++
    }
    return count
  }
}
