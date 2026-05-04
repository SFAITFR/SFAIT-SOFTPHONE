param(
    [string]$Version = "",
    [string]$BuildNumber = "",
    [string]$FlutterBin = $env:FLUTTER_BIN,
    [string]$Repository = "SFAITFR/SFAIT-SOFTPHONE"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($Version)) {
    $pubspec = Get-Content -Raw -Path "pubspec.yaml"
    $match = [regex]::Match($pubspec, "(?m)^version:\s*([0-9A-Za-z\.\-\+]+)")
    if (-not $match.Success) {
        throw "Unable to read version from pubspec.yaml."
    }
    $Version = $match.Groups[1].Value.Split("+", 2)[0]
}

$tag = "v$Version"
$msiOutput = & (Join-Path $PSScriptRoot "package-windows-msi.ps1") `
    -Version $Version `
    -BuildNumber $BuildNumber `
    -FlutterBin $FlutterBin

$msiPath = Join-Path $repoRoot "dist\releases\$tag\SFAIT_Softphone_installer.msi"
$msiShaPath = "$msiPath.sha256"

if (-not (Test-Path $msiPath) -or -not (Test-Path $msiShaPath)) {
    throw "Windows MSI release assets were not generated."
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "GitHub CLI is not installed. Upload these files to release ${tag}:"
    Write-Host "- $msiPath"
    Write-Host "- $msiShaPath"
    return
}

& gh auth status --hostname github.com *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "GitHub CLI is not authenticated. Upload these files to release ${tag}:"
    Write-Host "- $msiPath"
    Write-Host "- $msiShaPath"
    return
}

$releaseExists = $true
& gh release view $tag --repo $Repository *> $null
if ($LASTEXITCODE -ne 0) {
    $releaseExists = $false
}

if ($releaseExists) {
    & gh release upload $tag $msiPath $msiShaPath --repo $Repository --clobber
} else {
    & gh release create $tag $msiPath $msiShaPath `
        --repo $Repository `
        --title "SFAIT Softphone $Version" `
        --notes "Release SFAIT Softphone $Version."
}

Write-Host "Windows release assets uploaded to $Repository@$tag."
