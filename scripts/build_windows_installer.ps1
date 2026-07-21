param(
  [string]$Version = '',
  [string]$OutputDirectory = '',
  [string]$InnoSetupCompiler = '',
  [switch]$SkipFlutterBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $RepositoryRoot

if ([string]::IsNullOrWhiteSpace($Version)) {
  $VersionLine = Select-String -Path (Join-Path $RepositoryRoot 'pubspec.yaml') -Pattern '^version:\s*([^+\s]+)' | Select-Object -First 1
  if ($null -eq $VersionLine) {
    throw 'Unable to read the application version from pubspec.yaml.'
  }
  $Version = $VersionLine.Matches[0].Groups[1].Value
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path $RepositoryRoot 'build\installers'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

if (-not $SkipFlutterBuild) {
  flutter pub get --enforce-lockfile
  if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
  flutter build windows --release --build-name $Version
  if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows release build failed.' }
}

$GuiSource = Join-Path $RepositoryRoot 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $GuiSource 'lc.exe'))) {
  throw "Windows release output was not found at $GuiSource."
}

if ([string]::IsNullOrWhiteSpace($InnoSetupCompiler)) {
  if (-not [string]::IsNullOrWhiteSpace($env:INNO_SETUP_COMPILER)) {
    $InnoSetupCompiler = $env:INNO_SETUP_COMPILER
  } else {
    $Command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($null -ne $Command) {
      $InnoSetupCompiler = $Command.Source
    } else {
      $InnoSetupCompiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
    }
  }
}
if (-not (Test-Path $InnoSetupCompiler)) {
  throw 'Inno Setup 6 compiler was not found. Set INNO_SETUP_COMPILER or pass -InnoSetupCompiler.'
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$InstallerDefinition = Join-Path $RepositoryRoot 'packaging\windows\lc.iss'
$Arguments = @(
  "/DAppVersion=$Version",
  "/DAppSource=$GuiSource",
  "/DOutputDir=$OutputDirectory",
  $InstallerDefinition
)
& $InnoSetupCompiler $Arguments
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed.' }

$Installer = Join-Path $OutputDirectory 'lc-windows-x64-setup.exe'
if (-not (Test-Path $Installer)) {
  throw "Installer output was not found at $Installer."
}
Write-Host "Built $Installer"
