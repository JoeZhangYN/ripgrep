[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $Binary = '',
    [string] $Receipt = ''
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if ([string]::IsNullOrWhiteSpace($Binary)) {
    $Binary = Join-Path $RepositoryRoot 'target\release\rg.exe'
}
$Binary = (Resolve-Path -LiteralPath $Binary).Path
if ([string]::IsNullOrWhiteSpace($Receipt)) {
    $Receipt = Join-Path $RepositoryRoot '.codex\tmp\personal-rg-windows-fixture\result.json'
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Receipt) | Out-Null

$fixture = Join-Path (Split-Path -Parent $Receipt) 'fixture'
New-Item -ItemType Directory -Force -Path $fixture | Out-Null
Set-Content -LiteralPath (Join-Path $fixture 'a.txt') -Encoding utf8 -Value @('foo alpha', 'none', 'bar beta')
Set-Content -LiteralPath (Join-Path $fixture 'b.txt') -Encoding utf8 -Value @('none', 'foo gamma')
$glob = Join-Path $fixture '*.txt'

$sourceRevision = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceRevision)) {
    throw 'cannot read source git revision'
}
$binaryHash = (Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash.ToLowerInvariant()

function Invoke-Rg([string[]] $Arguments) {
    $output = (& $Binary @Arguments 2>&1 | Out-String)
    [pscustomobject]@{ output = $output; exit_code = $LASTEXITCODE }
}

$default = Invoke-Rg @('-n', 'foo|bar', $glob)
$noHeading = Invoke-Rg @('--no-heading', '-n', 'foo|bar', $glob)
$smartCase = Invoke-Rg @('-S', '-n', 'foo|bar', $fixture)
$files = Invoke-Rg @('--files', $fixture)
$json = Invoke-Rg @('--json', '-n', '(foo|bar.*)', $glob)
if ($default.exit_code -ne 0 -or $noHeading.exit_code -ne 0 -or $smartCase.exit_code -ne 0 -or $files.exit_code -ne 0 -or $json.exit_code -ne 0) {
    throw "Windows fixture failed: default=$($default.exit_code), no-heading=$($noHeading.exit_code), smart-case=$($smartCase.exit_code), files=$($files.exit_code), json=$($json.exit_code)"
}

$defaultGrouped = $default.output -match '(?m)^.*[ab]\.txt\r?$'
$defaultRepeatedPrefix = $default.output -match '(?m)^.*[ab]\.txt:\d+:'
$noHeadingLines = @($noHeading.output -split '\r?\n' | Where-Object { $_ -match '^[^\r\n]*[ab]\.txt:\d+:' })
$smartCaseLines = @($smartCase.output -split '\r?\n' | Where-Object { $_ -match '^\d+:' })
$fileLines = @($files.output -split '\r?\n' | Where-Object { $_ -match '[ab]\.txt$' })
$jsonRecords = @($json.output -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
if (-not $defaultGrouped -or $defaultRepeatedPrefix -or $noHeadingLines.Count -ne 3 -or $smartCaseLines.Count -ne 3 -or $fileLines.Count -ne 2 -or $jsonRecords.Count -ne 8) {
    throw 'Windows fixture output contract mismatch'
}

$receiptObject = [ordered]@{
    schema = 'ripgrep.personal-windows-runtime-fixture-receipt.v1'
    status = 'Candidate'
    terminal = 'Candidate'
    source_revision = $sourceRevision
    binary = $Binary
    binary_digest_sha256 = $binaryHash
    default_heading = [ordered]@{ exit_code = $default.exit_code; grouped_heading = $true; repeated_filename_prefix = $false; matched_lines = 3 }
    no_heading = [ordered]@{ exit_code = $noHeading.exit_code; file_line_text = $true; matched_lines = $noHeadingLines.Count }
    smart_case = [ordered]@{ exit_code = $smartCase.exit_code; matched_lines = $smartCaseLines.Count }
    files = [ordered]@{ exit_code = $files.exit_code; listed_files = $fileLines.Count }
    json = [ordered]@{ exit_code = $json.exit_code; records = $jsonRecords.Count; begin_match_end_summary = $true }
    path_selector = '*.txt'
    selector = '(foo|bar.*)'
    effect = $false
    write = $false
    current = $false
    semantic_current = $false
    publish = $false
    retire = $false
    material = $false
    goal = $false
    reader_zero = 'Unknown'
    writer_zero = 'Unknown'
    route_zero = 'Unknown'
    freshness = 'freshness.ripgrep.personal-windows-runtime-fixture.v1'
    invalidation = 'invalidation.ripgrep.personal-windows-binary-or-source-revision.v1'
    FirstMismatch = 'Programmatic Windows runtime fixture and output readback succeeded; canonical SemanticRuntimeJoin, external consumer/session proof and reader/writer/route-zero closure remain incomplete.'
    NextBoundedQuery = 'Join this receipt with Docker build/runtime and owner semantic receipts through a canonical read-only SemanticRuntimeJoin query.'
    ParentJoinTarget = '/root'
    retention = 'DurableUntilParentConsumption'
}
$receiptObject | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 -LiteralPath $Receipt
(Get-FileHash -LiteralPath $Receipt -Algorithm SHA256).Hash | Set-Content -Encoding ascii -LiteralPath ($Receipt + '.sha256')
Write-Output (Get-Content -Raw -LiteralPath $Receipt)
