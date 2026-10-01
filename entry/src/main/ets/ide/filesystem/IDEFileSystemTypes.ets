export enum IDEFileType {
  FILE = 0,
  DIRECTORY = 1,
  SYMBOLIC_LINK = 2,
  OTHER = 3
}

export interface IDEFileEntry {
  name: string
  path: string
  type: IDEFileType
  size: number
}

export class IDEFileSystemError extends Error {
  readonly operation: string
  readonly status: number

  constructor(operation: string, message: string, status: number = -1) {
    super(message)
    this.name = 'IDEFileSystemError'
    this.operation = operation
    this.status = status
  }
}
