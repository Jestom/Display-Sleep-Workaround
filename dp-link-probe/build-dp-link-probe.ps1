[CmdletBinding()]
param(
  [ValidateSet('Debug', 'Release')]
  [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'

function Find-MSBuild {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (Test-Path -LiteralPath $vswhere) {
    $installationPath = & $vswhere `
      -latest `
      -products * `
      -requires Microsoft.Component.MSBuild `
      -property installationPath

    if ($installationPath) {
      $amd64Candidate = Join-Path $installationPath 'MSBuild\Current\Bin\amd64\MSBuild.exe'
      if (Test-Path -LiteralPath $amd64Candidate) {
        return $amd64Candidate
      }

      $candidate = Join-Path $installationPath 'MSBuild\Current\Bin\MSBuild.exe'
      if (Test-Path -LiteralPath $candidate) {
        return $candidate
      }
    }
  }

  $command = Get-Command msbuild.exe -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  throw 'MSBuild was not found. Install Visual Studio and the Windows Driver Kit.'
}

function Find-BuildArtifact {
  param(
    [Parameter(Mandatory)]
    [string]$Root,

    [Parameter(Mandatory)]
    [string]$Filter
  )

  $artifact = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Filter |
    Where-Object {
      $_.FullName -match "[\\/]x64[\\/]$Configuration[\\/]" -or
      $_.FullName -match "[\\/]$Configuration[\\/]"
    } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if (-not $artifact) {
    throw "Build artifact was not found: $Filter"
  }

  return $artifact.FullName
}

$root = $PSScriptRoot
$solution = Join-Path $root 'TopologyDpProbe.sln'
$msbuild = Find-MSBuild
$kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$ntddk = @(Get-ChildItem `
    -Path (Join-Path $kitsRoot 'Include\*\km\ntddk.h') `
    -File `
    -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending)
$dispmprt = @(Get-ChildItem `
    -Path (Join-Path $kitsRoot 'Include\*\km\dispmprt.h') `
    -File `
    -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending)

if ($ntddk.Count -eq 0 -or $dispmprt.Count -eq 0) {
  throw @"
The complete Windows Driver Kit is not installed. Kernel headers ntddk.h and/or dispmprt.h were not found under:
$kitsRoot\Include\<version>\km

Install both the matching Windows SDK and the standalone WDK, then enable the Windows Driver Kit individual component in Visual Studio Installer.
"@
}

Write-Host "WDK kernel headers: $($ntddk[0].DirectoryName)"
Write-Host "MSBuild: $msbuild"

Write-Host "Building $solution ($Configuration|x64)"
$previousVsLang = $env:VSLANG
$buildExitCode = 1
try {
  $env:VSLANG = '1033'
  & $msbuild $solution `
    /m `
    /t:Build `
    /p:Configuration=$Configuration `
    /p:Platform=x64 `
    /v:minimal
  $buildExitCode = $LASTEXITCODE
} finally {
  $env:VSLANG = $previousVsLang
}

if ($buildExitCode -ne 0) {
  throw "MSBuild failed with exit code $buildExitCode"
}

$output = Join-Path $root 'out\x64'
New-Item -ItemType Directory -Path $output -Force | Out-Null

$artifacts = @(
  (Find-BuildArtifact -Root $root -Filter 'TopologyDpProbeDriver.sys'),
  (Find-BuildArtifact -Root $root -Filter 'TopologyDpProbeDriver.inf'),
  (Find-BuildArtifact -Root $root -Filter 'TopologyDpProbeDriver.cat'),
  (Find-BuildArtifact -Root $root -Filter 'TopologyDpProbeCtl.exe')
)

foreach ($artifact in $artifacts) {
  Copy-Item -LiteralPath $artifact -Destination $output -Force
}

$devcon = Get-ChildItem `
    -Path (Join-Path $kitsRoot 'Tools\*\x64\devcon.exe') `
    -File `
    -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending |
  Select-Object -First 1
if (-not $devcon) {
  throw "The x64 devcon.exe tool was not found under $kitsRoot\Tools"
}
Copy-Item -LiteralPath $devcon.FullName -Destination $output -Force

$outputDriver = Join-Path $output 'TopologyDpProbeDriver.sys'
$driverSignature = Get-AuthenticodeSignature -FilePath $outputDriver
if (-not $driverSignature.SignerCertificate) {
  throw "The built driver does not contain a signer certificate: $outputDriver"
}

$certificatePath = Join-Path $output 'TopologyDpProbeTest.cer'
Export-Certificate `
  -Cert $driverSignature.SignerCertificate `
  -FilePath $certificatePath `
  -Force | Out-Null

Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'TopologyDpProbeDriver.pdb' |
  Where-Object { $_.FullName -match "[\\/]$Configuration[\\/]" } |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1 |
  Copy-Item -Destination $output -Force

Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'TopologyDpProbeCtl.pdb' |
  Where-Object { $_.FullName -match "[\\/]$Configuration[\\/]" } |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1 |
  Copy-Item -Destination $output -Force

Write-Host "Build output: $output"
Get-ChildItem -LiteralPath $output | Select-Object Name, Length, LastWriteTime
