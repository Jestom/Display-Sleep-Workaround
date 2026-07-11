[CmdletBinding()]
param(
  [string]$PackagePath = (Join-Path $PSScriptRoot 'out\x64'),

  [switch]$TrustTestCertificate
)

$ErrorActionPreference = 'Stop'

function Assert-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window.'
  }
}

Assert-Administrator

if ([Environment]::OSVersion.Version.Build -lt 22000) {
  throw 'This experimental package currently requires Windows 11 build 22000 or newer.'
}

$inf = Join-Path $PackagePath 'TopologyAnchorDriver.inf'
$catalog = Join-Path $PackagePath 'TopologyAnchorDriver.cat'
$driver = Join-Path $PackagePath 'TopologyAnchorDriver.dll'
$controller = Join-Path $PackagePath 'TopologyAnchorController.exe'
$certificate = Join-Path $PackagePath 'TopologyAnchorTest.cer'

foreach ($requiredFile in @($inf, $catalog, $driver, $controller)) {
  if (-not (Test-Path -LiteralPath $requiredFile)) {
    throw "Required package file was not found: $requiredFile. Run .\build-anchor-driver.ps1 first."
  }
}

if ($TrustTestCertificate) {
  if (-not (Test-Path -LiteralPath $certificate)) {
    throw "Test certificate was not found: $certificate"
  }

  Write-Warning 'TrustTestCertificate changes the LocalMachine Root and TrustedPublisher certificate stores. Use it only for this controlled test build.'
  Import-Certificate -FilePath $certificate -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
  Import-Certificate -FilePath $certificate -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' | Out-Null
}

$signature = Get-AuthenticodeSignature -FilePath $catalog
if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
  throw @"
The driver catalog signature is not trusted: $($signature.Status) - $($signature.StatusMessage)

For a controlled local test build, rerun explicitly with:
  .\install-anchor-driver.ps1 -TrustTestCertificate

This script does not enable Windows test-signing mode or disable Secure Boot.
"@
}

& pnputil.exe /add-driver $inf /install | Out-Host
if ($LASTEXITCODE -ne 0) {
  throw "Driver package staging failed with exit code $LASTEXITCODE"
}

Write-Host 'Topology DDC Sleep Anchor driver package staged successfully.'
Write-Host 'No virtual display is connected yet.'
Write-Host 'Next: .\test-anchor-availability.ps1'
