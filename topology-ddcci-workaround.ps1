param(
  [int]$ApplyDelayMilliseconds = 0,
  [int]$WakeDebounceSeconds = 8,
  [int]$RestoreWakeDelayMilliseconds = 1200,
  [int]$DisplayRestoreRetryCount = 3,
  [int]$DisplayRestoreRetryDelayMilliseconds = 1000,
  [int]$DdcPowerOnRetryCount = 8,
  [int]$DdcPowerOnRetryDelayMilliseconds = 750,
  [ValidateSet("DdcciAllRemaining", "Disabled")]
  [string]$RemainingDisplayPowerMode = "Disabled",
  [ValidateSet("IdlePreempt", "PowerEvent")]
  [string]$TriggerMode = "PowerEvent",
  [ValidateRange(0, 2147483)]
  [int]$IdleTimeoutSeconds = 0,
  [ValidateRange(100, 60000)]
  [int]$IdlePollMilliseconds = 500,
  [switch]$ExperimentalAllowZeroActivePaths,
  [ValidateRange(30, 86400)]
  [int]$EmergencyRestoreSeconds = 240,
  [int]$TriggerDpmsAfterSeconds = 0,
  [int]$AutoRestoreAfterSeconds = 0,
  [switch]$TestOnce,
  [switch]$CompileOnly,
  [switch]$ListDisplays,
  [switch]$NoLog,
  [Alias("TargetNeedle")]
  [string[]]$TargetNeedles = @(),
  [int]$TargetId = -1,
  [int]$TargetOutputTechnology = -1,
  [string]$ProfileName = "Display",
  [string]$LogFilePrefix = "display-topology-ddcci",
  [string]$LogPath = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$coreScript = Join-Path $root "topology-ddcci-core.ps1"

if (-not (Test-Path -LiteralPath $coreScript)) {
  throw "Core topology/DDC script not found: $coreScript"
}

$TargetNeedles = @($TargetNeedles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if (-not $CompileOnly -and -not $ListDisplays -and $TargetNeedles.Count -eq 0 -and $TargetId -lt 0 -and $TargetOutputTechnology -lt 0) {
  throw "A target display criterion is required. Run with -ListDisplays, then pass -TargetNeedles, -TargetId, or -TargetOutputTechnology."
}
if (-not $CompileOnly -and -not $ListDisplays -and @($TargetNeedles | Where-Object { $_ -match "YOUR_MONITOR_ID" }).Count -gt 0) {
  throw "TargetNeedles still contains the README placeholder YOUR_MONITOR_ID. Run with -ListDisplays and replace it with the actual monitor ID."
}
if ($TriggerMode -eq "IdlePreempt" -and $TriggerDpmsAfterSeconds -gt 0) {
  throw "Use -IdleTimeoutSeconds for IdlePreempt tests. TriggerDpmsAfterSeconds is available only with -TriggerMode PowerEvent."
}

if (-not $CompileOnly -and -not $ListDisplays) {
  $listenerScriptNames = @("topology-ddcci-workaround.ps1", "c340-topology-ddcci-workaround.ps1")
  $otherListeners = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
    $process = $_
    $process.ProcessId -ne $PID -and
    $process.CommandLine -and
    ($listenerScriptNames | Where-Object { $process.CommandLine -like "*$_*" })
  })
  if ($otherListeners.Count -gt 0) {
    $processSummary = ($otherListeners | ForEach-Object { "PID=$($_.ProcessId) Name=$($_.Name)" }) -join "; "
    throw "Another topology/DDC listener is already running. Stop the installed or legacy task before starting this instance. $processSummary"
  }
}

$arguments = @{
  Listen = $true
  ApplyDelayMilliseconds = $ApplyDelayMilliseconds
  WakeDebounceSeconds = $WakeDebounceSeconds
  RestoreWakeDelayMilliseconds = $RestoreWakeDelayMilliseconds
  DisplayRestoreRetryCount = $DisplayRestoreRetryCount
  DisplayRestoreRetryDelayMilliseconds = $DisplayRestoreRetryDelayMilliseconds
  DdcPowerOnRetryCount = $DdcPowerOnRetryCount
  DdcPowerOnRetryDelayMilliseconds = $DdcPowerOnRetryDelayMilliseconds
  RemainingDisplayPowerMode = $RemainingDisplayPowerMode
  TriggerMode = $TriggerMode
  IdleTimeoutSeconds = $IdleTimeoutSeconds
  IdlePollMilliseconds = $IdlePollMilliseconds
  EmergencyRestoreSeconds = $EmergencyRestoreSeconds
  TargetNeedles = $TargetNeedles
  TargetId = $TargetId
  TargetOutputTechnology = $TargetOutputTechnology
  ProfileName = $ProfileName
  LogFilePrefix = $LogFilePrefix
}

if ($TriggerDpmsAfterSeconds -gt 0) {
  $arguments.TriggerDpmsAfterSeconds = $TriggerDpmsAfterSeconds
}

if ($AutoRestoreAfterSeconds -gt 0) {
  $arguments.AutoRestoreAfterSeconds = $AutoRestoreAfterSeconds
}

if ($TestOnce) {
  $arguments.TestOnce = $true
}

if ($ExperimentalAllowZeroActivePaths) {
  $arguments.ExperimentalAllowZeroActivePaths = $true
}

if ($CompileOnly) {
  $arguments.CompileOnly = $true
}

if ($ListDisplays) {
  $arguments.ListDisplays = $true
}

if ($NoLog) {
  $arguments.NoLog = $true
}

if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
  $arguments.LogPath = $LogPath
}

& $coreScript @arguments
