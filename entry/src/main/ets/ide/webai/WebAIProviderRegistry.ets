import { url } from '@kit.ArkTS'

export const LOCAL_AI_WORKSPACE_ID = 'local'

export class WebAIProvider {
  id: string
  name: string
  homeUrl: string
  allowedDomains: string[]

  constructor(id: string, name: string, homeUrl: string, allowedDomains: string[]) {
    this.id = id
    this.name = name
    this.homeUrl = homeUrl
    this.allowedDomains = allowedDomains
  }
}

/** Registry for browser-backed AI sites. It is intentionally separate from inference providers. */
export class WebAIProviderRegistry {
  private providers: WebAIProvider[] = [
    new WebAIProvider('deepseek', 'DeepSeek', 'https://chat.deepseek.com/', [
      'deepseek.com'
    ]),
    new WebAIProvider('chatgpt', 'ChatGPT', 'https://chatgpt.com/', [
      'chatgpt.com', 'openai.com', 'accounts.google.com', 'login.microsoftonline.com', 'appleid.apple.com'
    ]),
    new WebAIProvider('doubao', '豆包', 'https://www.doubao.com/chat/', [
      'doubao.com', 'bytedance.com', 'bytedance.net'
    ]),
    new WebAIProvider('kimi', 'Kimi', 'https://www.kimi.com/', [
      'kimi.com', 'moonshot.cn'
    ]),
    new WebAIProvider('qwen', '通义千问', 'https://chat.qwen.ai/', [
      'qwen.ai', 'aliyun.com', 'alibaba.com'
    ]),
    new WebAIProvider('yuanbao', '腾讯元宝', 'https://yuanbao.tencent.com/chat/', [
      'yuanbao.tencent.com', 'qq.com', 'weixin.qq.com'
    ]),
    new WebAIProvider('gemini', 'Gemini', 'https://gemini.google.com/app', [
      'gemini.google.com', 'accounts.google.com'
    ]),
    new WebAIProvider('claude', 'Claude', 'https://claude.ai/new', [
      'claude.ai', 'anthropic.com', 'accounts.google.com'
    ])
  ]

  list(): WebAIProvider[] {
    return this.providers.slice()
  }

  find(id: string): WebAIProvider | null {
    for (const provider of this.providers) {
      if (provider.id === id) return provider
    }
    return null
  }

  isAllowedNavigation(providerId: string, targetUrl: string): boolean {
    const provider = this.find(providerId)
    if (!provider) return false
    try {
      const parsed = url.URL.parseURL(targetUrl)
      if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return false
      const host = parsed.hostname.toLowerCase()
      for (const allowed of provider.allowedDomains) {
        if (host === allowed || host.endsWith('.' + allowed)) return true
      }
    } catch (error) {
      return false
    }
    return false
  }
}

export const webAIProviderRegistry: WebAIProviderRegistry = new WebAIProviderRegistry()
