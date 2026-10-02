export enum IDEPluginCapability {
  LANGUAGE = 'language',
  DIAGNOSTIC = 'diagnostic',
  RUN = 'run',
  FORMAT = 'format',
  SOURCE_CONTROL = 'sourceControl'
}

export enum IDEPluginType {
  LANGUAGE_DIAGNOSTIC = 'Language / Diagnostic Plugin',
  GENERAL = 'IDE Plugin'
}

export enum IDEPluginCheckerStatus {
  UNKNOWN = 0,
  AVAILABLE = 1,
  UNAVAILABLE = 2
}

export interface IDEPluginManifest {
  id: string
  name: string
  version: string
  description: string
  type: IDEPluginType
  capabilities: IDEPluginCapability[]
}

export interface IDEPluginContext {
  getActiveFilePath(): string
}

/** Lightweight lifecycle contract; plugins run inside the IDE layer only. */
export interface IDEPlugin {
  manifest: IDEPluginManifest
  checkerStatus: IDEPluginCheckerStatus
  checkerMessage: string
  activate(context: IDEPluginContext): void
  deactivate(): void
}

export interface IDEPluginState {
  manifest: IDEPluginManifest
  enabled: boolean
  checkerStatus: IDEPluginCheckerStatus
  checkerMessage: string
}
