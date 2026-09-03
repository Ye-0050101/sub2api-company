import { beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, RouterLinkStub } from '@vue/test-utils'
import HomeView from '../HomeView.vue'
import CompanyHome from '@/components/home/CompanyHome.vue'
import zh from '@/i18n/locales/zh/landing'
import en from '@/i18n/locales/en/landing'

const { appStore, authStore, language } = vi.hoisted(() => ({
  language: { locale: 'zh' },
  appStore: {
    cachedPublicSettings: {} as Record<string, unknown>, siteName: 'Sub2API', siteLogo: '', docUrl: '',
    siteVersion: '', publicSettingsLoaded: true, fetchPublicSettings: vi.fn()
  },
  authStore: { isAuthenticated: false, isAdmin: false, user: null, checkAuth: vi.fn() }
}))
vi.mock('@/stores', () => ({ useAppStore: () => appStore, useAuthStore: () => authStore }))
vi.mock('@/stores/app', () => ({ useAppStore: () => appStore }))
vi.mock('@/composables/useClipboard', () => ({ useClipboard: () => ({ copied: false, copyToClipboard: vi.fn() }) }))
vi.mock('vue-i18n', async (original) => ({
  ...await original<typeof import('vue-i18n')>(),
  useI18n: () => ({ t: (key: string) => {
    const messages = language.locale === 'zh' ? zh : en
    const value = key.split('.').reduce<unknown>((current, part) => {
      return current && typeof current === 'object' ? (current as Record<string, unknown>)[part] : undefined
    }, messages)
    return typeof value === 'string' ? value : key
  } })
}))

function render(settings: Record<string, unknown> = {}, locale = 'zh') {
  appStore.cachedPublicSettings = { version: `company-${'a'.repeat(40)}`, ...settings }
  language.locale = locale
  return mount(HomeView, { global: {
    stubs: {
      RouterLink: RouterLinkStub, Icon: true, LocaleSwitcher: true, CompanyVersionBadge: true,
      BaseDialog: { props: ['show'], template: '<section v-if="show" role="dialog"><slot /><slot name="footer" /></section>' }
    }
  } })
}

describe('Company homepage integration', () => {
  beforeEach(() => {
    authStore.isAuthenticated = false
    authStore.isAdmin = false
    appStore.siteVersion = ''
    localStorage.clear()
    document.documentElement.classList.remove('dark')
    vi.spyOn(window, 'matchMedia').mockReturnValue({ matches: false } as MediaQueryList)
  })
  it('renders the approved Company experience without removed footer or marketing elements', () => {
    const wrapper = render()
    expect(wrapper.findComponent(CompanyHome).exists()).toBe(true)
    expect(wrapper.text()).toContain('HS AI 工作台')
    expect(wrapper.text()).toContain('受控出口')
    for (const forbidden of ['请遵守公司数据使用规范', '界面预览', '按量计费', '用多少付多少', 'GPT', 'Grok', 'DeepSeek']) expect(wrapper.text()).not.toContain(forbidden)
    expect(wrapper.find('.terminal-container').exists()).toBe(false)
    wrapper.unmount()
  })
  it.each([
    [{ home_content: '<main id="custom-home">Custom</main>' }, '#custom-home'],
    [{ compact_home_enabled: true }, '[data-testid="compact-home"]'],
    [{ version: '0.2.0' }, '.terminal-container']
  ])('retains existing homepage selection for %s', (settings, selector) => {
    const wrapper = render(settings)
    expect(wrapper.findComponent(CompanyHome).exists()).toBe(false)
    expect(wrapper.find(selector as string).exists()).toBe(true)
    wrapper.unmount()
  })
  it.each([[false, false, '/login'], [true, false, '/dashboard'], [true, true, '/admin/dashboard']])(
    'uses existing login/dashboard routes for authenticated=%s admin=%s', (authenticated, admin, destination) => {
      authStore.isAuthenticated = authenticated as boolean
      authStore.isAdmin = admin as boolean
      const wrapper = render()
      expect(wrapper.findAllComponents(RouterLinkStub).map(link => link.props('to'))).toEqual([destination, destination])
      wrapper.unmount()
    }
  )
  it('honors administrator branding and rejects an unsafe documentation URL', async () => {
    const wrapper = render({ site_name: 'Company title', site_subtitle: 'Saved subtitle', doc_url: 'javascript:alert(1)' })
    expect(wrapper.text()).toContain('Company title')
    expect(wrapper.text()).toContain('Saved subtitle')
    expect(wrapper.find('a[href^="javascript:"]').exists()).toBe(false)
    await wrapper.get('button.hs-secondary').trigger('click')
    expect(wrapper.get('[role="dialog"]').text()).toContain('在公司局域网内，使用汉森企业邮箱注册账号。')
    expect(wrapper.get('[role="dialog"]').text()).toContain('登录控制台，选择所属部门分组，创建个人 API 密钥。')
    wrapper.unmount()
  })
  it('supports existing guide links, motion control and theme switching', async () => {
    const wrapper = render({ doc_url: 'https://docs.example.com/start' })
    expect(wrapper.get('a.hs-secondary').attributes('href')).toBe('https://docs.example.com/start')
    expect(wrapper.get('a.hs-secondary').attributes('rel')).toBe('noopener noreferrer')
    const pause = wrapper.get('.hs-motion-toggle')
    await pause.trigger('click')
    expect(wrapper.get('[data-testid="company-home"]').classes()).toContain('hs-paused')
    expect(pause.attributes('aria-pressed')).toBe('true')
    await wrapper.get('button[aria-label="切换到深色模式"]').trigger('click')
    expect(document.documentElement.classList.contains('dark')).toBe(true)
    wrapper.unmount()
  })
  it('renders English Company content without supplier marketing', async () => {
    const wrapper = render({}, 'en')
    expect(wrapper.text()).toContain('Employee sign in')
    expect(wrapper.text()).toContain('Controlled routing')
    expect(wrapper.text()).not.toContain('Pay As You Go')
    await wrapper.get('button.hs-secondary').trigger('click')
    expect(wrapper.get('[role="dialog"]').text()).toContain('On the company local network, register using your Hoson corporate email address.')
    expect(wrapper.get('[role="dialog"]').text()).toContain('Sign in to the console, select your department group, and create a personal API key.')
    wrapper.unmount()
  })
})
