[CmdletBinding()]
param(
    [string] $RepositoryRoot = '',
    [string] $Receipt = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RepositoryRoot = Join-Path $scriptRoot '..'
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if ([string]::IsNullOrWhiteSpace($Receipt)) {
    $Receipt = Join-Path $RepositoryRoot '.codex\tmp\rg-dogfood\result.json'
}
$receiptDir = Split-Path -Parent $Receipt
New-Item -ItemType Directory -Force -Path $receiptDir | Out-Null

$revision = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($revision)) {
    throw 'cannot read dogfood source revision'
}

& cargo build --manifest-path (Join-Path $RepositoryRoot 'Cargo.toml') --release --features personal-default-heading --bin rg
if ($LASTEXITCODE -ne 0) { throw 'personal release build failed' }
$windowsReceipt = Join-Path $receiptDir 'windows.json'
& (Join-Path $RepositoryRoot 'scripts\test-personal-rg-windows.ps1') -RepositoryRoot $RepositoryRoot -Binary (Join-Path $RepositoryRoot 'target\release\rg.exe') -Receipt $windowsReceipt | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Windows dogfood failed' }
$linuxReceipt = Join-Path $receiptDir 'linux.json'
& (Join-Path $RepositoryRoot 'scripts\test-personal-rg-linux-docker.ps1') -RepositoryRoot $RepositoryRoot -Receipt $linuxReceipt | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Linux Docker dogfood failed' }

$windows = Get-Content -Raw -LiteralPath $windowsReceipt | ConvertFrom-Json
$linux = Get-Content -Raw -LiteralPath $linuxReceipt | ConvertFrom-Json
$project = 'project.ripgrep.personal'
$partition = 'partition.personal-dogfood'
$runtimeEvidence = @(
    [ordered]@{
        gate_ref = 'runtime.dogfood'
        project = $project
        partition = $partition
        source_revision = $revision
        terminal = 'Candidate'
        source_receipts = @($windowsReceipt, $linuxReceipt)
    },
    [ordered]@{
        gate_ref = 'runtime.owner-admission'
        project = $project
        partition = $partition
        source_revision = $revision
        terminal = 'Unknown'
        first_mismatch = 'Owner admission receipt was not supplied by the dogfood runner.'
    },
    [ordered]@{
        gate_ref = 'runtime.consumer-session'
        project = $project
        partition = $partition
        source_revision = $revision
        terminal = 'Unknown'
        first_mismatch = 'External semantic-consumer session receipt was not supplied by the dogfood runner.'
    },
    [ordered]@{
        gate_ref = 'runtime.install-target'
        project = $project
        partition = $partition
        source_revision = $revision
        terminal = 'Unknown'
        first_mismatch = 'Installation target readback was not supplied by the dogfood runner.'
    }
)
$combined = [ordered]@{
    schema = 'ripgrep.personal-dogfood-receipt.v1'
    source_revision = $revision
    binary = (Join-Path $RepositoryRoot 'target\release\rg.exe')
    windows = $windows
    linux = $linux
    effect = $false
    current = $false
    semantic_current = $false
    publish = $false
    retire = $false
    goal = $false
    freshness = 'freshness.ripgrep.personal-dogfood.v1'
    invalidation = 'invalidation.ripgrep.personal-dogfood-source-or-binary-revision.v1'
    runtime_evidence = $runtimeEvidence
    FirstMismatch = 'Programmatic cross-platform dogfood passed; canonical semantic consumer, install target and Owner admission remain separate gates.'
    NextBoundedQuery = 'Join this receipt with semantic-storage durable revision, semantic-consumer ack, and installation target readback.'
    ParentJoinTarget = '/root'
    retention = 'DurableUntilParentConsumption'
}
$json = $combined | ConvertTo-Json -Depth 20
$json | Set-Content -LiteralPath $Receipt -Encoding utf8
(Get-FileHash -LiteralPath $Receipt -Algorithm SHA256).Hash | Set-Content -LiteralPath ($Receipt + '.sha256') -Encoding ascii
Write-Output $json
