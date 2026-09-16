Set-StrictMode -Version Latest

function Select-CodexStableReleaseCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Releases
    )

    $candidates = foreach ($release in $Releases) {
        if ($null -eq $release) { continue }

        $draftProperty = $release.PSObject.Properties['draft']
        $prereleaseProperty = $release.PSObject.Properties['prerelease']
        $tagProperty = $release.PSObject.Properties['tag_name']
        $urlProperty = $release.PSObject.Properties['html_url']
        if ($null -eq $draftProperty -or $draftProperty.Value -isnot [bool] -or
            $null -eq $prereleaseProperty -or $prereleaseProperty.Value -isnot [bool] -or
            $null -eq $tagProperty -or $null -eq $urlProperty) {
            continue
        }
        if ($draftProperty.Value -or $prereleaseProperty.Value) { continue }

        $tag = [string]$tagProperty.Value
        if ($tag -notmatch '^rust-v(?<major>0|[1-9][0-9]*)\.(?<minor>0|[1-9][0-9]*)\.(?<patch>0|[1-9][0-9]*)$') {
            continue
        }

        $versionText = '{0}.{1}.{2}' -f $Matches.major, $Matches.minor, $Matches.patch
        try {
            $semanticVersion = [version]$versionText
        }
        catch {
            continue
        }
        $expectedUrl = "https://github.com/openai/codex/releases/tag/$tag"
        $releaseUrl = [string]$urlProperty.Value
        if ($releaseUrl -ne $expectedUrl) { continue }

        [pscustomobject]@{
            Version         = $versionText
            Tag             = $tag
            Url             = $releaseUrl
            SemanticVersion = $semanticVersion
        }
    }

    return $candidates |
        Sort-Object -Property SemanticVersion -Descending |
        Select-Object -First 1
}

function Get-LatestCodexStableReleaseCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $releaseApi = 'https://api.github.com/repos/openai/codex/releases'
    $latest = $null
    try {
        $latest = Invoke-RestMethod -Headers $Headers -Uri "$releaseApi/latest"
    }
    catch {
        # The recent-release scan below is also a safe fallback for a missing or
        # temporarily unusable GitHub "latest" endpoint.
    }

    if ($null -ne $latest) {
        $candidate = Select-CodexStableReleaseCandidate -Releases @($latest)
        if ($null -ne $candidate) {
            $candidate | Add-Member -NotePropertyName DiscoverySource -NotePropertyValue 'latest'
            return $candidate
        }
    }

    try {
        $recent = @(Invoke-RestMethod -Headers $Headers -Uri "$releaseApi`?per_page=100")
    }
    catch {
        throw 'GitHub did not return a verifiable openai/codex release list.'
    }

    $candidate = Select-CodexStableReleaseCandidate -Releases $recent
    if ($null -eq $candidate) {
        throw 'No non-draft, non-prerelease openai/codex release matched rust-vMAJOR.MINOR.PATCH.'
    }
    $candidate | Add-Member -NotePropertyName DiscoverySource -NotePropertyValue 'recent'
    return $candidate
}
