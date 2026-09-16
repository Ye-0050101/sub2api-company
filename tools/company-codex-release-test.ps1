Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'company-codex-release.ps1')

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Actual -ne $Expected) {
        throw "$Message (expected=$Expected actual=$Actual)"
    }
}

$releases = @(
    [pscustomobject]@{ tag_name = 'rust-v0.159.9'; draft = $false; prerelease = $false; html_url = 'https://github.com/openai/codex/releases/tag/rust-v0.159.9' }
    [pscustomobject]@{ tag_name = 'rust-v0.160.0'; draft = $false; prerelease = $false; html_url = 'https://github.com/openai/codex/releases/tag/rust-v0.160.0' }
    [pscustomobject]@{ tag_name = 'rust-v0.999.0'; draft = $true; prerelease = $false; html_url = 'https://github.com/openai/codex/releases/tag/rust-v0.999.0' }
    [pscustomobject]@{ tag_name = 'rust-v0.998.0'; draft = $false; prerelease = $true; html_url = 'https://github.com/openai/codex/releases/tag/rust-v0.998.0' }
    [pscustomobject]@{ tag_name = 'rust-v01.0.0'; draft = $false; prerelease = $false; html_url = 'https://github.com/openai/codex/releases/tag/rust-v01.0.0' }
    [pscustomobject]@{ tag_name = 'rust-v0.997.0-beta.1'; draft = $false; prerelease = $false; html_url = 'https://github.com/openai/codex/releases/tag/rust-v0.997.0-beta.1' }
    [pscustomobject]@{ tag_name = 'v0.996.0'; draft = $false; prerelease = $false; html_url = 'https://github.com/openai/codex/releases/tag/v0.996.0' }
    [pscustomobject]@{ tag_name = 'rust-v0.995.0'; draft = $false; prerelease = $false; html_url = 'https://example.com/not-openai-codex' }
    [pscustomobject]@{ tag_name = 'rust-v999999999999.0.0'; draft = $false; prerelease = $false; html_url = 'https://github.com/openai/codex/releases/tag/rust-v999999999999.0.0' }
    [pscustomobject]@{ tag_name = 'rust-v0.994.0'; html_url = 'https://github.com/openai/codex/releases/tag/rust-v0.994.0' }
)

$candidate = Select-CodexStableReleaseCandidate -Releases $releases
Assert-Equal -Actual $candidate.Version -Expected '0.160.0' -Message 'Semantic maximum was not selected'
Assert-Equal -Actual $candidate.Tag -Expected 'rust-v0.160.0' -Message 'Candidate tag is incorrect'
Assert-Equal -Actual $candidate.Url -Expected 'https://github.com/openai/codex/releases/tag/rust-v0.160.0' -Message 'Candidate URL is incorrect'

$none = Select-CodexStableReleaseCandidate -Releases @(
    [pscustomobject]@{ tag_name = 'rust-v0.161.0-alpha.1'; draft = $false; prerelease = $true; html_url = 'https://github.com/openai/codex/releases/tag/rust-v0.161.0-alpha.1' }
)
Assert-Equal -Actual ($null -eq $none) -Expected $true -Message 'Invalid releases must not produce a candidate'

Write-Host 'Codex stable release candidate selection: OK'
