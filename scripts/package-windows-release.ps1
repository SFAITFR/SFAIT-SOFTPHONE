param(
    [string]$Version = "",
    [string]$BuildNumber = "",
    [string]$FlutterBin = $env:FLUTTER_BIN
)

$ErrorActionPreference = "Stop"

function Assert-LastExitCode {
    param([string]$Message)

    if ($LASTEXITCODE -ne 0) {
        throw $Message
    }
}

function Get-PubspecVersionParts {
    $pubspec = Get-Content -Raw -Path "pubspec.yaml"
    $match = [regex]::Match($pubspec, "(?m)^version:\s*([0-9A-Za-z\.\-\+]+)")
    if (-not $match.Success) {
        throw "Unable to read version from pubspec.yaml."
    }

    $parts = $match.Groups[1].Value.Split("+", 2)
    return @{
        Version = $parts[0]
        BuildNumber = if ($parts.Count -gt 1) { $parts[1] } else { "1" }
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$pubspecVersion = Get-PubspecVersionParts
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = $pubspecVersion.Version
}
if ([string]::IsNullOrWhiteSpace($BuildNumber)) {
    $BuildNumber = $pubspecVersion.BuildNumber
}
if ([string]::IsNullOrWhiteSpace($FlutterBin)) {
    $FlutterBin = "flutter"
}

$releaseDir = Join-Path $repoRoot "build\windows\x64\runner\Release"
$distDir = Join-Path $repoRoot "dist\releases\v$Version"
$stageDir = Join-Path $distDir "SFAIT Softphone"
$zipPath = Join-Path $distDir "sfait-softphone-$Version-windows-x64.zip"
$shaPath = "$zipPath.sha256"

& $FlutterBin build windows --release `
    --build-name $Version `
    --build-number $BuildNumber `
    --dart-define "SFAIT_APP_VERSION=$Version"
Assert-LastExitCode "Flutter Windows release build failed."

if (-not (Test-Path (Join-Path $releaseDir "sfait_softphone.exe"))) {
    throw "Windows release build output not found: $releaseDir"
}

if (Test-Path $stageDir) {
    Remove-Item -LiteralPath $stageDir -Recurse -Force
}
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
Copy-Item -Path (Join-Path $releaseDir "*") -Destination $stageDir -Recurse -Force

if (Test-Path $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -Path $stageDir -DestinationPath $zipPath -Force

$hash = Get-FileHash -Algorithm SHA256 -Path $zipPath
"$($hash.Hash.ToLowerInvariant())  $(Split-Path -Leaf $zipPath)" |
    Set-Content -Path $shaPath -Encoding ASCII

Get-Item $zipPath, $shaPath | Select-Object FullName, Length, LastWriteTime
