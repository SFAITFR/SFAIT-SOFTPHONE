param(
    [string]$Version = "",
    [string]$BuildNumber = "",
    [string]$FlutterBin = $env:FLUTTER_BIN,
    [string]$WixBin = ""
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

function Convert-ToMsiVersion {
    param([string]$RawVersion)

    $parts = $RawVersion.Split("-", 2)[0].Split(".")
    while ($parts.Count -lt 3) {
        $parts += "0"
    }
    return ($parts | Select-Object -First 3) -join "."
}

function Get-XmlEscaped {
    param([string]$Value)

    return [System.Security.SecurityElement]::Escape($Value)
}

function Get-StableGuid {
    param([string]$Value)

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())
        $hash = $md5.ComputeHash($bytes)
        $hash[6] = ($hash[6] -band 0x0f) -bor 0x30
        $hash[8] = ($hash[8] -band 0x3f) -bor 0x80
        return ([Guid]::new($hash)).ToString("B").ToUpperInvariant()
    }
    finally {
        $md5.Dispose()
    }
}

function Get-SafeId {
    param([string]$Prefix, [string]$Value)

    $safe = [regex]::Replace($Value, "[^A-Za-z0-9_]", "_")
    if ($safe.Length -gt 64) {
        $safe = $safe.Substring(0, 64)
    }
    return "$Prefix$safe"
}

function Get-RelativePath {
    param([string]$BasePath, [string]$TargetPath)

    $base = [System.IO.Path]::GetFullPath($BasePath)
    if (-not $base.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $base += [System.IO.Path]::DirectorySeparatorChar
    }
    $target = [System.IO.Path]::GetFullPath($TargetPath)
    $baseUri = [Uri]::new($base)
    $targetUri = [Uri]::new($target)
    return [Uri]::UnescapeDataString(
        $baseUri.MakeRelativeUri($targetUri).ToString().Replace("/", [System.IO.Path]::DirectorySeparatorChar)
    )
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
if ([string]::IsNullOrWhiteSpace($WixBin)) {
    $cachedWix = Join-Path $env:USERPROFILE ".nuget\packages\wixtoolset.sdk\4.0.5\tools\net472\x64\wix.exe"
    if (Test-Path $cachedWix) {
        $WixBin = $cachedWix
    }
    else {
        $command = Get-Command wix.exe -ErrorAction SilentlyContinue
        if ($command) {
            $WixBin = $command.Source
        }
        else {
            $defaultWix = "C:\Program Files\WiX Toolset v7.0\bin\wix.exe"
            if (Test-Path $defaultWix) {
                $WixBin = $defaultWix
            }
        }
    }
}
if ([string]::IsNullOrWhiteSpace($WixBin) -or -not (Test-Path $WixBin)) {
    throw "WiX CLI not found. Install WiXToolset.WiXCLI with winget."
}

$releaseDir = Join-Path $repoRoot "build\windows\x64\runner\Release"
$distDir = Join-Path $repoRoot "dist\releases\v$Version"
$msiPath = Join-Path $distDir "SFAIT_Softphone_installer.msi"
$shaPath = "$msiPath.sha256"
$wixWorkDir = Join-Path $repoRoot "build\windows-msi"
$wxsPath = Join-Path $wixWorkDir "SFAITSoftphone.wxs"
$pinScriptPath = Join-Path $wixWorkDir "pin-taskbar.ps1"
$objPath = Join-Path $wixWorkDir "SFAITSoftphone.wixobj"
$msiVersion = Convert-ToMsiVersion $Version
$upgradeCode = "{9B8DAA43-9791-4907-9B4E-274827778291}"

& $FlutterBin build windows --release `
    --build-name $Version `
    --build-number $BuildNumber `
    --dart-define "SFAIT_APP_VERSION=$Version"
Assert-LastExitCode "Flutter Windows release build failed."

if (-not (Test-Path (Join-Path $releaseDir "sfait_softphone.exe"))) {
    throw "Windows release build output not found: $releaseDir"
}

New-Item -ItemType Directory -Path $distDir -Force | Out-Null
if (Test-Path $wixWorkDir) {
    Remove-Item -LiteralPath $wixWorkDir -Recurse -Force
}
New-Item -ItemType Directory -Path $wixWorkDir -Force | Out-Null

$directoryMap = @{"." = "INSTALLFOLDER"}
$directories = New-Object System.Collections.Generic.List[string]
$components = New-Object System.Collections.Generic.List[string]
$componentRefs = New-Object System.Collections.Generic.List[string]

$allDirectories = Get-ChildItem -LiteralPath $releaseDir -Directory -Recurse |
    Sort-Object FullName
foreach ($directory in $allDirectories) {
    $relative = Get-RelativePath $releaseDir $directory.FullName
    $parentRelative = Split-Path $relative -Parent
    if ([string]::IsNullOrWhiteSpace($parentRelative)) {
        $parentRelative = "."
    }
    $directoryId = Get-SafeId "dir_" $relative
    $directoryMap[$relative] = $directoryId
    $parentId = $directoryMap[$parentRelative]
    $directories.Add("    <DirectoryRef Id=`"$parentId`"><Directory Id=`"$directoryId`" Name=`"$(Get-XmlEscaped $directory.Name)`" /></DirectoryRef>")
}

$files = Get-ChildItem -LiteralPath $releaseDir -File -Recurse | Sort-Object FullName
$index = 0
foreach ($file in $files) {
    $relative = Get-RelativePath $releaseDir $file.FullName
    $directoryRelative = Split-Path $relative -Parent
    if ([string]::IsNullOrWhiteSpace($directoryRelative)) {
        $directoryRelative = "."
    }
    $directoryId = $directoryMap[$directoryRelative]
    $componentId = "cmp_$index"
    $fileId = "fil_$index"
    $guid = Get-StableGuid "SFAIT Softphone MSI component $relative"
    $source = Get-XmlEscaped $file.FullName
    $name = Get-XmlEscaped $file.Name
    $components.Add("    <Component Id=`"$componentId`" Directory=`"$directoryId`" Guid=`"$guid`"><File Id=`"$fileId`" Source=`"$source`" Name=`"$name`" KeyPath=`"yes`" /></Component>")
    $componentRefs.Add("      <ComponentRef Id=`"$componentId`" />")
    $index += 1
}

$iconPath = Get-XmlEscaped (Join-Path $repoRoot "windows\runner\resources\app_icon.ico")
$directoryXml = $directories -join [Environment]::NewLine
$componentXml = $components -join [Environment]::NewLine
$componentRefXml = $componentRefs -join [Environment]::NewLine
$pinScriptSource = Get-XmlEscaped $pinScriptPath

$pinTaskbarScript = @'
param([string]$ShortcutPath)

$ErrorActionPreference = "SilentlyContinue"

function Normalize-Verb {
    param([string]$Name)

    $clean = $Name -replace "&", ""
    $normalized = $clean.Normalize([Text.NormalizationForm]::FormD)
    $chars = foreach ($char in $normalized.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($char) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            $char
        }
    }
    return (-join $chars).ToLowerInvariant()
}

if (-not (Test-Path -LiteralPath $ShortcutPath)) {
    exit 0
}

$shell = New-Object -ComObject Shell.Application
$folderPath = Split-Path -LiteralPath $ShortcutPath -Parent
$itemName = Split-Path -LiteralPath $ShortcutPath -Leaf
$folder = $shell.Namespace($folderPath)
if ($null -eq $folder) {
    exit 0
}

$item = $folder.ParseName($itemName)
if ($null -eq $item) {
    exit 0
}

foreach ($verb in @($item.Verbs())) {
    $name = Normalize-Verb $verb.Name
    if ($name -match "(pin.*taskbar|epingler.*barre)") {
        $verb.DoIt()
        Start-Sleep -Milliseconds 500
        break
    }
}

exit 0
'@

Set-Content -Path $pinScriptPath -Value $pinTaskbarScript -Encoding UTF8

$wxs = @"
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package Name="SFAIT Softphone" Manufacturer="SFAIT" Version="$msiVersion" UpgradeCode="$upgradeCode" Scope="perUser">
    <MajorUpgrade AllowSameVersionUpgrades="yes" DowngradeErrorMessage="Une version plus recente de SFAIT Softphone est deja installee." />
    <MediaTemplate EmbedCab="yes" />
    <Icon Id="AppIcon.ico" SourceFile="$iconPath" />

    <StandardDirectory Id="LocalAppDataFolder">
      <Directory Id="ProgramsDirectory" Name="Programs">
        <Directory Id="INSTALLFOLDER" Name="SFAIT Softphone" />
      </Directory>
    </StandardDirectory>
    <StandardDirectory Id="ProgramMenuFolder">
      <Directory Id="ApplicationProgramsFolder" Name="SFAIT Softphone" />
    </StandardDirectory>
    <StandardDirectory Id="DesktopFolder" />
    <StandardDirectory Id="AppDataFolder">
      <Directory Id="MicrosoftAppDataFolder" Name="Microsoft">
        <Directory Id="InternetExplorerFolder" Name="Internet Explorer">
          <Directory Id="QuickLaunchFolder" Name="Quick Launch">
            <Directory Id="UserPinnedFolder" Name="User Pinned">
              <Directory Id="TaskBarFolder" Name="TaskBar" />
            </Directory>
          </Directory>
        </Directory>
      </Directory>
    </StandardDirectory>

$directoryXml

$componentXml

    <Component Id="TaskbarPinScriptComponent" Directory="INSTALLFOLDER" Guid="{DFD6322C-2F4F-4B96-8624-B8974E02419E}">
      <File Id="TaskbarPinScriptFile" Source="$pinScriptSource" Name="pin-taskbar.ps1" KeyPath="yes" />
    </Component>

    <Component Id="ApplicationShortcutComponent" Directory="ApplicationProgramsFolder" Guid="{6C9C2D9C-82D7-49B4-892C-C59D2BE63734}">
      <Shortcut Id="ApplicationStartMenuShortcut" Name="SFAIT Softphone" Target="[INSTALLFOLDER]sfait_softphone.exe" WorkingDirectory="INSTALLFOLDER" Icon="AppIcon.ico" />
      <RemoveFolder Id="ApplicationProgramsFolder" On="uninstall" />
      <RegistryValue Root="HKCU" Key="Software\SFAIT\SFAIT Softphone" Name="installed" Type="integer" Value="1" KeyPath="yes" />
    </Component>

    <Component Id="ApplicationDesktopShortcutComponent" Directory="DesktopFolder" Guid="{0B4B2E84-1381-4C32-A76E-13F38EE7C9A5}">
      <Shortcut Id="ApplicationDesktopShortcut" Name="SFAIT Softphone" Target="[INSTALLFOLDER]sfait_softphone.exe" WorkingDirectory="INSTALLFOLDER" Icon="AppIcon.ico" />
      <RegistryValue Root="HKCU" Key="Software\SFAIT\SFAIT Softphone" Name="desktopShortcut" Type="integer" Value="1" KeyPath="yes" />
    </Component>

    <Component Id="ApplicationTaskbarShortcutComponent" Directory="TaskBarFolder" Guid="{C2AA98D9-652C-4C81-A737-46EB55AA9BC7}">
      <Shortcut Id="ApplicationTaskbarShortcut" Name="SFAIT Softphone" Target="[INSTALLFOLDER]sfait_softphone.exe" WorkingDirectory="INSTALLFOLDER" Icon="AppIcon.ico" />
      <RegistryValue Root="HKCU" Key="Software\SFAIT\SFAIT Softphone" Name="taskbarShortcut" Type="integer" Value="1" KeyPath="yes" />
    </Component>

    <CustomAction Id="PinApplicationToTaskbar" Directory="INSTALLFOLDER" Execute="immediate" Return="ignore" ExeCommand="&quot;[SystemFolder]WindowsPowerShell\v1.0\powershell.exe&quot; -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;[INSTALLFOLDER]pin-taskbar.ps1&quot; &quot;[ApplicationProgramsFolder]SFAIT Softphone.lnk&quot;" />

    <InstallExecuteSequence>
      <Custom Action="PinApplicationToTaskbar" After="CreateShortcuts" Condition="NOT REMOVE" />
    </InstallExecuteSequence>

    <Feature Id="MainFeature" Title="SFAIT Softphone" Level="1">
$componentRefXml
      <ComponentRef Id="TaskbarPinScriptComponent" />
      <ComponentRef Id="ApplicationShortcutComponent" />
      <ComponentRef Id="ApplicationDesktopShortcutComponent" />
      <ComponentRef Id="ApplicationTaskbarShortcutComponent" />
    </Feature>
  </Package>
</Wix>
"@

Set-Content -Path $wxsPath -Value $wxs -Encoding UTF8

if (Test-Path $msiPath) {
    Remove-Item -LiteralPath $msiPath -Force
}

& $WixBin build $wxsPath -arch x64 -o $msiPath
Assert-LastExitCode "WiX MSI build failed."

$hash = Get-FileHash -Algorithm SHA256 -Path $msiPath
"$($hash.Hash.ToLowerInvariant())  $(Split-Path -Leaf $msiPath)" |
    Set-Content -Path $shaPath -Encoding ASCII

Get-Item $msiPath, $shaPath | Select-Object FullName, Length, LastWriteTime
