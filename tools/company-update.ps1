[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$UpstreamRef
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
}

function Get-CheckedOutput {
    param([string]$Command, [string[]]$Arguments)
    $output = & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
    return ($output | Out-String).Trim()
}

$repoRoot = Get-CheckedOutput git @('rev-parse', '--show-toplevel')
Set-Location -LiteralPath $repoRoot
if ((Get-CheckedOutput git @('branch', '--show-current')) -ne 'company/egress-v1') {
    throw 'Switch to company/egress-v1 first.'
}
if ((Get-CheckedOutput git @('status', '--porcelain')) -ne '') { throw 'Worktree must be clean.' }
if ((Get-CheckedOutput git @('remote', 'get-url', '--push', 'upstream')) -ne 'DISABLED') {
    throw 'upstream push URL must be DISABLED.'
}

$companyBranch = 'company/egress-v1'
$ubuntuBranch = 'company/egress-v1-ubuntu22.04'
Invoke-Checked git @(
    'fetch', 'origin',
    'refs/heads/main:refs/remotes/origin/main',
    "refs/heads/${companyBranch}:refs/remotes/origin/${companyBranch}",
    "refs/heads/${ubuntuBranch}:refs/remotes/origin/${ubuntuBranch}"
)
if ((Get-CheckedOutput git @('rev-parse', 'HEAD')) -ne
    (Get-CheckedOutput git @('rev-parse', "origin/$companyBranch"))) {
    throw 'Local company/egress-v1 must exactly match origin before updating.'
}
if ((Get-CheckedOutput git @('rev-parse', 'main')) -ne
    (Get-CheckedOutput git @('rev-parse', 'origin/main'))) {
    throw 'Local main must exactly match origin before updating.'
}

Invoke-Checked git @('fetch', 'upstream', '--tags')
$targetSha = Get-CheckedOutput git @('rev-parse', '--verify', "$UpstreamRef`^{commit}")
$baseline = 'e8cb019fabf8b55199436229044cbf9aa7a82564'
& git merge-base --is-ancestor $baseline $targetSha
if ($LASTEXITCODE -ne 0) { throw 'Target is not a descendant of the frozen Company V1 baseline.' }

$tempBranch = 'company/upgrade-{0}-{1}' -f $targetSha.Substring(0, 12), [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Invoke-Checked git @('switch', '-c', $tempBranch)
try {
    Invoke-Checked git @('merge', '--no-edit', $targetSha)
    $python = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' } else { 'python' }
    Invoke-Checked $python @('tools/check_company_egress_guard.py')
    $companyCommit = Get-CheckedOutput git @('rev-parse', 'HEAD')
    Invoke-Checked git @('push', 'origin', $tempBranch)
}
catch {
    Write-Warning 'Upgrade stopped without force push or automatic reset. Inspect the current temporary branch.'
    throw
}

$credentialLines = "protocol=https`nhost=github.com`n`n" | git credential fill
$credential = @{}
foreach ($line in $credentialLines) {
    $parts = $line -split '=', 2
    if ($parts.Count -eq 2) { $credential[$parts[0]] = $parts[1] }
}
if (-not $credential.ContainsKey('password')) {
    throw 'Current GitHub credential is unavailable; this script never requests or stores a PAT.'
}
$headers = @{
    'Accept'         = 'application/vnd.github+json'
    'Authorization'  = 'Bearer ' + $credential['password']
    'User-Agent'     = 'Sub2API-Company-Update'
}
$repoApi = 'https://api.github.com/repos/Ye-0050101/sub2api-company'
function Wait-CompanyChecks {
    param(
        [Parameter(Mandatory = $true)][string]$Branch,
        [Parameter(Mandatory = $true)][string]$Commit
    )
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(30)
    $encodedBranch = [Uri]::EscapeDataString($Branch)
    $ci = $null
    $security = $null
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $runs = Invoke-RestMethod -Headers $headers -Uri "$repoApi/actions/runs?branch=$encodedBranch&per_page=20"
        $matching = @($runs.workflow_runs | Where-Object { $_.head_sha -eq $Commit })
        $ci = $matching | Where-Object { $_.name -eq 'CI' } | Select-Object -First 1
        $security = $matching | Where-Object { $_.name -eq 'Security Scan' } | Select-Object -First 1
        if ($ci -and $security -and $ci.status -eq 'completed' -and $security.status -eq 'completed') { break }
        Start-Sleep -Seconds 15
    }
    if (-not $ci -or $ci.status -ne 'completed' -or $ci.conclusion -ne 'success') {
        throw "CI did not complete successfully; inspect remote branch $Branch."
    }
    if (-not $security -or $security.status -ne 'completed' -or $security.conclusion -ne 'success') {
        throw "Security Scan did not complete successfully; inspect remote branch $Branch."
    }
    return [pscustomobject]@{ CI = $ci; Security = $security }
}

$companyChecks = Wait-CompanyChecks -Branch $tempBranch -Commit $companyCommit
$ciRun = $companyChecks.CI
$securityRun = $companyChecks.Security

$artifacts = Invoke-RestMethod -Headers $headers -Uri "$repoApi/actions/runs/$($ciRun.id)/artifacts?per_page=100"
$artifactName = "sub2api-linux-amd64-$companyCommit"
$artifact = $artifacts.artifacts | Where-Object { $_.name -eq $artifactName -and -not $_.expired } | Select-Object -First 1
if (-not $artifact) { throw "Verified embedded-site artifact not found: $artifactName" }

$distDir = Join-Path $repoRoot 'dist/company'
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
function Clear-ArtifactExtractDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    if ((Split-Path -Parent $resolved) -ne $resolvedRoot) {
        throw "Refusing to remove artifact directory outside the verified dist root: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
$zipPath = Join-Path $distDir "$artifactName.zip"
$extractDir = Join-Path $distDir $artifactName
# Invoke-WebRequest does not preserve Authorization on a cross-host redirect
# unless -PreserveAuthorizationOnRedirect is explicitly supplied. Follow the
# GitHub -> temporary blob redirect without forwarding the GitHub credential.
Invoke-WebRequest -Headers $headers -Uri $artifact.archive_download_url -OutFile $zipPath -MaximumRedirection 5
Clear-ArtifactExtractDirectory -Path $extractDir -Root $distDir
Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir
$binaryPath = Join-Path $extractDir 'sub2api-linux-amd64'
if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) { throw 'Artifact binary is missing.' }
$binarySha = (Get-FileHash -Algorithm SHA256 -LiteralPath $binaryPath).Hash.ToLowerInvariant()

$opsDir = Join-Path $extractDir 'company-ops'
$opsManifestPath = Join-Path $opsDir 'SHA256SUMS'
$requiredOps = @(
    'company-deploy-egress',
    'company-verify-egress',
    'company-route',
    'company-route-add'
    'companyctl'
)
if (-not (Test-Path -LiteralPath $opsManifestPath -PathType Leaf)) {
    throw 'Company operations SHA256SUMS is missing.'
}
$actualOpsFiles = @(
    Get-ChildItem -LiteralPath $opsDir |
        ForEach-Object Name |
        Sort-Object
)
$expectedOpsFiles = @($requiredOps + 'SHA256SUMS' | Sort-Object)
if (Compare-Object -ReferenceObject $expectedOpsFiles -DifferenceObject $actualOpsFiles) {
    throw 'Company operations artifact contains missing or unexpected files.'
}
$manifestEntries = @{}
foreach ($line in Get-Content -LiteralPath $opsManifestPath) {
    if ($line -notmatch '^([0-9a-f]{64})  ([a-z0-9-]+)$') {
        throw "Invalid operations manifest line: $line"
    }
    if ($manifestEntries.ContainsKey($Matches[2])) {
        throw "Duplicate operations manifest entry: $($Matches[2])"
    }
    $manifestEntries[$Matches[2]] = $Matches[1]
}
if ($manifestEntries.Count -ne $requiredOps.Count) {
    throw 'Operations manifest entry count is invalid.'
}
foreach ($name in $requiredOps) {
    if (-not $manifestEntries.ContainsKey($name)) {
        throw "Operations manifest is missing $name"
    }
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $opsDir $name)).Hash.ToLowerInvariant()
    if ($actualHash -ne $manifestEntries[$name]) {
        throw "Operations file hash mismatch: $name"
    }
}
$opsManifestSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $opsManifestPath).Hash.ToLowerInvariant()

$ubuntuTempBranch = 'company/upgrade-ubuntu22-{0}-{1}' -f $companyCommit.Substring(0, 12), [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$ubuntuCommit = $null
$ubuntuChecks = $null
$ubuntuBinaryPath = $null
$ubuntuBinarySha = $null
$ubuntuOpsDir = $null
$ubuntuOpsManifestSha = $null
try {
    Invoke-Checked git @('fetch', 'origin', ('{0}:refs/remotes/origin/{0}' -f $ubuntuBranch))
    & git show-ref --verify --quiet "refs/heads/$ubuntuBranch"
    if ($LASTEXITCODE -ne 0) {
        Invoke-Checked git @('branch', '--track', $ubuntuBranch, "origin/$ubuntuBranch")
    }
    Invoke-Checked git @('switch', '-c', $ubuntuTempBranch, "origin/$ubuntuBranch")
    Invoke-Checked git @('merge', '--no-edit', $tempBranch)
    Invoke-Checked $python @('tools/check_company_egress_guard.py')
    $ubuntuCommit = Get-CheckedOutput git @('rev-parse', 'HEAD')
    Invoke-Checked git @('push', 'origin', $ubuntuTempBranch)
    $ubuntuChecks = Wait-CompanyChecks -Branch $ubuntuTempBranch -Commit $ubuntuCommit

    $ubuntuArtifacts = Invoke-RestMethod -Headers $headers -Uri "$repoApi/actions/runs/$($ubuntuChecks.CI.id)/artifacts?per_page=100"
    $ubuntuArtifactName = "sub2api-linux-amd64-$ubuntuCommit"
    $ubuntuArtifact = $ubuntuArtifacts.artifacts |
        Where-Object { $_.name -eq $ubuntuArtifactName -and -not $_.expired } |
        Select-Object -First 1
    if (-not $ubuntuArtifact) {
        throw "Verified Ubuntu 22.04 artifact not found: $ubuntuArtifactName"
    }
    $ubuntuZipPath = Join-Path $distDir "$ubuntuArtifactName.zip"
    $ubuntuExtractDir = Join-Path $distDir $ubuntuArtifactName
    Invoke-WebRequest -Headers $headers -Uri $ubuntuArtifact.archive_download_url -OutFile $ubuntuZipPath -MaximumRedirection 5
    Clear-ArtifactExtractDirectory -Path $ubuntuExtractDir -Root $distDir
    Expand-Archive -LiteralPath $ubuntuZipPath -DestinationPath $ubuntuExtractDir
    $ubuntuBinaryPath = Join-Path $ubuntuExtractDir 'sub2api-linux-amd64'
    if (-not (Test-Path -LiteralPath $ubuntuBinaryPath -PathType Leaf)) {
        throw 'Ubuntu 22.04 artifact binary is missing.'
    }
    $ubuntuBinarySha = (Get-FileHash -Algorithm SHA256 -LiteralPath $ubuntuBinaryPath).Hash.ToLowerInvariant()
    $ubuntuOpsDir = Join-Path $ubuntuExtractDir 'company-ops'
    $ubuntuOpsManifestPath = Join-Path $ubuntuOpsDir 'SHA256SUMS'
    if (-not (Test-Path -LiteralPath $ubuntuOpsManifestPath -PathType Leaf)) {
        throw 'Ubuntu 22.04 operations SHA256SUMS is missing.'
    }
    $ubuntuActualOpsFiles = @(Get-ChildItem -LiteralPath $ubuntuOpsDir | ForEach-Object Name | Sort-Object)
    if (Compare-Object -ReferenceObject $expectedOpsFiles -DifferenceObject $ubuntuActualOpsFiles) {
        throw 'Ubuntu 22.04 operations artifact contains missing or unexpected files.'
    }
    $ubuntuManifestEntries = @{}
    foreach ($line in Get-Content -LiteralPath $ubuntuOpsManifestPath) {
        if ($line -notmatch '^([0-9a-f]{64})  ([a-z0-9-]+)$') {
            throw "Invalid Ubuntu 22.04 operations manifest line: $line"
        }
        if ($ubuntuManifestEntries.ContainsKey($Matches[2])) {
            throw "Duplicate Ubuntu 22.04 operations manifest entry: $($Matches[2])"
        }
        $ubuntuManifestEntries[$Matches[2]] = $Matches[1]
    }
    if ($ubuntuManifestEntries.Count -ne $requiredOps.Count) {
        throw 'Ubuntu 22.04 operations manifest entry count is invalid.'
    }
    foreach ($name in $requiredOps) {
        if (-not $ubuntuManifestEntries.ContainsKey($name)) {
            throw "Ubuntu 22.04 operations manifest is missing $name"
        }
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ubuntuOpsDir $name)).Hash.ToLowerInvariant()
        if ($actualHash -ne $ubuntuManifestEntries[$name]) {
            throw "Ubuntu 22.04 operations file hash mismatch: $name"
        }
    }
    $ubuntuOpsManifestSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $ubuntuOpsManifestPath).Hash.ToLowerInvariant()
}
catch {
    Write-Warning "Ubuntu 22.04 verification stopped safely on $ubuntuTempBranch; official branches were not changed."
    throw
}

# Publish the three verified commit IDs explicitly. Never publish an
# unverified local branch tip; the atomic non-force push also rejects races.
try {
    Invoke-Checked git @(
        'push', '--atomic', 'origin',
        ('{0}:refs/heads/main' -f $targetSha),
        ('{0}:refs/heads/{1}' -f $companyCommit, $companyBranch),
        ('{0}:refs/heads/{1}' -f $ubuntuCommit, $ubuntuBranch)
    )
}
catch {
    Write-Warning "Verified upgrades remain recoverable on $tempBranch and $ubuntuTempBranch; no force push or reset was performed."
    throw
}

# Keep local official branches aligned, but never misreport a completed remote
# publication if a local checkout cannot be refreshed.
try {
    Invoke-Checked git @('switch', 'main')
    Invoke-Checked git @('merge', '--ff-only', $targetSha)
    Invoke-Checked git @('switch', $companyBranch)
    Invoke-Checked git @('merge', '--ff-only', $tempBranch)
    Invoke-Checked git @('switch', $ubuntuBranch)
    Invoke-Checked git @('merge', '--ff-only', $ubuntuTempBranch)
    Invoke-Checked git @('switch', $companyBranch)
}
catch {
    Write-Warning 'Remote publication succeeded, but one or more local official branches need a manual fast-forward.'
}

# Delete a local temporary ref only after proving the corresponding official
# local branch contains it. Remote cleanup is safe after the verified atomic
# publication and is best-effort.
foreach ($pair in @(
    @($tempBranch, $companyBranch),
    @($ubuntuTempBranch, $ubuntuBranch)
)) {
    & git merge-base --is-ancestor $pair[0] $pair[1]
    if ($LASTEXITCODE -eq 0) {
        & git branch -D $pair[0]
    }
    else {
        Write-Warning "Verified temporary local branch $($pair[0]) was retained because $($pair[1]) is not synchronized."
    }
}
& git push origin --delete $tempBranch $ubuntuTempBranch
if ($LASTEXITCODE -ne 0) {
    Write-Warning 'Verified temporary remote branches could not be removed; official refs remain valid.'
}

$manifest = [ordered]@{
    company_commit  = $companyCommit
    upstream_commit = $targetSha
    binary_sha256   = $binarySha
    binary_path     = $binaryPath
    ops_path        = $opsDir
    ops_sha256      = $opsManifestSha
    ci_url          = $ciRun.html_url
    security_url    = $securityRun.html_url
    ubuntu22_commit = $ubuntuCommit
    ubuntu22_binary_path = $ubuntuBinaryPath
    ubuntu22_binary_sha256 = $ubuntuBinarySha
    ubuntu22_ops_path = $ubuntuOpsDir
    ubuntu22_ops_sha256 = $ubuntuOpsManifestSha
    ubuntu22_ci_url = $ubuntuChecks.CI.html_url
    ubuntu22_security_url = $ubuntuChecks.Security.html_url
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $distDir 'latest.json') -Encoding utf8
Write-Host "Company repository updated: $companyCommit"
Write-Host "Verified Linux website binary: $binaryPath"
Write-Host "SHA256: $binarySha"
Write-Host "Verified Company operations: $opsDir"
Write-Host "Operations manifest SHA256: $opsManifestSha"
Write-Host "Ubuntu 22.04 branch verified and updated: $ubuntuCommit"
Write-Host "Ubuntu 22.04 binary: $ubuntuBinaryPath"
Write-Host "Ubuntu 22.04 SHA256: $ubuntuBinarySha"
Write-Host 'No server operation was performed.'
