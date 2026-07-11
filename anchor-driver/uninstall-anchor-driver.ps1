[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window.'
  }
}

Assert-Administrator

Get-Process -Name 'TopologyAnchorController' -ErrorAction SilentlyContinue |
  Stop-Process -Force
Start-Sleep -Seconds 2

$packages = @(Get-WindowsDriver -Online -All |
  Where-Object {
    $_.OriginalFileName -and
    (Split-Path -Leaf $_.OriginalFileName) -ieq 'TopologyAnchorDriver.inf'
  })

if ($packages.Count -eq 0) {
  Write-Host 'Topology DDC Sleep Anchor driver package is not staged.'
  return
}

foreach ($package in $packages) {
  Write-Host "Removing driver package $($package.Driver)"
  & pnputil.exe /delete-driver $package.Driver /uninstall /force | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Driver package removal failed with exit code $LASTEXITCODE for $($package.Driver)"
  }
}

Write-Host 'Topology DDC Sleep Anchor controller stopped and driver package removed.'
Write-Host 'Any explicitly trusted local test certificate remains installed and must be removed separately if no other test driver uses it.'
