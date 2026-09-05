[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $Image = 'rust:1.98.0-bookworm',
    [string] $ImageDigest = 'sha256:82150a52ec202c1b14d7817e14516c392bb7f5cfebd88f1ed531cb37ebd39922',
    [string] $Target = 'x86_64-unknown-linux-gnu',
    [string] $Receipt = ''
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if ([string]::IsNullOrWhiteSpace($Receipt)) {
    $Receipt = Join-Path $RepositoryRoot '.codex\tmp\personal-rg-linux-docker-fixture\result.json'
}
$receiptParent = Split-Path -Parent $Receipt
New-Item -ItemType Directory -Force -Path $receiptParent | Out-Null

$targetSlug = $Target -replace '[^A-Za-z0-9_.-]', '-'
$binary = Join-Path $RepositoryRoot ('target\docker-' + $targetSlug + '\' + $Target + '\release\rg')
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "missing Linux release binary: $binary; run build-personal-rg-linux-docker.ps1 first"
}

$inspect = & docker image inspect $Image --format '{{json .RepoDigests}}' 2>&1
if ($LASTEXITCODE -ne 0) { throw "Docker image is unavailable: $Image" }
$expectedDigest = "$Image`@$ImageDigest"
if ($inspect -notmatch [regex]::Escape($ImageDigest)) {
    throw "Docker image digest mismatch; expected $expectedDigest, observed $inspect"
}

$fixture = Join-Path $receiptParent 'fixture'
New-Item -ItemType Directory -Force -Path $fixture | Out-Null
Set-Content -LiteralPath (Join-Path $fixture 'a.txt') -Encoding utf8 -Value @('foo alpha', 'none', 'bar beta')
Set-Content -LiteralPath (Join-Path $fixture 'b.txt') -Encoding utf8 -Value @('none', 'foo gamma')

$sourceRevision = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceRevision)) {
    throw 'cannot read source git revision'
}
$binaryHash = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
$mountRepository = "$RepositoryRoot`:/src"
$mountFixture = "$fixture`:/fixture"
$binaryInContainer = '/src/target/docker-' + $targetSlug + '/' + $Target + '/release/rg'

function Invoke-Rg([string] $Arguments) {
    $command = "$binaryInContainer $Arguments"
    $output = (& docker run --rm -v $mountRepository -v $mountFixture -w /src $expectedDigest bash -c $command 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ output = $output; exit_code = $exitCode }
}

$default = Invoke-Rg "-n 'foo|bar' '/fixture/*.txt'"
$noHeading = Invoke-Rg "--no-heading -n 'foo|bar' '/fixture/*.txt'"
$json = Invoke-Rg "--json -n 'foo|bar' '/fixture/*.txt'"
if ($default.exit_code -ne 0 -or $noHeading.exit_code -ne 0 -or $json.exit_code -ne 0) {
    throw "Docker runtime fixture failed: default=$($default.exit_code), no-heading=$($noHeading.exit_code), json=$($json.exit_code)"
}

$defaultGrouped = $default.output -match '(?m)^/fixture/[ab]\.txt\r?$'
$defaultRepeatedPrefix = $default.output -match '(?m)^/fixture/[ab]\.txt:\d+:'
$noHeadingLines = @($noHeading.output -split '\r?\n' | Where-Object { $_ -match '^/fixture/[ab]\.txt:\d+:' })
$jsonRecords = @($json.output -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
if (-not $defaultGrouped -or $defaultRepeatedPrefix -or $noHeadingLines.Count -ne 3 -or $jsonRecords.Count -ne 8) {
    throw 'Docker runtime fixture output contract mismatch'
}

$receiptObject = [ordered]@{
    schema = 'ripgrep.personal-linux-docker-runtime-fixture-receipt.v1'
    status = 'Candidate'
    terminal = 'Candidate'
    image = $Image
    image_digest = $ImageDigest
    target = $Target
    source_revision = $sourceRevision
    binary = $binary
    binary_digest_sha256 = $binaryHash
    default_heading = [ordered]@{ exit_code = $default.exit_code; grouped_heading = $true; repeated_filename_prefix = $false; matched_lines = 3 }
    no_heading = [ordered]@{ exit_code = $noHeading.exit_code; file_line_text = $true; repeated_filename_prefix = $false; matched_lines = $noHeadingLines.Count }
    json = [ordered]@{ exit_code = $json.exit_code; records = $jsonRecords.Count; begin_match_end_summary = $true }
    path_selector = "quoted /fixture/*.txt"
    selector = 'foo|bar'
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
    freshness = 'freshness.ripgrep.personal-linux-docker-runtime-fixture.v1'
    invalidation = 'invalidation.ripgrep.personal-linux-docker-image-or-source-or-binary-revision.v1'
    FirstMismatch = 'Programmatic Docker runtime fixture and output readback succeeded; canonical SemanticRuntimeJoin, external consumer/session proof and reader/writer/route-zero closure remain incomplete.'
    NextBoundedQuery = 'Join this receipt with owner semantic, Windows install and Docker build receipts using a canonical read-only SemanticRuntimeJoin query.'
    ParentJoinTarget = '/root'
    retention = 'DurableUntilParentConsumption'
}
$receiptObject | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 -LiteralPath $Receipt
(Get-FileHash -LiteralPath $Receipt -Algorithm SHA256).Hash | Set-Content -Encoding ascii -LiteralPath ($Receipt + '.sha256')
Write-Output (Get-Content -Raw -LiteralPath $Receipt)
