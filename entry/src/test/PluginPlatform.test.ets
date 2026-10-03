import { describe, expect, it } from '@ohos/hypium'
import FileViewerRegistry, {
  IDEFileViewerKind,
  IDEFileViewerOptions
} from '../main/ets/ide/plugin/FileViewerRegistry'
import { formatBinaryDisplayLines } from '../main/ets/ide/components/BinaryViewerPanel'
import BinaryEditSessionStore from '../main/ets/ide/model/BinaryEditSessionStore'

export default function pluginPlatformTest() {
  describe('pluginPlatform', () => {
    const registry = new FileViewerRegistry()
    const allEnabled = new IDEFileViewerOptions()
    allEnabled.markdownEnabled = true
    allEnabled.pdfEnabled = true
    allEnabled.officeEnabled = true
    allEnabled.csvEnabled = true

    it('detectsSupportedBinaryMagic', 0, () => {
      expect(registry.resolve('/bin/app', new Uint8Array([0x7f, 0x45, 0x4c, 0x46]), allEnabled).detectedType)
        .assertEqual('ELF')
      expect(registry.resolve('/tmp/a.zip', new Uint8Array([0x50, 0x4b, 0x03, 0x04]), allEnabled).detectedType)
        .assertEqual('ZIP')
      expect(registry.resolve('/tmp/a.png',
        new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), allEnabled).detectedType)
        .assertEqual('PNG')
    })

    it('routesNulAndHighBytesToBinary', 0, () => {
      const sample = new Uint8Array([0x00, 0x7f, 0x80, 0xff])
      expect(registry.resolve('/tmp/data.txt', sample, allEnabled).kind).assertEqual(IDEFileViewerKind.BINARY)
    })

    it('routesMarkdownOnlyWhenEnabled', 0, () => {
      const sample = new Uint8Array([0x23, 0x20, 0x48, 0x69])
      expect(registry.resolve('/home/readme.md', sample, allEnabled).kind).assertEqual(IDEFileViewerKind.MARKDOWN)
      const disabled = new IDEFileViewerOptions()
      expect(registry.resolve('/home/readme.md', sample, disabled).kind).assertEqual(IDEFileViewerKind.TEXT)
    })

    it('magicOverridesTextExtension', 0, () => {
      const pdf = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d])
      expect(registry.resolve('/home/readme.md', pdf, allEnabled).kind).assertEqual(IDEFileViewerKind.BINARY)
    })

    it('routesDocumentPluginsOnlyWhenEnabled', 0, () => {
      const zip = new Uint8Array([0x50, 0x4b, 0x03, 0x04])
      const ole = new Uint8Array([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])
      const pdf = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d])
      expect(registry.resolve('/home/report.pdf', pdf, allEnabled).kind).assertEqual(IDEFileViewerKind.PDF)
      expect(registry.resolve('/home/report.docx', zip, allEnabled).kind).assertEqual(IDEFileViewerKind.DOCUMENT)
      expect(registry.resolve('/home/data.xlsx', zip, allEnabled).kind).assertEqual(IDEFileViewerKind.SPREADSHEET)
      expect(registry.resolve('/home/slides.pptx', zip, allEnabled).kind).assertEqual(IDEFileViewerKind.PRESENTATION)
      expect(registry.resolve('/home/legacy.doc', ole, allEnabled).detectedType).assertEqual('DOC')
      expect(registry.resolve('/home/table.csv', new Uint8Array([0x61, 0x2c, 0x62]), allEnabled).kind)
        .assertEqual(IDEFileViewerKind.CSV)
      const disabled = new IDEFileViewerOptions()
      expect(registry.resolve('/home/report.pdf', pdf, disabled).kind).assertEqual(IDEFileViewerKind.BINARY)
      expect(registry.resolve('/home/report.docx', zip, disabled).kind).assertEqual(IDEFileViewerKind.BINARY)
    })

    it('formatsAllByteRangesWithoutUtf8Conversion', 0, () => {
      const lines = formatBinaryDisplayLines([0x00, 0x7f, 0x80, 0xff, 0x41], 0)
      expect(lines.length).assertEqual(1)
      expect(lines[0].cells[0].hex).assertEqual('00')
      expect(lines[0].cells[1].hex).assertEqual('7F')
      expect(lines[0].cells[2].hex).assertEqual('80')
      expect(lines[0].cells[3].hex).assertEqual('FF')
      expect(lines[0].ascii).assertEqual('....A')
    })

    it('buildsBinarySafePatches', 0, () => {
      const edits = new BinaryEditSessionStore()
      edits.setByte('/tmp/data.bin', 0, 0x00)
      edits.setByte('/tmp/data.bin', 1, 0x7f)
      edits.setByte('/tmp/data.bin', 2, 0x80)
      edits.setByte('/tmp/data.bin', 3, 0xff)
      const patches = edits.buildPatches('/tmp/data.bin')
      expect(patches.length).assertEqual(1)
      expect(patches[0].bytes[0]).assertEqual(0x00)
      expect(patches[0].bytes[1]).assertEqual(0x7f)
      expect(patches[0].bytes[2]).assertEqual(0x80)
      expect(patches[0].bytes[3]).assertEqual(0xff)
    })
  })
}
