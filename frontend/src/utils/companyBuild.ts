import companyVersion from '../../../COMPANY_VERSION?raw'
import upstreamVersion from '../../../backend/cmd/server/VERSION?raw'

// Display metadata is bundled with the frontend. Never replace the backend's
// company-<full SHA> identity or use this helper for authorization/update policy.
const releasePattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$/

export const companyReleaseVersion = companyVersion.trim()
export const upstreamReleaseVersion = upstreamVersion.trim()

export function isCompanyVersion(version: unknown): version is string {
  return typeof version === 'string' && /^company-[0-9a-f]{40}$/.test(version)
}

export function companyVersionLabel(version: string): string {
  if (!isCompanyVersion(version)) return version
  return releasePattern.test(companyReleaseVersion)
    ? `Company v${companyReleaseVersion}`
    : `company-${version.slice(8, 16)}`
}

export function companyVersionDetails(version: string): string {
  return [companyVersionLabel(version), `Upstream: v${upstreamReleaseVersion}`, version].join('\n')
}
