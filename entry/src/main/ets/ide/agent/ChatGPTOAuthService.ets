import { common, Want } from '@kit.AbilityKit'
import { asset } from '@kit.AssetStoreKit'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { http, socket } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { hilog } from '@kit.PerformanceAnalysisKit'
import {
  RefreshTokenChunkStore,
  RefreshTokenIntegrityProvider,
  RefreshTokenSecretBackend
} from './RefreshTokenChunkStore'

const AUTHORIZE_ENDPOINT = 'https://auth.openai.com/api/accounts/authorize'
const TOKEN_ENDPOINT = 'https://auth.openai.com/api/accounts/oauth/token'
const REVOCATION_ENDPOINT = 'https://auth.openai.com/api/accounts/oauth/revoke'
const RESOURCE = 'https://api.openai.com/v1'
const INITIAL_CLIENT_ID = 'dynamic_agent_client'
const SCOPES = 'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct'
const ASSET_ALIAS = 'hish.codex.chatgpt.oauth.v1'
const HOST_ASSET_ALIAS = 'hish.codex.chatgpt.host.v1'
const REGISTRATION_ASSET_ALIAS = 'hish.codex.chatgpt.registration.v1'
const REFRESH_ASSET_PREFIX = 'hish.codex.refresh.'
const REFRESH_METADATA_ALIAS = 'hish.codex.refresh.meta'
const REGISTRATION_HINT_ASSET_PREFIX = 'hish.codex.registration.hint.'
const REGISTRATION_HINT_METADATA_ALIAS = 'hish.codex.registration.hint.meta'
const REFRESH_SKEW_MS = 120000
const DOMAIN = 0x0000

interface OAuthTokenPayload {
  access_token?: string
  refresh_token?: string
  id_token?: string
  expires_in?: number
  client_id?: string
  token_type?: string
  scope?: string
  error?: string
  error_description?: string
}

interface OAuthStoredCredential {
  refreshToken: string
  clientId: string
  accountLabel: string
}

interface OAuthCredentialAssetRecord {
  clientId: string
  accountLabel: string
  refreshToken?: string
}

interface OAuthRegistration {
  clientId: string
  idTokenHint: string
  loginHint: string
}

interface OAuthRegistrationAssetRecord {
  clientId: string
  loginHint: string
  hasIdTokenHint?: boolean
  idTokenHint?: string
}

interface OAuthIdClaims {
  iss?: string
  aud?: string | string[]
  exp?: number
  nonce?: string
  email?: string
  name?: string
  sub?: string
}

interface OAuthCallbackResult {
  code: string
  state: string
  clientId: string
  error: string
}

class AssetStoreRefreshBackend implements RefreshTokenSecretBackend {
  async read(aliasText: string): Promise<Uint8Array | null> {
    const query = this.aliasQuery(aliasText)
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL)
    try {
      const results = await asset.query(query)
      if (results.length !== 1) return null
      const value = results[0].get(asset.Tag.SECRET)
      return value instanceof Uint8Array ? value : null
    } catch (error) {
      return null
    }
  }

  async writeNew(aliasText: string, value: Uint8Array): Promise<void> {
    const attributes: asset.AssetMap = this.aliasQuery(aliasText)
    attributes.set(asset.Tag.SECRET, value)
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED)
    await asset.add(attributes)
  }

  async replace(aliasText: string, value: Uint8Array): Promise<void> {
    const query = this.aliasQuery(aliasText)
    const existing = await this.read(aliasText)
    if (existing) {
      const attributes: asset.AssetMap = new Map<asset.Tag, asset.Value>()
      attributes.set(asset.Tag.SECRET, value)
      await asset.update(query, attributes)
      return
    }
    await this.writeNew(aliasText, value)
  }

  async remove(aliasText: string): Promise<void> {
    try { await asset.remove(this.aliasQuery(aliasText)) } catch (error) { }
  }

  async listAliases(prefix: string): Promise<string[]> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>()
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES)
    query.set(asset.Tag.RETURN_LIMIT, 1000)
    const results = await asset.query(query)
    const aliases: string[] = []
    for (const result of results) {
      const value = result.get(asset.Tag.ALIAS)
      if (!(value instanceof Uint8Array)) continue
      const aliasText = util.TextDecoder.create('utf-8').decodeToString(value)
      if (aliasText.startsWith(prefix)) aliases.push(aliasText)
    }
    return aliases
  }

  private aliasQuery(aliasText: string): asset.AssetMap {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>()
    query.set(asset.Tag.ALIAS, util.TextEncoder.create().encodeInto(aliasText))
    return query
  }
}

class AssetStoreRefreshIntegrity implements RefreshTokenIntegrityProvider {
  async sha256(value: Uint8Array): Promise<string> {
    const digest = cryptoFramework.createMd('SHA256')
    await digest.update({ data: value })
    return new util.Base64Helper().encodeToStringSync((await digest.digest()).data,
      util.Type.BASIC_URL_SAFE).replace(/=+$/g, '')
  }

  newGeneration(): string {
    const random = cryptoFramework.createRandom().generateRandomSync(12).data
    const suffix = new util.Base64Helper().encodeToStringSync(random,
      util.Type.BASIC_URL_SAFE).replace(/=+$/g, '')
    return Date.now().toString(36) + '-' + suffix
  }
}

export enum ChatGPTAuthState {
  SIGNED_OUT = 'SIGNED_OUT',
  SIGNING_IN = 'SIGNING_IN',
  SIGNED_IN = 'SIGNED_IN',
  REFRESHING = 'REFRESHING',
  ERROR = 'ERROR'
}

export class ChatGPTAccessToken {
  value: string
  expiresAt: number

  constructor(value: string, expiresAt: number) {
    this.value = value
    this.expiresAt = expiresAt
  }
}

export type ChatGPTAuthListener = (state: ChatGPTAuthState, message: string) => void

/** OAuth Authorization Code + PKCE controller. Refresh credentials live only
 * in HarmonyOS Asset Store; access tokens are memory-only. */
export default class ChatGPTOAuthService {
  private context: common.UIAbilityContext | null = null
  private state: ChatGPTAuthState = ChatGPTAuthState.SIGNED_OUT
  private message: string = ''
  private accessToken: ChatGPTAccessToken | null = null
  private credential: OAuthStoredCredential | null = null
  private registration: OAuthRegistration | null = null
  private hostId: string = ''
  private listeners: ChatGPTAuthListener[] = []
  private refreshInFlight: Promise<ChatGPTAccessToken> | null = null

  async initialize(context: common.UIAbilityContext): Promise<void> {
    this.context = context
    this.hostId = await this.readStringAsset(HOST_ASSET_ALIAS)
    this.registration = await this.readRegistration()
    this.credential = await this.readCredential()
    this.state = this.credential ? ChatGPTAuthState.SIGNED_IN : ChatGPTAuthState.SIGNED_OUT
    this.notify()
  }

  subscribe(listener: ChatGPTAuthListener): void {
    if (this.listeners.indexOf(listener) === -1) this.listeners.push(listener)
    listener(this.state, this.message)
  }

  unsubscribe(listener: ChatGPTAuthListener): void {
    this.listeners = this.listeners.filter((item: ChatGPTAuthListener): boolean => item !== listener)
  }

  isSignedIn(): boolean {
    return this.credential !== null
  }

  getState(): ChatGPTAuthState {
    return this.state
  }

  async signIn(): Promise<ChatGPTAccessToken> {
    const context = this.requireContext()
    this.state = ChatGPTAuthState.SIGNING_IN
    this.message = ''
    this.notify()
    let server: socket.TCPSocketServer | null = null
    try {
      const verifier = this.randomBase64Url(64)
      const state = this.randomBase64Url(32)
      const nonce = this.randomBase64Url(32)
      const challenge = await this.sha256Base64Url(verifier)
      const hostId = await this.ensureHostId()
      const dynamicRegistration = this.registration === null
      const authorizeClientId = dynamicRegistration ? INITIAL_CLIENT_ID : this.registration!.clientId
      server = socket.constructTCPSocketServerInstance()
      const callbackPromise = this.waitForCallback(server)
      await server.listen({ address: '127.0.0.1', port: 0, family: 1 })
      const address = await server.getLocalAddress()
      const redirectUri = 'http://127.0.0.1:' + address.port + '/auth/callback'
      const authorizeFields = this.fields([
        'response_type', 'code', 'client_id', authorizeClientId, 'redirect_uri', redirectUri,
        'scope', SCOPES, 'resource', RESOURCE, 'code_challenge', challenge,
        'code_challenge_method', 'S256', 'state', state, 'nonce', nonce,
        'ext_agent_host_id', hostId
      ])
      if (dynamicRegistration) {
        authorizeFields.set('agent_name_hint', 'HiSH')
      } else if (this.registration) {
        if (this.registration.idTokenHint) authorizeFields.set('id_token_hint', this.registration.idTokenHint)
        if (this.registration.loginHint) authorizeFields.set('login_hint', this.registration.loginHint)
      }
      this.logAuthorizeDiagnostics(dynamicRegistration, hostId, redirectUri, state, nonce, verifier)
      const authorizeUrl = AUTHORIZE_ENDPOINT + '?' + this.formEncode(authorizeFields)
      const want: Want = { action: 'ohos.want.action.viewData', uri: authorizeUrl }
      await context.startAbility(want)
      const callback = await callbackPromise
      if (callback.error) throw new Error('OAUTH_CALLBACK_' + callback.error)
      if (callback.state !== state) throw new Error('OAUTH_STATE_MISMATCH')
      if (dynamicRegistration && !callback.clientId) throw new Error('OAUTH_ISSUED_CLIENT_ID_MISSING')
      const issuedClientId = dynamicRegistration ? callback.clientId : authorizeClientId
      if (!issuedClientId || issuedClientId === INITIAL_CLIENT_ID) {
        throw new Error('OAUTH_ISSUED_CLIENT_ID_INVALID')
      }
      const token = await this.exchangeCode(callback.code, verifier, redirectUri, issuedClientId)
      const claims = this.validateIdTokenClaims(token.id_token || '', nonce, issuedClientId)
      if (!this.hasScope(token.scope || '', 'chatgpt.tokens.use.direct')) {
        throw new Error('OAUTH_CHATGPT_PLAN_SCOPE_MISSING')
      }
      const refreshToken = token.refresh_token || ''
      if (!refreshToken) throw new Error('OAUTH_REFRESH_TOKEN_MISSING')
      this.credential = {
        refreshToken: refreshToken,
        clientId: issuedClientId,
        accountLabel: claims.email || claims.name || 'ChatGPT'
      }
      this.registration = {
        clientId: issuedClientId,
        idTokenHint: token.id_token || '',
        loginHint: claims.email || ''
      }
      await this.writeRegistration(this.registration)
      await this.writeCredential(this.credential)
      this.accessToken = this.toAccessToken(token)
      this.state = ChatGPTAuthState.SIGNED_IN
      this.message = ''
      this.notify()
      return this.accessToken
    } catch (error) {
      this.state = ChatGPTAuthState.ERROR
      this.message = this.errorMessage(error, 'OAUTH_SIGN_IN_FAILED')
      this.notify()
      throw error instanceof Error ? error : new Error('OAUTH_SIGN_IN_FAILED')
    } finally {
      if (server) {
        try { await server.close() } catch (error) { }
      }
    }
  }

  async getValidAccessToken(): Promise<ChatGPTAccessToken> {
    if (this.accessToken && this.accessToken.expiresAt - Date.now() > REFRESH_SKEW_MS) return this.accessToken
    if (this.refreshInFlight) return this.refreshInFlight
    this.refreshInFlight = this.refreshAccessToken()
    try {
      return await this.refreshInFlight
    } finally {
      this.refreshInFlight = null
    }
  }

  async logout(): Promise<void> {
    const credential = this.credential
    this.accessToken = null
    this.credential = null
    await this.removeCredential()
    if (credential) {
      try {
        await this.postForm(REVOCATION_ENDPOINT, this.fields([
          'token', credential.refreshToken, 'token_type_hint', 'refresh_token',
          'client_id', credential.clientId
        ]))
      } catch (error) {
        // Local logout must succeed even if remote revocation is unavailable.
      }
    }
    this.state = ChatGPTAuthState.SIGNED_OUT
    this.message = ''
    this.notify()
  }

  private async refreshAccessToken(): Promise<ChatGPTAccessToken> {
    if (!this.credential) throw new Error('CHATGPT_NOT_SIGNED_IN')
    this.state = ChatGPTAuthState.REFRESHING
    this.notify()
    const token = await this.postForm(TOKEN_ENDPOINT, this.fields([
      'grant_type', 'refresh_token', 'refresh_token', this.credential.refreshToken,
      'client_id', this.credential.clientId, 'resource', RESOURCE
    ]))
    if (token.refresh_token) {
      const rotatedCredential: OAuthStoredCredential = {
        refreshToken: token.refresh_token,
        clientId: this.credential.clientId,
        accountLabel: this.credential.accountLabel
      }
      await this.writeCredential(rotatedCredential)
      this.credential = rotatedCredential
    }
    this.accessToken = this.toAccessToken(token)
    this.state = ChatGPTAuthState.SIGNED_IN
    this.message = ''
    this.notify()
    return this.accessToken
  }

  private async exchangeCode(code: string, verifier: string, redirectUri: string,
    clientId: string): Promise<OAuthTokenPayload> {
    return await this.postForm(TOKEN_ENDPOINT, this.fields([
      'grant_type', 'authorization_code', 'code', code, 'redirect_uri', redirectUri,
      'client_id', clientId, 'code_verifier', verifier, 'resource', RESOURCE
    ]))
  }

  private async postForm(url: string, fields: Map<string, string>): Promise<OAuthTokenPayload> {
    const request = http.createHttp()
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/x-www-form-urlencoded' },
        extraData: this.formEncode(fields),
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        connectTimeout: 15000,
        readTimeout: 30000
      })
      const body = typeof response.result === 'string' ? response.result : ''
      const parsed = body ? JSON.parse(body) as OAuthTokenPayload : new Object() as OAuthTokenPayload
      if (response.responseCode < 200 || response.responseCode >= 300 || parsed.error) {
        throw new Error(parsed.error_description || parsed.error || 'OAUTH_HTTP_' + response.responseCode)
      }
      return parsed
    } finally {
      request.destroy()
    }
  }

  private waitForCallback(server: socket.TCPSocketServer): Promise<OAuthCallbackResult> {
    return new Promise<OAuthCallbackResult>((resolve, reject): void => {
      let settled = false
      const timeout = setTimeout((): void => {
        if (!settled) {
          settled = true
          reject(new Error('OAUTH_CALLBACK_TIMEOUT'))
        }
      }, 180000)
      server.on('connect', (connection: socket.TCPSocketConnection): void => {
        connection.on('message', (message: socket.SocketMessageInfo): void => {
          if (settled) return
          const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(message.message))
          const firstLine = text.split('\r\n')[0] || ''
          const target = firstLine.split(' ')[1] || ''
          const result = this.parseCallbackTarget(target)
          const ok = !!result.code && !result.error
          const body = ok ? 'Sign in complete. You can return to HiSH.' : 'Sign in failed. Return to HiSH.'
          void connection.send({ data: 'HTTP/1.1 ' + (ok ? '200 OK' : '400 Bad Request') +
            '\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ' + body.length +
            '\r\nConnection: close\r\n\r\n' + body }).finally((): void => { void connection.close() })
          settled = true
          clearTimeout(timeout)
          resolve(result)
        })
      })
    })
  }

  private parseCallbackTarget(target: string): OAuthCallbackResult {
    const queryIndex = target.indexOf('?')
    const query = queryIndex >= 0 ? target.substring(queryIndex + 1) : ''
    const values: Record<string, string> = {}
    for (const pair of query.split('&')) {
      if (!pair) continue
      const separator = pair.indexOf('=')
      const key = decodeURIComponent(separator >= 0 ? pair.substring(0, separator) : pair)
      const value = decodeURIComponent(separator >= 0 ? pair.substring(separator + 1) : '')
      values[key] = value
    }
    return { code: values['code'] || '', state: values['state'] || '',
      clientId: values['client_id'] || '', error: values['error'] || '' }
  }

  private validateIdTokenClaims(idToken: string, nonce: string, clientId: string): OAuthIdClaims {
    const parts = idToken.split('.')
    if (parts.length !== 3) throw new Error('OAUTH_ID_TOKEN_INVALID')
    const claimsText = util.TextDecoder.create('utf-8').decodeToString(this.decodeBase64Url(parts[1]))
    const claims = JSON.parse(claimsText) as OAuthIdClaims
    if (claims.iss !== 'https://auth.openai.com') throw new Error('OAUTH_ISSUER_INVALID')
    const audienceValid = typeof claims.aud === 'string' ? claims.aud === clientId :
      Array.isArray(claims.aud) && claims.aud.indexOf(clientId) !== -1
    if (!audienceValid) throw new Error('OAUTH_AUDIENCE_INVALID')
    if (!claims.exp || claims.exp * 1000 <= Date.now()) throw new Error('OAUTH_ID_TOKEN_EXPIRED')
    if (claims.nonce !== nonce) throw new Error('OAUTH_NONCE_MISMATCH')
    return claims
  }

  private async writeCredential(credential: OAuthStoredCredential): Promise<void> {
    const byteLength = util.TextEncoder.create().encodeInto(credential.refreshToken).length
    const metadata = await this.refreshTokenStore().save(credential.refreshToken)
    const record: OAuthCredentialAssetRecord = {
      clientId: credential.clientId,
      accountLabel: credential.accountLabel
    }
    await this.writeStringAsset(ASSET_ALIAS, JSON.stringify(record))
    hilog.info(DOMAIN, 'ChatGPTOAuth',
      'Refresh credential saved bytes=%{public}d chunks=%{public}d generation=%{public}s',
      byteLength, metadata.chunkCount, metadata.generation)
  }

  private async writeRegistration(registration: OAuthRegistration): Promise<void> {
    if (registration.idTokenHint) await this.registrationHintStore().save(registration.idTokenHint)
    const record: OAuthRegistrationAssetRecord = {
      clientId: registration.clientId,
      loginHint: registration.loginHint,
      hasIdTokenHint: registration.idTokenHint.length > 0
    }
    await this.writeStringAsset(REGISTRATION_ASSET_ALIAS, JSON.stringify(record))
  }

  private async writeStringAsset(aliasText: string, value: string): Promise<void> {
    const encoder = util.TextEncoder.create()
    const alias = encoder.encodeInto(aliasText)
    const secret = encoder.encodeInto(value)
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>()
    query.set(asset.Tag.ALIAS, alias)
    try { await asset.remove(query) } catch (error) { }
    const attributes: asset.AssetMap = new Map<asset.Tag, asset.Value>()
    attributes.set(asset.Tag.ALIAS, alias)
    attributes.set(asset.Tag.SECRET, secret)
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED)
    await asset.add(attributes)
  }

  private async readCredential(): Promise<OAuthStoredCredential | null> {
    const value = await this.readStringAsset(ASSET_ALIAS)
    if (!value) return null
    try {
      const record = JSON.parse(value) as OAuthCredentialAssetRecord
      if (!record.clientId || !record.accountLabel) return null
      if (record.refreshToken) {
        const legacy: OAuthStoredCredential = {
          refreshToken: record.refreshToken,
          clientId: record.clientId,
          accountLabel: record.accountLabel
        }
        await this.writeCredential(legacy)
        return legacy
      }
      const refreshToken = await this.refreshTokenStore().load()
      hilog.info(DOMAIN, 'ChatGPTOAuth', 'Refresh credential loaded successfully')
      return { refreshToken: refreshToken, clientId: record.clientId, accountLabel: record.accountLabel }
    } catch (error) {
      hilog.error(DOMAIN, 'ChatGPTOAuth', 'Refresh credential load failed: %{public}s',
        this.errorMessage(error as Object, 'OAUTH_REFRESH_TOKEN_LOAD_FAILED'))
      return null
    }
  }

  private async readRegistration(): Promise<OAuthRegistration | null> {
    const value = await this.readStringAsset(REGISTRATION_ASSET_ALIAS)
    if (!value) return null
    try {
      const record = JSON.parse(value) as OAuthRegistrationAssetRecord
      if (!record.clientId || record.clientId === INITIAL_CLIENT_ID) return null
      if (record.idTokenHint) {
        const legacy: OAuthRegistration = {
          clientId: record.clientId,
          idTokenHint: record.idTokenHint,
          loginHint: record.loginHint || ''
        }
        await this.writeRegistration(legacy)
        return legacy
      }
      let idTokenHint = ''
      if (record.hasIdTokenHint) idTokenHint = await this.registrationHintStore().load()
      return { clientId: record.clientId, idTokenHint: idTokenHint, loginHint: record.loginHint || '' }
    } catch (error) {
      return null
    }
  }

  private async readStringAsset(aliasText: string): Promise<string> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>()
    query.set(asset.Tag.ALIAS, util.TextEncoder.create().encodeInto(aliasText))
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL)
    try {
      const results = await asset.query(query)
      if (results.length !== 1) return ''
      const value = results[0].get(asset.Tag.SECRET)
      if (!(value instanceof Uint8Array)) return ''
      return util.TextDecoder.create('utf-8').decodeToString(value)
    } catch (error) {
      return ''
    }
  }

  private async removeCredential(): Promise<void> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>()
    query.set(asset.Tag.ALIAS, util.TextEncoder.create().encodeInto(ASSET_ALIAS))
    try { await asset.remove(query) } catch (error) { }
    await this.refreshTokenStore().deleteAll()
    hilog.info(DOMAIN, 'ChatGPTOAuth', 'Refresh credential chunks and metadata removed')
  }

  private refreshTokenStore(): RefreshTokenChunkStore {
    return new RefreshTokenChunkStore(new AssetStoreRefreshBackend(), new AssetStoreRefreshIntegrity(),
      REFRESH_ASSET_PREFIX, REFRESH_METADATA_ALIAS)
  }

  private registrationHintStore(): RefreshTokenChunkStore {
    return new RefreshTokenChunkStore(new AssetStoreRefreshBackend(), new AssetStoreRefreshIntegrity(),
      REGISTRATION_HINT_ASSET_PREFIX, REGISTRATION_HINT_METADATA_ALIAS)
  }

  private randomBase64Url(length: number): string {
    const data = cryptoFramework.createRandom().generateRandomSync(length).data
    return this.encodeBase64Url(data)
  }

  private async sha256Base64Url(value: string): Promise<string> {
    const digest = cryptoFramework.createMd('SHA256')
    await digest.update({ data: util.TextEncoder.create().encodeInto(value) })
    return this.encodeBase64Url((await digest.digest()).data)
  }

  private encodeBase64Url(value: Uint8Array): string {
    return new util.Base64Helper().encodeToStringSync(value, util.Type.BASIC_URL_SAFE).replace(/=+$/g, '')
  }

  private decodeBase64Url(value: string): Uint8Array {
    let padded = value
    while (padded.length % 4 !== 0) padded += '='
    return new util.Base64Helper().decodeSync(padded, util.Type.BASIC_URL_SAFE)
  }

  private formEncode(fields: Map<string, string>): string {
    const pairs: string[] = []
    fields.forEach((value: string, key: string): void => {
      pairs.push(encodeURIComponent(key) + '=' + encodeURIComponent(value))
    })
    return pairs.join('&')
  }

  private fields(values: string[]): Map<string, string> {
    const result = new Map<string, string>()
    for (let index = 0; index + 1 < values.length; index += 2) {
      result.set(values[index], values[index + 1])
    }
    return result
  }

  private async ensureHostId(): Promise<string> {
    if (this.isValidHostId(this.hostId)) return this.hostId
    this.hostId = 'urn:uuid:' + this.generateUuidV4()
    await this.writeStringAsset(HOST_ASSET_ALIAS, this.hostId)
    return this.hostId
  }

  private generateUuidV4(): string {
    const bytes = cryptoFramework.createRandom().generateRandomSync(16).data
    bytes[6] = (bytes[6] & 0x0f) | 0x40
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let hex = ''
    for (let index = 0; index < bytes.length; index++) {
      hex += bytes[index].toString(16).padStart(2, '0')
    }
    return hex.substring(0, 8) + '-' + hex.substring(8, 12) + '-' + hex.substring(12, 16) + '-' +
      hex.substring(16, 20) + '-' + hex.substring(20)
  }

  private isValidHostId(value: string): boolean {
    return /^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
  }

  private hasScope(scopes: string, required: string): boolean {
    return scopes.split(/\s+/).indexOf(required) !== -1
  }

  private logAuthorizeDiagnostics(dynamic: boolean, hostId: string, redirectUri: string,
    state: string, nonce: string, verifier: string): void {
    hilog.info(DOMAIN, 'ChatGPTOAuth', 'OAuth authorize endpoint: %{public}s', AUTHORIZE_ENDPOINT)
    hilog.info(DOMAIN, 'ChatGPTOAuth', 'client_id type: %{public}s', dynamic ? 'dynamic' : 'issued')
    hilog.info(DOMAIN, 'ChatGPTOAuth', 'ext_agent_host_id present=%{public}s format=%{public}s length=%{public}d',
      hostId.length > 0, this.isValidHostId(hostId) ? 'urn:uuid' : 'invalid', hostId.length)
    hilog.info(DOMAIN, 'ChatGPTOAuth', 'redirect_uri: %{public}s', redirectUri)
    hilog.info(DOMAIN, 'ChatGPTOAuth', 'requested scopes: %{public}s', SCOPES)
    hilog.info(DOMAIN, 'ChatGPTOAuth', 'state=%{public}s nonce=%{public}s verifier=%{public}s',
      state.length > 0 ? 'present' : 'missing', nonce.length > 0 ? 'present' : 'missing',
      verifier.length > 0 ? 'present' : 'missing')
  }

  private toAccessToken(payload: OAuthTokenPayload): ChatGPTAccessToken {
    if (!payload.access_token) throw new Error('OAUTH_ACCESS_TOKEN_MISSING')
    const expiresIn = payload.expires_in && payload.expires_in > 0 ? payload.expires_in : 3600
    return new ChatGPTAccessToken(payload.access_token, Date.now() + expiresIn * 1000)
  }

  private requireContext(): common.UIAbilityContext {
    if (!this.context) throw new Error('OAUTH_CONTEXT_NOT_READY')
    return this.context
  }

  private notify(): void {
    for (const listener of this.listeners.slice()) listener(this.state, this.message)
  }

  private errorMessage(error: Object, fallback: string): string {
    return error instanceof Error ? error.message : fallback
  }
}

export const chatGPTOAuthService: ChatGPTOAuthService = new ChatGPTOAuthService()
