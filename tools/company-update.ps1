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
$deadline = [DateTimeOffset]::UtcNow.AddMinutes(30)
$encodedBranch = [Uri]::EscapeDataString($tempBranch)
$ciRun = $null
$securityRun = $null
while ([DateTimeOffset]::UtcNow -lt $deadline) {
    $runs = Invoke-RestMethod -Headers $headers -Uri "$repoApi/actions/runs?branch=$encodedBranch&per_page=20"
    $matching = @($runs.workflow_runs | Where-Object { $_.head_sha -eq $companyCommit })
    $ciRun = $matching | Where-Object { $_.name -eq 'CI' } | Select-Object -First 1
    $securityRun = $matching | Where-Object { $_.name -eq 'Security Scan' } | Select-Object -First 1
    if ($ciRun -and $securityRun -and $ciRun.status -eq 'completed' -and $securityRun.status -eq 'completed') { break }
    Start-Sleep -Seconds 15
}
if (-not $ciRun -or $ciRun.status -ne 'completed' -or $ciRun.conclusion -ne 'success') {
    throw "CI did not complete successfully; inspect remote branch $tempBranch."
}
if (-not $securityRun -or $securityRun.status -ne 'completed' -or $securityRun.conclusion -ne 'success') {
    throw "Security Scan did not complete successfully; inspect remote branch $tempBranch."
}

$artifacts = Invoke-RestMethod -Headers $headers -Uri "$repoApi/actions/runs/$($ciRun.id)/artifacts?per_page=100"
$artifactName = "sub2api-linux-amd64-$companyCommit"
$artifact = $artifacts.artifacts | Where-Object { $_.name -eq $artifactName -and -not $_.expired } | Select-Object -First 1
if (-not $artifact) { throw "Verified embedded-site artifact not found: $artifactName" }

$distDir = Join-Path $repoRoot 'dist/company'
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
$zipPath = Join-Path $distDir "$artifactName.zip"
$extractDir = Join-Path $distDir $artifactName
# Invoke-WebRequest does not preserve Authorization on a cross-host redirect
# unless -PreserveAuthorizationOnRedirect is explicitly supplied. Follow the
# GitHub -> temporary blob redirect without forwarding the GitHub credential.
Invoke-WebRequest -Headers $headers -Uri $artifact.archive_download_url -OutFile $zipPath -MaximumRedirection 5
if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
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

try {
    Invoke-Checked git @('switch', 'main')
    Invoke-Checked git @('merge', '--ff-only', $targetSha)
    Invoke-Checked git @('switch', 'company/egress-v1')
    Invoke-Checked git @('merge', '--ff-only', $tempBranch)
    Invoke-Checked git @('push', '--atomic', 'origin', 'main', 'company/egress-v1')
    Invoke-Checked git @('branch', '-d', $tempBranch)
    Invoke-Checked git @('push', 'origin', '--delete', $tempBranch)
}
catch {
    Write-Warning "Verified upgrade remains recoverable on $tempBranch; no force push or reset was performed."
    throw
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
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $distDir 'latest.json') -Encoding utf8
Write-Host "Company repository updated: $companyCommit"
Write-Host "Verified Linux website binary: $binaryPath"
Write-Host "SHA256: $binarySha"
Write-Host "Verified Company operations: $opsDir"
Write-Host "Operations manifest SHA256: $opsManifestSha"
Write-Host 'No server operation was performed.'
