[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$UpstreamRef,

    [string]$SshTarget,

    [switch]$Deploy,

    [switch]$DatabaseBackupConfirmed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE"
    }
}

function Get-CheckedOutput {
    param([string]$Command, [string[]]$Arguments)
    $output = & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE"
    }
    return ($output | Out-String).Trim()
}

$repoRoot = Get-CheckedOutput git @('rev-parse', '--show-toplevel')
Set-Location -LiteralPath $repoRoot

if ((Get-CheckedOutput git @('branch', '--show-current')) -ne 'company/egress-v1') {
    throw 'Switch to company/egress-v1 first.'
}
if ((Get-CheckedOutput git @('status', '--porcelain')) -ne '') {
    throw 'Worktree must be clean.'
}
if ((Get-CheckedOutput git @('remote', 'get-url', '--push', 'upstream')) -ne 'DISABLED') {
    throw 'upstream push URL must be DISABLED.'
}

Invoke-Checked git @('fetch', 'upstream', '--tags')
$targetSha = Get-CheckedOutput git @('rev-parse', '--verify', "$UpstreamRef`^{commit}")
$baseline = 'e8cb019fabf8b55199436229044cbf9aa7a82564'
& git merge-base --is-ancestor $baseline $targetSha
if ($LASTEXITCODE -ne 0) {
    throw 'Target is not a descendant of the frozen Company V1 baseline.'
}

$tempBranch = 'company/upgrade-{0}-{1}' -f $targetSha.Substring(0, 12), [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$upgradeCompleted = $false
try {
    Invoke-Checked git @('switch', '-c', $tempBranch)
    Invoke-Checked git @('merge', '--no-edit', $targetSha)
    Invoke-Checked python @('tools/check_company_egress_guard.py')

    $companyCommit = Get-CheckedOutput git @('rev-parse', 'HEAD')

    Invoke-Checked git @('switch', 'main')
    Invoke-Checked git @('merge', '--ff-only', $targetSha)
    Invoke-Checked git @('switch', 'company/egress-v1')
    Invoke-Checked git @('merge', '--ff-only', $tempBranch)
    Invoke-Checked git @('branch', '-d', $tempBranch)
    Invoke-Checked git @('push', '--atomic', 'origin', 'main', 'company/egress-v1')
    $upgradeCompleted = $true
}
finally {
    if (-not $upgradeCompleted) {
        Write-Warning 'Upgrade stopped without force push or automatic reset. Inspect the current temporary branch.'
    }
}

$credentialLines = "protocol=https`nhost=github.com`n`n" | git credential fill
$credential = @{}
foreach ($line in $credentialLines) {
    $parts = $line -split '=', 2
    if ($parts.Count -eq 2) { $credential[$parts[0]] = $parts[1] }
}
if (-not $credential.ContainsKey('password')) {
    throw 'The current GitHub credential is unavailable; no PAT is requested or stored by this script.'
}
$headers = @{
    'Accept'        = 'application/vnd.github+json'
    'Authorization' = 'Bearer ' + $credential['password']
    'User-Agent'    = 'Sub2API-Company-Upgrade'
}

$repoApi = 'https://api.github.com/repos/Ye-0050101/sub2api-company'
$deadline = [DateTimeOffset]::UtcNow.AddMinutes(30)
$ciRun = $null
$securityRun = $null
while ([DateTimeOffset]::UtcNow -lt $deadline) {
    $runs = Invoke-RestMethod -Headers $headers -Uri "$repoApi/actions/runs?branch=company%2Fegress-v1&per_page=20"
    $matching = @($runs.workflow_runs | Where-Object { $_.head_sha -eq $companyCommit })
    $ciRun = $matching | Where-Object { $_.name -eq 'CI' } | Select-Object -First 1
    $securityRun = $matching | Where-Object { $_.name -eq 'Security Scan' } | Select-Object -First 1
    if ($ciRun -and $securityRun -and $ciRun.status -eq 'completed' -and $securityRun.status -eq 'completed') {
        break
    }
    Start-Sleep -Seconds 15
}
if (-not $ciRun -or $ciRun.status -ne 'completed' -or $ciRun.conclusion -ne 'success') {
    throw 'CI did not complete successfully; deployment was not attempted.'
}
if (-not $securityRun -or $securityRun.status -ne 'completed' -or $securityRun.conclusion -ne 'success') {
    throw 'Security Scan did not complete successfully; deployment was not attempted.'
}

Write-Host "Verified CI and Security Scan for $companyCommit"
if (-not $Deploy) {
    Write-Host 'Source upgrade complete. Re-run with -Deploy after confirming a database backup.'
    exit 0
}
if (-not $DatabaseBackupConfirmed) {
    throw '-DatabaseBackupConfirmed is required for deployment.'
}
if ([string]::IsNullOrWhiteSpace($SshTarget)) {
    throw '-SshTarget is required for deployment.'
}

$artifacts = Invoke-RestMethod -Headers $headers -Uri "$repoApi/actions/runs/$($ciRun.id)/artifacts?per_page=100"
$artifactName = "sub2api-linux-amd64-$companyCommit"
$artifact = $artifacts.artifacts | Where-Object { $_.name -eq $artifactName -and -not $_.expired } | Select-Object -First 1
if (-not $artifact) {
    throw "Verified binary artifact not found: $artifactName"
}

$distDir = Join-Path $repoRoot 'dist/company'
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
$zipPath = Join-Path $distDir "$artifactName.zip"
$extractDir = Join-Path $distDir $artifactName
$redirect = Invoke-WebRequest -Headers $headers -Uri $artifact.archive_download_url -MaximumRedirection 0 -SkipHttpErrorCheck
if ($redirect.StatusCode -notin 301, 302, 303, 307, 308 -or -not $redirect.Headers.Location) {
    throw 'GitHub did not return a temporary artifact download URL.'
}
Invoke-WebRequest -Uri $redirect.Headers.Location -OutFile $zipPath
if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir
$binaryPath = Join-Path $extractDir 'sub2api-linux-amd64'
if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
    throw 'Downloaded artifact does not contain sub2api-linux-amd64.'
}
$binarySha = (Get-FileHash -Algorithm SHA256 -LiteralPath $binaryPath).Hash.ToLowerInvariant()

$remoteBinary = "/tmp/sub2api-company-$companyCommit"
$remoteDeploy = '/tmp/company-deploy-egress.sh'
$remoteVerify = '/tmp/company-verify-egress.sh'
Invoke-Checked scp @($binaryPath, "$SshTarget`:$remoteBinary")
Invoke-Checked scp @((Join-Path $repoRoot 'deploy/company-deploy-egress.sh'), "$SshTarget`:$remoteDeploy")
Invoke-Checked scp @((Join-Path $repoRoot 'deploy/company-verify-egress.sh'), "$SshTarget`:$remoteVerify")
Invoke-Checked ssh @($SshTarget, 'bash', $remoteDeploy, '--binary', $remoteBinary, '--sha256', $binarySha, '--db-backup-confirmed')
Invoke-Checked ssh @($SshTarget, 'bash', $remoteVerify, '--sha256', $binarySha)

Write-Host "Deployment complete: $companyCommit ($binarySha)"
