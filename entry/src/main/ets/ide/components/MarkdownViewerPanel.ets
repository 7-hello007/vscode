import { common } from '@kit.AbilityKit'
import {
  IDE_BORDER_SUBTLE_COLOR,
  IDE_SURFACE_INPUT_COLOR,
  IDE_SURFACE_MESSAGE_COLOR,
  IDE_SURFACE_SELECTED_COLOR
} from '../theme/IDEBackgroundSurfaces'

enum MarkdownBlockType {
  PARAGRAPH = 0,
  HEADING = 1,
  LIST = 2,
  QUOTE = 3,
  CODE = 4,
  TABLE = 5,
  IMAGE = 6,
  SPACER = 7
}

enum MarkdownInlineType {
  TEXT = 0,
  BOLD = 1,
  ITALIC = 2,
  CODE = 3,
  LINK = 4
}

class MarkdownInline {
  id: string
  text: string
  type: MarkdownInlineType
  url: string

  constructor(id: string, text: string, type: MarkdownInlineType, url: string = '') {
    this.id = id
    this.text = text
    this.type = type
    this.url = url
  }
}

class MarkdownBlock {
  id: string
  type: MarkdownBlockType
  level: number = 0
  text: string = ''
  tokens: MarkdownInline[] = []
  rows: string[][] = []
  imageUrl: string = ''
  imageAlt: string = ''

  constructor(id: string, type: MarkdownBlockType) {
    this.id = id
    this.type = type
  }
}

@Component
export default struct MarkdownViewerPanel {
  @Watch('onContentChanged') @Prop content: string = ''
  @Prop path: string = ''
  @State blocks: MarkdownBlock[] = []

  aboutToAppear(): void {
    this.blocks = this.parse(this.content)
  }

  private onContentChanged(): void {
    this.blocks = this.parse(this.content)
  }

  private parse(content: string): MarkdownBlock[] {
    const result: MarkdownBlock[] = []
    const lines = content.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n')
    let index = 0
    let blockSequence = 0
    while (index < lines.length) {
      const line = lines[index]
      if (line.trim().startsWith('```')) {
        const codeLines: string[] = []
        index++
        while (index < lines.length && !lines[index].trim().startsWith('```')) {
          codeLines.push(lines[index])
          index++
        }
        if (index < lines.length) index++
        const code = new MarkdownBlock('md-' + blockSequence++, MarkdownBlockType.CODE)
        code.text = codeLines.join('\n')
        result.push(code)
        continue
      }
      const image = line.trim().match(/^!\[([^\]]*)\]\(([^)]+)\)$/)
      if (image) {
        const block = new MarkdownBlock('md-' + blockSequence++, MarkdownBlockType.IMAGE)
        block.imageAlt = image[1]
        block.imageUrl = image[2]
        result.push(block)
        index++
        continue
      }
      if (line.indexOf('|') !== -1 && index + 1 < lines.length && this.isTableSeparator(lines[index + 1])) {
        const table = new MarkdownBlock('md-' + blockSequence++, MarkdownBlockType.TABLE)
        table.rows.push(this.tableCells(line))
        index += 2
        while (index < lines.length && lines[index].indexOf('|') !== -1 && lines[index].trim()) {
          table.rows.push(this.tableCells(lines[index]))
          index++
        }
        result.push(table)
        continue
      }
      if (!line.trim()) {
        result.push(new MarkdownBlock('md-' + blockSequence++, MarkdownBlockType.SPACER))
        index++
        continue
      }
      const heading = line.match(/^(#{1,6})\s+(.+)$/)
      if (heading) {
        const block = new MarkdownBlock('md-' + blockSequence++, MarkdownBlockType.HEADING)
        block.level = heading[1].length
        block.text = heading[2]
        block.tokens = this.inlineTokens(block.text, block.id)
        result.push(block)
        index++
        continue
      }
      const list = line.match(/^\s*(?:[-+*]|\d+\.)\s+(.+)$/)
      if (list) {
        const block = new MarkdownBlock('md-' + blockSequence++, MarkdownBlockType.LIST)
        block.text = list[1]
        block.tokens = this.inlineTokens(block.text, block.id)
        result.push(block)
        index++
        continue
      }
      if (line.trim().startsWith('>')) {
        const block = new MarkdownBlock('md-' + blockSequence++, MarkdownBlockType.QUOTE)
        block.text = line.trim().substring(1).trim()
        block.tokens = this.inlineTokens(block.text, block.id)
        result.push(block)
        index++
        continue
      }
      const paragraph = new MarkdownBlock('md-' + blockSequence++, MarkdownBlockType.PARAGRAPH)
      paragraph.text = line
      paragraph.tokens = this.inlineTokens(line, paragraph.id)
      result.push(paragraph)
      index++
    }
    return result
  }

  private inlineTokens(value: string, prefix: string): MarkdownInline[] {
    const result: MarkdownInline[] = []
    let plain = ''
    let index = 0
    let tokenIndex = 0
    const flush = (): void => {
      if (!plain) return
      result.push(new MarkdownInline(prefix + '-inline-' + tokenIndex++, plain, MarkdownInlineType.TEXT))
      plain = ''
    }
    while (index < value.length) {
      if (value.startsWith('**', index)) {
        const end = value.indexOf('**', index + 2)
        if (end > index + 2) {
          flush()
          result.push(new MarkdownInline(prefix + '-inline-' + tokenIndex++, value.substring(index + 2, end),
            MarkdownInlineType.BOLD))
          index = end + 2
          continue
        }
      }
      if (value[index] === '*' || value[index] === '_') {
        const marker = value[index]
        const end = value.indexOf(marker, index + 1)
        if (end > index + 1) {
          flush()
          result.push(new MarkdownInline(prefix + '-inline-' + tokenIndex++, value.substring(index + 1, end),
            MarkdownInlineType.ITALIC))
          index = end + 1
          continue
        }
      }
      if (value[index] === '`') {
        const end = value.indexOf('`', index + 1)
        if (end > index + 1) {
          flush()
          result.push(new MarkdownInline(prefix + '-inline-' + tokenIndex++, value.substring(index + 1, end),
            MarkdownInlineType.CODE))
          index = end + 1
          continue
        }
      }
      if (value[index] === '[') {
        const labelEnd = value.indexOf('](', index + 1)
        const urlEnd = labelEnd === -1 ? -1 : value.indexOf(')', labelEnd + 2)
        if (labelEnd > index + 1 && urlEnd > labelEnd + 2) {
          flush()
          result.push(new MarkdownInline(prefix + '-inline-' + tokenIndex++,
            value.substring(index + 1, labelEnd), MarkdownInlineType.LINK,
            value.substring(labelEnd + 2, urlEnd)))
          index = urlEnd + 1
          continue
        }
      }
      plain += value[index]
      index++
    }
    flush()
    return result
  }

  private isTableSeparator(value: string): boolean {
    const cells = this.tableCells(value)
    if (cells.length === 0) return false
    for (const cell of cells) {
      if (!/^:?-{3,}:?$/.test(cell.replace(/\s/g, ''))) return false
    }
    return true
  }

  private tableCells(value: string): string[] {
    let normalized = value.trim()
    if (normalized.startsWith('|')) normalized = normalized.substring(1)
    if (normalized.endsWith('|')) normalized = normalized.substring(0, normalized.length - 1)
    return normalized.split('|').map((cell: string): string => cell.trim())
  }

  private openLink(url: string): void {
    if (!url.startsWith('https://') && !url.startsWith('http://')) return
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext
    void context.startAbility({
      action: 'ohos.want.action.viewData',
      uri: url
    })
  }

  @Builder
  private inlineText(tokens: MarkdownInline[], size: number = 13, weight: FontWeight = FontWeight.Normal) {
    Text() {
      ForEach(tokens, (token: MarkdownInline) => {
        Span(token.text)
          .fontWeight(token.type === MarkdownInlineType.BOLD ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(token.type === MarkdownInlineType.ITALIC ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(token.type === MarkdownInlineType.CODE ? 'monospace' : '')
          .fontColor(token.type === MarkdownInlineType.LINK ? '#7EA6D8' :
            (token.type === MarkdownInlineType.CODE ? '#D6B982' : '#D7DBE2'))
          .decoration({ type: token.type === MarkdownInlineType.LINK ?
            TextDecorationType.Underline : TextDecorationType.None })
          .onClick(() => {
            if (token.type === MarkdownInlineType.LINK) this.openLink(token.url)
          })
      }, (token: MarkdownInline): string => token.id)
    }
    .fontSize(size)
    .fontWeight(weight)
    .lineHeight(20)
    .width('100%')
  }

  @Builder
  private renderBlock(block: MarkdownBlock) {
    if (block.type === MarkdownBlockType.HEADING) {
      Column() {
        this.inlineText(block.tokens, Math.max(15, 24 - block.level * 2), FontWeight.Bold)
      }
        .width('100%')
        .margin({ top: block.level <= 2 ? 12 : 6, bottom: 4 })
    } else if (block.type === MarkdownBlockType.LIST) {
      Row({ space: 8 }) {
        Text('•').fontColor('#8EA4C4').fontSize(14)
        Column() {
          this.inlineText(block.tokens)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 4 })
    } else if (block.type === MarkdownBlockType.QUOTE) {
      Row({ space: 10 }) {
        Divider().vertical(true).width(2).height('100%').color('#687384')
        Column() {
          this.inlineText(block.tokens)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 6, bottom: 6, right: 6 })
      .backgroundColor(IDE_SURFACE_MESSAGE_COLOR)
    } else if (block.type === MarkdownBlockType.CODE) {
      Text(block.text)
        .width('100%')
        .fontSize(12)
        .lineHeight(18)
        .fontFamily('monospace')
        .fontColor('#D6D9DF')
        .padding(10)
        .backgroundColor(IDE_SURFACE_INPUT_COLOR)
        .border({ width: 1, color: IDE_BORDER_SUBTLE_COLOR })
    } else if (block.type === MarkdownBlockType.TABLE) {
      Column() {
        ForEach(block.rows, (row: string[], rowIndex: number) => {
          Row() {
            ForEach(row, (cell: string, cellIndex: number) => {
              Text(cell)
                .fontSize(11)
                .fontColor(rowIndex === 0 ? '#E0E4EA' : '#B8C0CB')
                .fontWeight(rowIndex === 0 ? FontWeight.Bold : FontWeight.Normal)
                .padding(6)
                .layoutWeight(1)
                .border({ width: 0.5, color: IDE_BORDER_SUBTLE_COLOR })
            }, (cell: string, cellIndex: number): string => block.id + '-cell-' + rowIndex + '-' + cellIndex)
          }
          .width('100%')
          .backgroundColor(rowIndex === 0 ? IDE_SURFACE_SELECTED_COLOR : IDE_SURFACE_MESSAGE_COLOR)
        }, (row: string[], rowIndex: number): string => block.id + '-row-' + rowIndex)
      }
      .width('100%')
    } else if (block.type === MarkdownBlockType.IMAGE) {
      Column({ space: 6 }) {
        if (block.imageUrl.startsWith('https://') || block.imageUrl.startsWith('http://') ||
          block.imageUrl.startsWith('file://')) {
          Image(block.imageUrl)
            .width('100%')
            .height(220)
            .objectFit(ImageFit.Contain)
        }
        Text(block.imageAlt || block.imageUrl)
          .fontSize(10)
          .fontColor('#87909D')
      }
      .width('100%')
      .padding(8)
      .backgroundColor(IDE_SURFACE_MESSAGE_COLOR)
      .border({ width: 1, color: IDE_BORDER_SUBTLE_COLOR })
    } else if (block.type === MarkdownBlockType.SPACER) {
      Row().height(8)
    } else {
      this.inlineText(block.tokens)
    }
  }

  build() {
    Column() {
      List({ space: 6 }) {
        ForEach(this.blocks, (block: MarkdownBlock) => {
          ListItem() {
            this.renderBlock(block)
          }
        }, (block: MarkdownBlock): string => block.id)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 18, right: 18, top: 10, bottom: 18 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}

