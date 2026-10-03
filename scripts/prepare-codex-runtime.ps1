param(
    [string]$ArchivePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$version = '0.160.0'
$artifactName = 'codex-aarch64-unknown-linux-musl.tar.gz'
$entryName = 'codex-aarch64-unknown-linux-musl'
$artifactUrl = "https://github.com/openai/codex/releases/download/rust-v$version/$artifactName"
$artifactSha256 = '883620139925F677E5A12C95BA87A1D7F421388EBB797B1C10ABA42A04EDE9D7'
$binarySha256 = '50B06603BDCDAC39B714F5C3E68583C002B8AD8779EBFDAAF4932FF016B379C0'
$binarySize = 248966648
$repoRoot = Split-Path -Parent $PSScriptRoot
$destination = Join-Path $repoRoot 'entry/src/main/resources/rawfile/codex/codex-aarch64-unknown-linux-musl'
$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("hish-codex-runtime-" + [Guid]::NewGuid().ToString('N'))
$resolvedArchive = $ArchivePath

function Get-Header([string]$Path, [int]$Length) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $header = New-Object byte[] $Length
        $read = $stream.Read($header, 0, $header.Length)
        if ($read -ne $Length) { throw "File is shorter than the required $Length-byte header: $Path" }
        return $header
    } finally {
        $stream.Dispose()
    }
}

try {
    New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
    if ([string]::IsNullOrWhiteSpace($resolvedArchive)) {
        $resolvedArchive = Join-Path $workRoot $artifactName
        & curl.exe -L --fail --retry 3 -o $resolvedArchive $artifactUrl
        if ($LASTEXITCODE -ne 0) { throw "Official Codex download failed with exit code $LASTEXITCODE" }
    } else {
        $resolvedArchive = (Resolve-Path -LiteralPath $resolvedArchive).Path
    }

    $actualArchiveSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedArchive).Hash
    if ($actualArchiveSha -ne $artifactSha256) {
        throw "Official archive SHA-256 mismatch: $actualArchiveSha"
    }
    $entries = @(& tar.exe -tzf $resolvedArchive)
    if ($LASTEXITCODE -ne 0 -or $entries.Count -ne 1 -or $entries[0] -ne $entryName) {
        throw "Unexpected official archive content: $($entries -join ', ')"
    }

    & tar.exe -xzf $resolvedArchive -C $workRoot
    if ($LASTEXITCODE -ne 0) { throw "Official archive extraction failed" }
    $extracted = Join-Path $workRoot $entryName
    $details = Get-Item -LiteralPath $extracted
    $header = Get-Header -Path $extracted -Length 20
    $magic = ($header[0..3] | ForEach-Object { $_.ToString('X2') }) -join '-'
    $machine = $header[18] -bor ($header[19] -shl 8)
    $actualBinarySha = (Get-FileHash -Algorithm SHA256 -LiteralPath $extracted).Hash
    if ($details.Length -ne $binarySize -or $magic -ne '7F-45-4C-46' -or
        $header[4] -ne 2 -or $header[5] -ne 1 -or $machine -ne 0xB7 -or
        $actualBinarySha -ne $binarySha256) {
        throw "Extracted Codex executable validation failed: size=$($details.Length) magic=$magic machine=0x$($machine.ToString('X4')) sha256=$actualBinarySha"
    }

    $destinationDirectory = Split-Path -Parent $destination
    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    $temporaryDestination = $destination + '.tmp'
    Copy-Item -LiteralPath $extracted -Destination $temporaryDestination -Force
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $temporaryDestination).Hash -ne $binarySha256) {
        Remove-Item -LiteralPath $temporaryDestination -Force
        throw 'Prepared rawfile verification failed'
    }
    Move-Item -LiteralPath $temporaryDestination -Destination $destination -Force
    Write-Output "Prepared OpenAI Codex $version ARM64-musl ELF"
    Write-Output "Destination: $destination"
    Write-Output "Size: $binarySize"
    Write-Output "SHA-256: $binarySha256"
} finally {
    $resolvedWorkRoot = [System.IO.Path]::GetFullPath($workRoot)
    $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedWorkRoot.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedWorkRoot)) {
        Remove-Item -LiteralPath $resolvedWorkRoot -Recurse -Force
    }
}
