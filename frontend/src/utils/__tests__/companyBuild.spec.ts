import { describe, expect, it } from 'vitest'
import { companyReleaseVersion, upstreamReleaseVersion, isCompanyVersion, companyVersionLabel, companyVersionDetails } from '../companyBuild'

const identity = `company-${'a'.repeat(40)}`

describe('Company presentation metadata', () => {
  it('reads versioned release metadata rather than package.json or a synthetic version', () => {
    expect(companyReleaseVersion).toMatch(/^\d+\.\d+\.\d+$/)
    expect(upstreamReleaseVersion).toMatch(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/)
    expect(companyVersionLabel(identity)).toBe(`Company v${companyReleaseVersion}`)
  })
  it.each([undefined, null, '', '0.2.0', 'company-abcdef', 'company-' + 'a'.repeat(41), 'company-' + 'A'.repeat(40), '0.1.183-company.abcdef'])(
    'does not identify %s as the strict Company display format', (value) => expect(isCompanyVersion(value)).toBe(false)
  )
  it('preserves unknown formats and the complete raw build identity', () => {
    expect(isCompanyVersion(identity)).toBe(true)
    expect(companyVersionLabel('0.2.0')).toBe('0.2.0')
    expect(companyVersionDetails(identity)).toBe(`Company v${companyReleaseVersion}\nUpstream: v${upstreamReleaseVersion}\n${identity}`)
  })
})
