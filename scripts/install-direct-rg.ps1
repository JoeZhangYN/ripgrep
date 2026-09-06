[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Binary,
    [string] $Target = '',
    [string] $Receipt = ''
)

$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $Binary -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "source binary is not a file: $source"
}
if ([string]::IsNullOrWhiteSpace($Target)) {
    $Target = (Get-Command rg -ErrorAction Stop).Source
}
$targetPath = (Resolve-Path -LiteralPath $Target -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    throw "target binary is not a file: $targetPath"
}
if ([StringComparer]::OrdinalIgnoreCase.Equals($source, $targetPath)) {
    throw 'source and target must be distinct files'
}

$sourceDigest = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
$targetDigest = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
$backupPath = "$targetPath.native-backup"
$previousBackupPath = $null
$effect = $false
$terminal = 'AlreadyCurrent'

if ($sourceDigest -ne $targetDigest) {
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        $suffix = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
        $previousBackupPath = "$targetPath.native-backup.previous-$suffix"
        Copy-Item -LiteralPath $backupPath -Destination $previousBackupPath -Force
    }
    Copy-Item -LiteralPath $targetPath -Destination $backupPath -Force
    Copy-Item -LiteralPath $source -Destination $targetPath -Force
    $effect = $true
    $terminal = 'Current'
}

$readbackDigest = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($readbackDigest -ne $sourceDigest) {
    throw "target digest readback differs from source: expected $sourceDigest, observed $readbackDigest"
}

$receiptObject = [ordered]@{
    schema = 'ripgrep.personal-direct-install-receipt.v1'
    source = $source
    source_digest_sha256 = $sourceDigest
    target = $targetPath
    target_digest_sha256 = $readbackDigest
    backup = if (Test-Path -LiteralPath $backupPath -PathType Leaf) { $backupPath } else { $null }
    previous_backup = $previousBackupPath
    terminal = $terminal
    effect = $effect
    write = $effect
    current = $true
    semantic_current = $false
    publish = $false
    retire = $false
    goal = $false
    freshness = 'freshness.ripgrep.personal-direct-install.v1'
    invalidation = 'invalidation.ripgrep.personal-direct-install-source-or-target-digest.v1'
    FirstMismatch = $null
    NextBoundedQuery = $null
    ParentJoinTarget = '/root'
    retention = 'DurableUntilParentConsumption'
}
$json = $receiptObject | ConvertTo-Json -Depth 8
if (-not [string]::IsNullOrWhiteSpace($Receipt)) {
    $receiptParent = Split-Path -Parent $Receipt
    New-Item -ItemType Directory -Force -Path $receiptParent | Out-Null
    $json | Set-Content -LiteralPath $Receipt -Encoding utf8
    (Get-FileHash -LiteralPath $Receipt -Algorithm SHA256).Hash.ToLowerInvariant() |
        Set-Content -LiteralPath ($Receipt + '.sha256') -Encoding ascii
}
Write-Output $json
