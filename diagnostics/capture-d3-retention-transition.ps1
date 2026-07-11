[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [uint32]$TargetId,

  [ValidateRange(5, 35)]
  [int]$ObserveAfterDisplayOffSeconds = 20,

  [ValidateRange(0, 64)]
  [int]$MonitorIndex = 0,

  [string]$Label = "",

  [switch]$NoArchive
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$captureScriptPath = Join-Path $scriptRoot "capture-natural-display-sleep.ps1"
$controllerPath = Join-Path $projectRoot "dp-link-probe\out\x64\TopologyDpProbeCtl.exe"

if (-not (Test-Path -LiteralPath $captureScriptPath)) {
  throw "Display-sleep capture script not found: $captureScriptPath"
}
if (-not (Test-Path -LiteralPath $controllerPath)) {
  throw "DP link probe controller not found: $controllerPath"
}
if ([string]::IsNullOrWhiteSpace($Label)) {
  $Label = "d3-retention-boundary-${ObserveAfterDisplayOffSeconds}s"
}

$captureParameters = @{
  Label = $Label
  DisplayPowerTrigger = "Off"
  TriggerAfterSeconds = 3
  ObserveAfterDisplayOffSeconds = $ObserveAfterDisplayOffSeconds
  PostWakeCaptureSeconds = 2
  MaxWaitForDisplayOffSeconds = 60
  CaptureDpcd = $true
  DpcdTargetId = $TargetId
  DpcdMonitorIndex = $MonitorIndex
  DpcdControllerPath = $controllerPath
  KeepExpandedTrace = $true
}
if ($NoArchive) {
  $captureParameters.NoArchive = $true
}

& $captureScriptPath @captureParameters
if ($LASTEXITCODE -ne 0) {
  throw "Synchronized D3-retention capture failed with exit code $LASTEXITCODE."
}
