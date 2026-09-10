[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$HostName,
    [string]$UserName = 'hsaiapi',
    [ValidateSet('ubuntu22', 'ubuntu24')]
    [string]$Target = 'ubuntu22',
    [string]$ManifestPath = 'dist/company/latest.json',
    [ValidateRange(1, 65535)]
    [int]$Port = 22,
    [switch]$Deploy
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

function Get-ManifestValue {
    param([object]$Manifest, [string]$Name)
    $property = $Manifest.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Release manifest is missing $Name"
    }
    return [string]$property.Value
}

function Assert-HexValue {
    param([string]$Value, [int]$Length, [string]$Name)
    if ($Value -notmatch "^[0-9a-f]{$Length}$") {
        throw "$Name must be $Length lowercase hexadecimal characters"
    }
}

function Resolve-ReleasePath {
    param([string]$Path, [string]$DistRoot, [string]$Name)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $prefix = $DistRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name must stay inside the verified dist/company directory"
    }
    return $resolved
}

if (-not $Deploy) {
    throw 'No server change was requested. Supply -Deploy explicitly after selecting the maintenance window.'
}
if ($UserName -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { throw 'UserName contains unsafe characters' }
if ($HostName -notmatch '^[A-Za-z0-9.-]{1,253}$' -or $HostName.StartsWith('.') -or $HostName.EndsWith('.')) {
    throw 'HostName must be a literal IPv4 address or a plain DNS name'
}
foreach ($command in ('git', 'scp', 'ssh')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "$command is required" }
}

$repoRoot = Get-CheckedOutput git @('rev-parse', '--show-toplevel')
Set-Location -LiteralPath $repoRoot
$distRoot = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'dist/company')).Path
$manifestCandidate = if ([IO.Path]::IsPathRooted($ManifestPath)) {
    $ManifestPath
} else {
    Join-Path $repoRoot $ManifestPath
}
$manifestFile = Resolve-ReleasePath $manifestCandidate $distRoot 'ManifestPath'
$manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json

$repoCompanyVersion = (Get-Content -LiteralPath (Join-Path $repoRoot 'COMPANY_VERSION') -Raw).Trim()
$companyVersion = if ($null -ne $manifest.PSObject.Properties['company_version']) {
    [string]$manifest.company_version
} else {
    $repoCompanyVersion
}
if ($companyVersion -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
    throw 'Company version must be major.minor.patch'
}
if ($companyVersion -ne $repoCompanyVersion) {
    throw 'latest.json does not belong to the current Company source version'
}

if ($Target -eq 'ubuntu22') {
    $commit = Get-ManifestValue $manifest 'ubuntu22_commit'
    $binaryPath = Get-ManifestValue $manifest 'ubuntu22_binary_path'
    $expectedBinarySha = Get-ManifestValue $manifest 'ubuntu22_binary_sha256'
    $opsPath = Get-ManifestValue $manifest 'ubuntu22_ops_path'
    $expectedOpsSha = Get-ManifestValue $manifest 'ubuntu22_ops_sha256'
    $expectedOSVersion = '22.04'
} else {
    $commit = Get-ManifestValue $manifest 'company_commit'
    $binaryPath = Get-ManifestValue $manifest 'binary_path'
    $expectedBinarySha = Get-ManifestValue $manifest 'binary_sha256'
    $opsPath = Get-ManifestValue $manifest 'ops_path'
    $expectedOpsSha = Get-ManifestValue $manifest 'ops_sha256'
    $expectedOSVersion = '24.04'
}
Assert-HexValue $commit 40 'commit'
Assert-HexValue $expectedBinarySha 64 'binary SHA256'
Assert-HexValue $expectedOpsSha 64 'operations manifest SHA256'

$binary = Resolve-ReleasePath $binaryPath $distRoot 'binary_path'
$ops = Resolve-ReleasePath $opsPath $distRoot 'ops_path'
$extractDirectory = Split-Path -Parent $binary
if ((Split-Path -Parent $ops) -ne $extractDirectory -or (Split-Path -Leaf $ops) -ne 'company-ops') {
    throw 'Binary and company-ops must come from the same extracted artifact'
}
if ((Split-Path -Leaf $binary) -ne 'sub2api-linux-amd64') { throw 'Unexpected binary name' }
$artifactZip = Resolve-ReleasePath ($extractDirectory + '.zip') $distRoot 'artifact zip'

$actualBinarySha = (Get-FileHash -Algorithm SHA256 -LiteralPath $binary).Hash.ToLowerInvariant()
if ($actualBinarySha -ne $expectedBinarySha) { throw 'Binary SHA256 does not match latest.json' }
$opsManifest = Join-Path $ops 'SHA256SUMS'
$actualOpsSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $opsManifest).Hash.ToLowerInvariant()
if ($actualOpsSha -ne $expectedOpsSha) { throw 'Operations manifest SHA256 does not match latest.json' }

$requiredOps = @('company-deploy-egress', 'company-verify-egress', 'company-route', 'company-route-add', 'companyctl')
$actualFiles = @(Get-ChildItem -LiteralPath $ops | ForEach-Object Name | Sort-Object)
$expectedFiles = @($requiredOps + 'SHA256SUMS' | Sort-Object)
if (Compare-Object -ReferenceObject $expectedFiles -DifferenceObject $actualFiles) {
    throw 'company-ops contains missing or unexpected files'
}
$entries = @{}
foreach ($line in Get-Content -LiteralPath $opsManifest) {
    if ($line -notmatch '^([0-9a-f]{64})  ([a-z0-9-]+)$') { throw "Invalid operations manifest line: $line" }
    if ($entries.ContainsKey($Matches[2])) { throw "Duplicate operations manifest entry: $($Matches[2])" }
    $entries[$Matches[2]] = $Matches[1]
}
foreach ($name in $requiredOps) {
    if (-not $entries.ContainsKey($name)) { throw "Operations manifest is missing $name" }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ops $name)).Hash.ToLowerInvariant()
    if ($hash -ne $entries[$name]) { throw "Operations file hash mismatch: $name" }
}

$archiveSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactZip).Hash.ToLowerInvariant()
$shortCommit = $commit.Substring(0, 12)
$timestamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$remoteHome = "/home/$UserName"
$remoteArchive = "$remoteHome/.company-release-$shortCommit-$timestamp.zip"
$remoteRelease = "$remoteHome/release-v$companyVersion-$shortCommit-$timestamp"
$destination = "$UserName@$HostName"

$remoteTemplate = @'
set -Eeuo pipefail
archive='__ARCHIVE__'
release='__RELEASE__'
expected_archive_sha='__ARCHIVE_SHA__'
expected_binary_sha='__BINARY_SHA__'
expected_ops_sha='__OPS_SHA__'
expected_os='ubuntu:__OS_VERSION__'
nginx_was_active=0

cleanup_archive() { rm -f -- "$archive"; }
restore_ingress() {
  if [[ $nginx_was_active -eq 1 ]]; then
    sudo systemctl start nginx.service >/dev/null 2>&1 || true
    nginx_was_active=0
  fi
}
trap 'restore_ingress; cleanup_archive' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sudo -v
test -f "$archive"
test "$(sha256sum "$archive" | awk '{print $1}')" = "$expected_archive_sha"
test ! -e "$release"
install -d -m 0700 "$release"
python3 -m zipfile -e "$archive" "$release"
chmod 0755 \
  "$release/sub2api-linux-amd64" \
  "$release/company-ops/company-deploy-egress" \
  "$release/company-ops/company-verify-egress" \
  "$release/company-ops/company-route" \
  "$release/company-ops/company-route-add" \
  "$release/company-ops/companyctl"
test "$(sha256sum "$release/sub2api-linux-amd64" | awk '{print $1}')" = "$expected_binary_sha"
test "$(sha256sum "$release/company-ops/SHA256SUMS" | awk '{print $1}')" = "$expected_ops_sha"
(cd "$release/company-ops" && sha256sum --strict -c SHA256SUMS)
. /etc/os-release
test "$ID:$VERSION_ID" = "$expected_os"

sudo companyctl account audit
if ! sudo companyctl verify >"$release/precheck.log" 2>&1; then
  tail -n 60 "$release/precheck.log"
  echo 'COMPANY_SERVER_PRECHECK_FAILED' >&2
  exit 1
fi
echo 'COMPANY_SERVER_PRECHECK_PASS'

if sudo systemctl is-active --quiet nginx.service; then
  nginx_was_active=1
  sudo systemctl stop nginx.service
fi
sudo bash "$release/company-ops/company-deploy-egress" \
  --binary "$release/sub2api-linux-amd64" \
  --sha256 "$expected_binary_sha" \
  --ops-dir "$release/company-ops" \
  --ops-sha256 "$expected_ops_sha"
restore_ingress

sudo /opt/sub2api/sub2api -version
curl --noproxy '*' -fsS --max-time 5 http://127.0.0.1:8080/health
echo
sudo companyctl account audit
if ! sudo companyctl verify --sha256 "$expected_binary_sha" >"$release/verify.log" 2>&1; then
  tail -n 80 "$release/verify.log"
  echo 'COMPANY_SERVER_VERIFY_FAILED' >&2
  exit 1
fi
echo 'COMPANY_SERVER_VERIFY_PASS'
echo "COMPANY_SERVER_DEPLOY_READY release=$release"
'@

$remoteScript = $remoteTemplate.Replace('__ARCHIVE__', $remoteArchive).
    Replace('__RELEASE__', $remoteRelease).
    Replace('__ARCHIVE_SHA__', $archiveSha).
    Replace('__BINARY_SHA__', $expectedBinarySha).
    Replace('__OPS_SHA__', $expectedOpsSha).
    Replace('__OS_VERSION__', $expectedOSVersion)
$encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScript))
$remoteCommand = "printf '%s' '$encodedScript' | base64 -d | bash"

Write-Host "Validated Company v$companyVersion target=$Target commit=$commit"
Write-Host "Uploading the already verified artifact to $destination..."
Invoke-Checked scp @('-P', [string]$Port, $artifactZip, ($destination + ':' + $remoteArchive))
Write-Host 'Starting the maintenance-window deployment; the server will create its own verified database backup.'
Invoke-Checked ssh @('-tt', '-p', [string]$Port, $destination, $remoteCommand)
Write-Host "Company server deployment completed: $destination Company v$companyVersion"
