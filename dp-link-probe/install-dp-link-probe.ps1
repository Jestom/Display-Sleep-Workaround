[CmdletBinding()]
param(
  [string]$PackagePath = (Join-Path $PSScriptRoot 'out\x64')
)

$ErrorActionPreference = 'Stop'

function Assert-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window.'
  }
}

function Find-DevCon {
  $localDevCon = Join-Path $PSScriptRoot 'out\x64\devcon.exe'
  if (Test-Path -LiteralPath $localDevCon) {
    return $localDevCon
  }

  $command = Get-Command devcon.exe -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  $toolsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Tools'
  $candidate = Get-ChildItem -LiteralPath $toolsRoot -Recurse -File -Filter devcon.exe `
      -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '[\\/]x64[\\/]devcon\.exe$' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1

  if (-not $candidate) {
    throw 'devcon.exe was not found. Install the Windows Driver Kit or add devcon.exe to PATH.'
  }

  return $candidate.FullName
}

Assert-Administrator

$inf = Join-Path $PackagePath 'TopologyDpProbeDriver.inf'
if (-not (Test-Path -LiteralPath $inf)) {
  throw "Driver package not found: $inf. Run .\build-dp-link-probe.ps1 first."
}

$devcon = Find-DevCon

# Remove a previous root-enumerated probe instance so repeated tests do not create duplicates.
& $devcon remove 'Root\TopologyDpProbe' | Out-Host

& $devcon install $inf 'Root\TopologyDpProbe' | Out-Host
if ($LASTEXITCODE -ne 0) {
  throw "Driver installation failed with exit code $LASTEXITCODE"
}

Write-Host 'Topology DP Link Diagnostic Probe installed.'
Write-Host 'Next: .\out\x64\TopologyDpProbeCtl.exe list'
