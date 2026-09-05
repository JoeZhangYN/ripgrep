[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Source,
    [Parameter(Mandatory = $true)]
    [string[]] $Target,
    [Parameter(Mandatory = $true)]
    [string] $BackupDirectory,
    [Parameter(Mandatory = $true)]
    [string] $Receipt,
    [Parameter(Mandatory = $true)]
    [string] $Revision
)

$ErrorActionPreference = 'Stop'

function Get-AbsoluteFile([string] $Path) {
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path
    if (-not $item.PSIsContainer -and $item.Exists) {
        return $item
    }
    throw "expected an existing file: $Path"
}

$sourceItem = Get-AbsoluteFile $Source
$sourcePath = $sourceItem.FullName
$sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($Target.Count -eq 0) { throw 'at least one target is required' }
if ([string]::IsNullOrWhiteSpace($Revision)) { throw 'revision is required' }

New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Receipt) | Out-Null
$backupRoot = (Resolve-Path -LiteralPath $BackupDirectory).Path
$readbacks = @()
$backups = @()

foreach ($targetValue in $Target) {
    $targetItem = Get-AbsoluteFile $targetValue
    $targetPath = $targetItem.FullName
    if ([IO.Path]::GetFileName($targetPath) -ne 'rg.exe') {
        throw "target is not an exact rg.exe path: $targetPath"
    }
    if ($targetPath -eq $sourcePath) {
        throw "source and target must be distinct: $targetPath"
    }

    $targetKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($targetPath))).ToLowerInvariant().Substring(0, 16)
    $backupPath = Join-Path $backupRoot ("rg.exe.personal-before-$targetKey.exe")
    Copy-Item -LiteralPath $targetPath -Destination $backupPath -Force
    $tempPath = "$targetPath.personal-install-$PID.tmp"
    try {
        Copy-Item -LiteralPath $sourcePath -Destination $tempPath -Force
        Move-Item -LiteralPath $tempPath -Destination $targetPath -Force
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    }

    $installedItem = Get-AbsoluteFile $targetPath
    $installedHash = (Get-FileHash -LiteralPath $installedItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $readbacks += [ordered]@{
        target = $installedItem.FullName
        source_digest_sha256 = $sourceHash
        installed_digest_sha256 = $installedHash
        matching = ($installedHash -eq $sourceHash)
        length = $installedItem.Length
    }
    $backups += $backupPath
}

$receiptObject = [ordered]@{
    schema = 'ripgrep.personal-native-install-receipt.v1'
    revision = $Revision
    source = $sourcePath
    source_digest_sha256 = $sourceHash
    targets = $readbacks
    backups = $backups
    effect = $true
    current = $false
    semantic_current = $false
    status = 'Candidate'
    freshness = 'freshness.ripgrep.personal-native-install.v1'
    invalidation = 'invalidation.ripgrep.personal-native-commit.v1'
    reader_zero = 'Unknown'
    writer_zero = 'Unknown'
    route_zero = 'Unknown'
    retention = 'DurableUntilParentConsumption'
}
$receiptObject | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Receipt -Encoding UTF8
Write-Output ($receiptObject | ConvertTo-Json -Depth 8)
