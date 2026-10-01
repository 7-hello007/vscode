export enum IDEPluginCapability {
  LANGUAGE = 'language',
  RUN = 'run',
  FORMAT = 'format',
  SOURCE_CONTROL = 'sourceControl'
}

export interface IDEPluginManifest {
  id: string
  name: string
  version: string
  description: string
  capabilities: IDEPluginCapability[]
}

export interface IDEPluginContext {
  getActiveFilePath(): string
}

/** Lightweight lifecycle contract; plugins run inside the IDE layer only. */
export interface IDEPlugin {
  manifest: IDEPluginManifest
  activate(context: IDEPluginContext): void
  deactivate(): void
}

export interface IDEPluginState {
  manifest: IDEPluginManifest
  enabled: boolean
}
