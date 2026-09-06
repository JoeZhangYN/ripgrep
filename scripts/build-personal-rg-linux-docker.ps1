[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $Image = 'rust:1.98.0-bookworm',
    [string] $ImageDigest = 'sha256:82150a52ec202c1b14d7817e14516c392bb7f5cfebd88f1ed531cb37ebd39922',
    [string] $Target = 'x86_64-unknown-linux-gnu',
    [string] $RustToolchain = '1.98.1-x86_64-unknown-linux-gnu',
    [string] $Receipt = ''
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if ([string]::IsNullOrWhiteSpace($Receipt)) {
    $Receipt = Join-Path $RepositoryRoot '.codex\tmp\personal-rg-linux-docker-build\result.json'
}
$receiptParent = Split-Path -Parent $Receipt
New-Item -ItemType Directory -Force -Path $receiptParent | Out-Null
$targetSlug = $Target -replace '[^A-Za-z0-9_.-]', '-'
$targetRoot = Join-Path $RepositoryRoot ('target\docker-' + $targetSlug + '\' + $Target)
New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null

$inspect = & docker image inspect $Image --format '{{json .RepoDigests}}' 2>&1
if ($LASTEXITCODE -ne 0) { throw "Docker image is unavailable: $Image" }
$expectedDigest = "$Image`@$ImageDigest"
if ($inspect -notmatch [regex]::Escape($ImageDigest)) {
    throw "Docker image digest mismatch; expected $expectedDigest, observed $inspect"
}

$sourceRevision = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceRevision)) {
    throw 'cannot read source git revision'
}

$mount = "$RepositoryRoot`:/src"
$targetDir = '/src/target/docker-' + $targetSlug
$binaryInContainer = "$targetDir/$Target/release/rg"
$buildScript = "set -e; rustup toolchain install $RustToolchain --profile minimal --no-self-update; cargo +$RustToolchain build --manifest-path /src/Cargo.toml --release --features personal-default-heading --target $Target; $binaryInContainer --version"
& docker run --rm -v $mount -w /src -e "CARGO_TARGET_DIR=$targetDir" "$expectedDigest" bash -c $buildScript
if ($LASTEXITCODE -ne 0) { throw 'Docker Linux release build failed' }

$binary = Join-Path $targetRoot 'release\rg'
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw "missing Linux release binary: $binary" }
$binaryHash = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
$version = (& docker run --rm -v $mount -w /src "$expectedDigest" bash -c "$binaryInContainer --version | head -n 1").Trim()
$receiptObject = [ordered]@{
    schema = 'ripgrep.personal-linux-docker-build-receipt.v1'
    status = 'Candidate'
    terminal = 'Candidate'
    image = $Image
    image_digest = $ImageDigest
    target = $Target
    rust_toolchain = $RustToolchain
    source_revision = $sourceRevision
    binary = $binary
    binary_digest_sha256 = $binaryHash
    version = $version
    features = @('personal-default-heading')
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
    freshness = 'freshness.ripgrep.personal-linux-docker-build.v1'
    invalidation = 'invalidation.ripgrep.personal-linux-docker-image-or-source-revision.v1'
    FirstMismatch = 'Docker build/image/binary readback is recorded; runtime behavior, semantic Join, consumer/proof and ParentJoin remain separate gates.'
    NextBoundedQuery = 'Run the binary in a pinned Linux runtime fixture, reverse-parse behavior, and join it with Owner semantic and Windows install receipts.'
    retention = 'DurableUntilParentConsumption'
}
$receiptObject | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 -LiteralPath $Receipt
(Get-FileHash -LiteralPath $Receipt -Algorithm SHA256).Hash | Set-Content -Encoding ascii -LiteralPath ($Receipt + '.sha256')
Write-Output (Get-Content -Raw -LiteralPath $Receipt)
