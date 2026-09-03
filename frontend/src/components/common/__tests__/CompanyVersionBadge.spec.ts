import { beforeEach, describe, expect, it, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import VersionBadge from '../VersionBadge.vue'
import { companyReleaseVersion, companyVersionDetails } from '@/utils/companyBuild'

const { appStore, authStore, copy } = vi.hoisted(() => ({
  authStore: { isAdmin: true },
  appStore: {
    versionLoading: false, currentVersion: '', latestVersion: '', hasUpdate: false,
    releaseInfo: null, buildType: 'source', fetchVersion: vi.fn().mockResolvedValue(undefined)
  },
  copy: vi.fn().mockResolvedValue(true)
}))
vi.mock('@/stores', () => ({ useAppStore: () => appStore, useAuthStore: () => authStore }))
vi.mock('@/composables/useClipboard', () => ({ useClipboard: () => ({ copied: false, copyToClipboard: copy }) }))
vi.mock('vue-i18n', async (original) => ({ ...await original<typeof import('vue-i18n')>(), useI18n: () => ({ t: (key: string) => key }) }))

function render(version: string) {
  return mount(VersionBadge, {
    props: { version },
    global: { stubs: {
      Icon: true,
      BaseDialog: { props: ['show', 'title'], template: '<section v-if="show" role="dialog"><h2>{{ title }}</h2><slot /></section>' }
    } }
  })
}

describe('Company release badge and legacy update protection', () => {
  beforeEach(() => {
    Object.assign(appStore, { currentVersion: '', buildType: 'source', hasUpdate: false })
    authStore.isAdmin = true
    vi.clearAllMocks()
  })
  it.each([true, false])('shows the release to admin=%s, retains full identity and copies it', async (admin) => {
    authStore.isAdmin = admin
    const raw = `company-${'b'.repeat(40)}`
    const wrapper = render(raw)
    expect(wrapper.text()).toBe(`Company v${companyReleaseVersion}`)
    expect(appStore.fetchVersion).not.toHaveBeenCalled()
    await wrapper.get('.company-version-trigger').trigger('click')
    expect(wrapper.get('[role="dialog"]').text()).toContain(raw)
    expect(wrapper.text()).toContain('version.companyManagedHint')
    await wrapper.get('[role="dialog"] button').trigger('click')
    expect(copy).toHaveBeenCalledWith(companyVersionDetails(raw))
    expect(wrapper.find('a[href*="github.com"]').exists()).toBe(false)
    wrapper.unmount()
  })
  it('preserves protection for legacy Company version formats identified by the backend', async () => {
    appStore.buildType = 'company'
    const wrapper = render('0.1.183-company.abcdef')
    await wrapper.get('button').trigger('click')
    expect(wrapper.text()).toContain('version.companyManagedHint')
    expect(wrapper.text()).not.toContain('version.updateNow')
    expect(wrapper.find('a[href*="github.com"]').exists()).toBe(false)
    wrapper.unmount()
  })
  it('leaves ordinary release display and the existing admin fetch unchanged', () => {
    appStore.buildType = 'release'
    const wrapper = render('0.2.0')
    expect(wrapper.text()).toBe('v0.2.0')
    expect(appStore.fetchVersion).toHaveBeenCalledWith(false)
    wrapper.unmount()
  })
})
