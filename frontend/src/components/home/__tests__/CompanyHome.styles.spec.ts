import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { compileStyle, parse } from 'vue/compiler-sfc'

describe('Company styles stay local after Vue compilation', () => {
  it.each([
    ['../CompanyHome.vue', '.dark .company-home'],
    ['../../common/CompanyVersionBadge.vue', '.dark .company-version-trigger']
  ])('scopes dark mode to %s', (file, selector) => {
    const source = readFileSync(new URL(file, import.meta.url), 'utf8')
    const { descriptor } = parse(source)
    const style = compileStyle({ source: descriptor.styles[0].content, id: 'data-v-company-test', scoped: true })
    expect(style.errors).toEqual([])
    expect(style.code).toContain(selector)
    expect(style.code).not.toMatch(/\.dark\s*\{/)
  })
})
