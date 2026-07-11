[CmdletBinding()]
param(
  [ValidateSet('Debug', 'Release')]
  [string]$Configuration = 'Release',

  [ValidateSet('x64', 'ARM64')]
  [string]$Platform = 'x64'
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
      $_.FullName -match "[\\/]$Platform[\\/]$Configuration[\\/]" -or
      $_.FullName -match "[\\/]$Configuration[\\/]$Platform[\\/]"
    } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if (-not $artifact) {
    throw "Build artifact was not found: $Filter"
  }

  return $artifact.FullName
}

$root = $PSScriptRoot
$workRoot = Split-Path -Parent $root
$solution = Join-Path $root 'TopologyAnchor.sln'
$msbuild = Find-MSBuild
$kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$iddcxHeaders = @(Get-ChildItem `
    -Path (Join-Path $kitsRoot 'Include\*\um\iddcx.h') `
    -File `
    -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending)

if ($iddcxHeaders.Count -eq 0) {
  throw @"
The complete Windows Driver Kit is not installed. iddcx.h was not found under:
$kitsRoot\Include\<version>\um

Install both the matching Windows SDK and the standalone WDK, then enable the Windows Driver Kit individual component in Visual Studio Installer.
"@
}

$logRoot = Join-Path $workRoot 'log\anchor-driver'
$logPath = Join-Path $logRoot ("build-{0}-{1}-{2}.log" -f $Configuration, $Platform, (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

Write-Host "WDK IddCx headers: $($iddcxHeaders[0].DirectoryName)"
Write-Host "MSBuild: $msbuild"
Write-Host "Building $solution ($Configuration|$Platform)"
Write-Host "Build log: $logPath"

$previousVsLang = $env:VSLANG
$buildExitCode = 1
try {
  $env:VSLANG = '1033'
  & $msbuild $solution `
    /m `
    /t:Build `
    /p:Configuration=$Configuration `
    /p:Platform=$Platform `
    /p:Inf2CatUseLocalTime=true `
    /v:minimal 2>&1 |
    Tee-Object -LiteralPath $logPath
  $buildExitCode = $LASTEXITCODE
} finally {
  $env:VSLANG = $previousVsLang
}

if ($buildExitCode -ne 0) {
  throw "MSBuild failed with exit code $buildExitCode. See $logPath"
}

$output = Join-Path $root "out\$Platform"
if (Test-Path -LiteralPath $output) {
  Remove-Item -LiteralPath $output -Recurse -Force
}
New-Item -ItemType Directory -Path $output -Force | Out-Null

$requiredArtifacts = @(
  (Find-BuildArtifact -Root $root -Filter 'TopologyAnchorDriver.dll'),
  (Find-BuildArtifact -Root $root -Filter 'TopologyAnchorDriver.inf'),
  (Find-BuildArtifact -Root $root -Filter 'TopologyAnchorDriver.cat'),
  (Find-BuildArtifact -Root $root -Filter 'TopologyAnchorController.exe')
)

foreach ($artifact in $requiredArtifacts) {
  Copy-Item -LiteralPath $artifact -Destination $output -Force
}

foreach ($pdbName in @('TopologyAnchorDriver.pdb', 'TopologyAnchorController.pdb')) {
  $pdb = Get-ChildItem -LiteralPath $root -Recurse -File -Filter $pdbName |
    Where-Object {
      $_.FullName -match "[\\/]$Platform[\\/]$Configuration[\\/]" -or
      $_.FullName -match "[\\/]$Configuration[\\/]$Platform[\\/]"
    } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($pdb) {
    Copy-Item -LiteralPath $pdb.FullName -Destination $output -Force
  }
}

$outputDriver = Join-Path $output 'TopologyAnchorDriver.dll'
$driverSignature = Get-AuthenticodeSignature -FilePath $outputDriver
if (-not $driverSignature.SignerCertificate) {
  throw "The built driver does not contain a signer certificate: $outputDriver"
}

$certificatePath = Join-Path $output 'TopologyAnchorTest.cer'
Export-Certificate `
  -Cert $driverSignature.SignerCertificate `
  -FilePath $certificatePath `
  -Force | Out-Null

Write-Host "Build output: $output"
Get-ChildItem -LiteralPath $output | Select-Object Name, Length, LastWriteTime
