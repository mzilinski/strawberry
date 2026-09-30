# Builds the Strawberry MSI package from a staging directory containing strawberry.exe with all DLLs and plugin directories.
# Requires the WiX v6 .NET tool: dotnet tool install --global wix --version 6.0.2
#
# Example: pwsh dist/windows/build-msi.ps1 -StageDir build/stage -Arch x64

param(
  [Parameter(Mandatory = $true)][string]$StageDir,
  [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
  [string]$Version,
  [string]$OutDir = '.'
)

$ErrorActionPreference = 'Stop'
$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Resolve-Path (Join-Path $SourceDir '..\..')
$StageDir = (Resolve-Path $StageDir).Path

if (-not (Test-Path (Join-Path $StageDir 'strawberry.exe'))) {
  throw "strawberry.exe not found in $StageDir"
}

# MSI versions are numeric, use major.minor.patch from cmake/Version.cmake and the commit count as fourth field.
if (-not $Version) {
  $VersionCmake = Get-Content (Join-Path $RootDir 'cmake\Version.cmake') -Raw
  $Parts = 'MAJOR', 'MINOR', 'PATCH' | ForEach-Object {
    if ($VersionCmake -notmatch "set\(STRAWBERRY_VERSION_$_\s+(\d+)\)") { throw "STRAWBERRY_VERSION_$_ not found" }
    $Matches[1]
  }
  $CommitCount = git -C $RootDir rev-list --count HEAD 2>$null
  if (-not $CommitCount) { $CommitCount = 0 }
  $Version = ($Parts + [Math]::Min([int]$CommitCount, 65535)) -join '.'
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$WorkDir = New-Item -ItemType Directory -Force -Path (Join-Path $OutDir 'msi-work')

# WixUI only shows RTF licenses, convert COPYING.
$LicenseRtf = Join-Path $WorkDir 'COPYING.rtf'
$License = (Get-Content (Join-Path $RootDir 'COPYING') -Raw) -replace '\\', '\\' -replace '\{', '\{' -replace '\}', '\}' -replace "`r?`n", "\par`n"
Set-Content -Path $LicenseRtf -Encoding ascii -Value "{\rtf1\ansi\deff0{\fonttbl{\f0 Consolas;}}\f0\fs16 $License}"

# Same file associations as strawberry.nsi.in.
# Video containers (.mp4, .webm, .asf) are not registered, Strawberry would be offered as the default program for videos.
$FileTypes = [ordered]@{
  mp3 = 'MP3 Audio File'; mp2 = 'MP2 Audio File'; flac = 'FLAC Audio File'; ogg = 'OGG Audio File'; oga = 'OGG Audio File'
  opus = 'Opus Audio File'; spx = 'OGG Speex Audio File'; m4a = 'MP4 Audio File'; aac = 'AAC Audio File'; wma = 'WMA Audio File'
  wav = 'WAV Audio File'; aif = 'AIFF Audio File'; aiff = 'AIFF Audio File'; aifc = 'AIFF Audio File'; wv = 'WavPack Audio File'
  ape = "Monkey's Audio File"; mpc = 'Musepack Audio File'; tta = 'TrueAudio Audio File'; tak = 'TAK Audio File'; mka = 'Matroska Audio File'
  ac3 = 'AC3 Audio File'; dts = 'DTS Audio File'; dsf = 'DSF Audio File'; dsd = 'DSDIFF Audio File'; dff = 'DSDIFF Audio File'
  spc = 'SNES SPC700 Audio File'; vgm = 'VGM Audio File'; mod = 'MOD Module Music File'; s3m = 'S3M Module Music File'
  xm = 'XM Module Music File'; it = 'IT Module Music File'
  pls = 'PLS Audio File'; m3u = 'M3U Audio File'; m3u8 = 'M3U8 Playlist'; xspf = 'XSPF Audio File'
  asx = 'Windows Media Audio/Video playlist'; wpl = 'Windows Media Playlist'; cue = 'CUE Sheet'
}
$ProgId = 'Strawberry Music Player'
$CapabilitiesKey = 'Software\Clients\Media\Strawberry\Capabilities\FileAssociations'
$Values = foreach ($Ext in $FileTypes.Keys) {
  $Class = "Software\Classes\$ProgId.AssocFile.$($Ext.ToUpper())"
  $Desc = [Security.SecurityElement]::Escape($FileTypes[$Ext])
  @"
      <RegistryValue Root="HKLM" Key="$CapabilitiesKey" Name=".$Ext" Type="string" Value="$ProgId.AssocFile.$($Ext.ToUpper())" />
      <RegistryValue Root="HKLM" Key="$Class" Type="string" Value="$Desc" />
      <RegistryValue Root="HKLM" Key="$Class\DefaultIcon" Type="string" Value="[INSTALLFOLDER]strawberry.ico" />
      <RegistryValue Root="HKLM" Key="$Class\shell" Type="string" Value="Play" />
      <RegistryValue Root="HKLM" Key="$Class\shell\open" Type="string" Value="&amp;Open" />
      <RegistryValue Root="HKLM" Key="$Class\shell\open\command" Type="string" Value="&quot;[INSTALLFOLDER]strawberry.exe&quot; &quot;%1&quot;" />
      <RegistryValue Root="HKLM" Key="$Class\shell\play" Type="string" Value="&amp;Play" />
      <RegistryValue Root="HKLM" Key="$Class\shell\play\command" Type="string" Value="&quot;[INSTALLFOLDER]strawberry.exe&quot; &quot;%L&quot;" />
"@
}
$AssociationsWxs = Join-Path $WorkDir 'associations.wxs'
Set-Content -Path $AssociationsWxs -Encoding utf8 -Value @"
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Fragment>
    <Component Id="FileAssociations" Directory="INSTALLFOLDER">
      <RegistryValue Root="HKLM" Key="Software\Strawberry\Installer" Name="FileAssociations" Type="integer" Value="1" KeyPath="yes" />
$($Values -join "`n")
    </Component>
  </Fragment>
</Wix>
"@

$WixVersion = (wix --version) -replace '\+.*$', ''
wix extension add --global "WixToolset.UI.wixext/$WixVersion" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Failed to add WixToolset.UI.wixext' }

$OutFile = Join-Path $OutDir "StrawberrySetup-$Version-msvc-$Arch.msi"

wix build (Join-Path $SourceDir 'strawberry.wxs') $AssociationsWxs `
  -arch $Arch `
  -ext WixToolset.UI.wixext `
  -d "StageDir=$StageDir" `
  -d "Version=$Version" `
  -d "LicenseRtf=$LicenseRtf" `
  -o $OutFile
if ($LASTEXITCODE -ne 0) { throw 'wix build failed' }

# ICE43 and ICE57 assume a per-user start menu, it is per-machine with Scope="perMachine".
# ICE61 is expected, AllowSameVersionUpgrades lets development builds with the same version replace each other.
wix msi validate $OutFile -sice ICE43 -sice ICE57 -sice ICE61
if ($LASTEXITCODE -ne 0) { throw 'MSI validation failed' }

Write-Host "Created $OutFile"
