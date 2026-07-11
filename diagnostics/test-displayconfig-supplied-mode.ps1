[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$TargetNeedle,

  [ValidateRange(1, 900)]
  [int]$ObserveAfterDisplayOffSeconds = 30,

  [ValidateRange(0, 64)]
  [int]$MonitorIndex = 0,

  [ValidateRange(15, 120)]
  [int]$VisibilityConfirmationSeconds = 45,

  [UInt64]$PixelRate = 533160000,
  [UInt32]$HorizontalSyncNumerator = 148100,
  [UInt32]$HorizontalSyncDenominator = 1,
  [UInt32]$VerticalSyncNumerator = 100,
  [UInt32]$VerticalSyncDenominator = 1,

  [switch]$AllowChanges,

  [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$bridgePath = Join-Path $scriptRoot "SuppliedModeExperiment.cs"
$captureScriptPath = Join-Path $projectRoot "dp-link-probe\capture-dp-link-sleep.ps1"
$controllerPath = Join-Path $projectRoot "dp-link-probe\out\x64\TopologyDpProbeCtl.exe"
$logRoot = Join-Path $projectRoot "log\diagnostics"
$runToken = "{0}-ccd-supplied-mode" -f (Get-Date -Format "yyyyMMdd-HHmmss")
$experimentLog = Join-Path $logRoot "$runToken.log"
$watchdogMarker = Join-Path $logRoot "$runToken-watchdog.txt"
$script:WatchdogProcess = $null
$script:ApplyAttempted = $false

New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

function Write-ExperimentLog {
  param([string]$Message)

  $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
  Write-Host $line
  Add-Content -LiteralPath $experimentLog -Value $line -Encoding UTF8
}

function Write-ExperimentBlock {
  param(
    [string]$Title,
    [string]$Value
  )

  Write-ExperimentLog $Title
  foreach ($line in (($Value -split "`r?`n") | Where-Object { $_ -ne "" })) {
    Write-ExperimentLog ("  " + $line)
  }
}

function Test-IsAdministrator {
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentPowerShellPath {
  try {
    $path = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
      return $path
    }
  } catch {
  }
  return (Join-Path $PSHOME "powershell.exe")
}

function Assert-NoConflictingListener {
  $listenerNames = @(
    "topology-ddcci-workaround.ps1",
    "c340-topology-ddcci-workaround.ps1"
  )
  $listeners = @(Get-CimInstance Win32_Process | Where-Object {
    $process = $_
    $process.ProcessId -ne $PID -and
    $process.CommandLine -and
    ($listenerNames | Where-Object { $process.CommandLine -like "*$_*" })
  })
  if ($listeners.Count -gt 0) {
    $summary = ($listeners | ForEach-Object {
      "PID=$($_.ProcessId) Name=$($_.Name)"
    }) -join "; "
    throw "A topology/DDC listener is still running. Stop it before this experiment. $summary"
  }
}

function Start-RecoveryWatchdog {
  $powershellPath = Get-CurrentPowerShellPath
  $displaySwitchPath = Join-Path $env:windir "System32\DisplaySwitch.exe"
  $watchdogDelaySeconds = $VisibilityConfirmationSeconds + 15
  $escapedMarker = $watchdogMarker.Replace("'", "''")
  $escapedDisplaySwitch = $displaySwitchPath.Replace("'", "''")
  $command = "Start-Sleep -Seconds $watchdogDelaySeconds; Add-Content -LiteralPath '$escapedMarker' -Value ('Watchdog fired at ' + (Get-Date -Format o)); Start-Process -FilePath '$escapedDisplaySwitch' -ArgumentList '/extend' -WindowStyle Hidden"
  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

  $script:WatchdogProcess = Start-Process `
    -FilePath $powershellPath `
    -ArgumentList @(
      "-NoLogo",
      "-NoProfile",
      "-WindowStyle", "Hidden",
      "-EncodedCommand", $encodedCommand
    ) `
    -WindowStyle Hidden `
    -PassThru
  Write-ExperimentLog "Recovery watchdog armed. ProcessId=$($script:WatchdogProcess.Id) DelaySeconds=$watchdogDelaySeconds"
}

function Stop-RecoveryWatchdog {
  if (-not $script:WatchdogProcess) {
    return
  }

  try {
    if (-not $script:WatchdogProcess.HasExited) {
      Stop-Process -Id $script:WatchdogProcess.Id -Force -ErrorAction Stop
      Write-ExperimentLog "Recovery watchdog cancelled. ProcessId=$($script:WatchdogProcess.Id)"
    }
  } catch {
    Write-ExperimentLog "Recovery watchdog cancellation failed: $($_.Exception.Message)"
  } finally {
    $script:WatchdogProcess = $null
  }
}

function Wait-ForVisibleDisplayConfirmation {
  Write-Host ""
  Write-Host "The supplied mode was applied and the screen may blink."
  Write-Host "After the image is fully visible, press ENTER within $VisibilityConfirmationSeconds seconds."
  Write-Host "If the display remains blank, do not press anything; automatic recovery will run."
  Write-Host ""

  $deadline = (Get-Date).AddSeconds($VisibilityConfirmationSeconds)
  try {
    while ((Get-Date) -lt $deadline) {
      if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter) {
          Write-ExperimentLog "User confirmed that the display image is visible after supplied-mode apply."
          return $true
        }
      }
      Start-Sleep -Milliseconds 100
    }
  } catch {
    throw "Timed visibility confirmation requires an interactive ConsoleHost: $($_.Exception.Message)"
  }

  Write-ExperimentLog "Visibility confirmation timed out; recovery watchdog is being allowed to fire."
  return $false
}

if (-not (Test-Path -LiteralPath $bridgePath)) {
  throw "Supplied-mode bridge not found: $bridgePath"
}
if (-not (Test-IsAdministrator)) {
  throw "Run this experiment from an elevated PowerShell window."
}
if ($Host.Name -ne "ConsoleHost") {
  throw "Run this experiment from an interactive PowerShell ConsoleHost. Host=$($Host.Name)"
}
if (-not $ValidateOnly) {
  if (-not (Test-Path -LiteralPath $captureScriptPath)) {
    throw "DP link capture script not found: $captureScriptPath"
  }
  if (-not (Test-Path -LiteralPath $controllerPath)) {
    throw "DP link probe controller not found: $controllerPath"
  }
}

Assert-NoConflictingListener

if (-not ("TopologyDdcci.SuppliedModeV2.ModeControl" -as [type])) {
  Add-Type -Path $bridgePath
}

try {
  Write-ExperimentLog "CCD supplied-mode experiment started. TargetNeedle=$TargetNeedle ValidateOnly=$ValidateOnly AllowChanges=$AllowChanges"
  Write-ExperimentLog "Requested timing: pixelRate=$PixelRate h=$HorizontalSyncNumerator/$HorizontalSyncDenominator v=$VerticalSyncNumerator/$VerticalSyncDenominator"
  Write-ExperimentLog "Safety: one active path only, exact post-apply readback, no SDC_SAVE_TO_DATABASE, finally restore, external DisplaySwitch watchdog."
  Write-ExperimentBlock "DisplayConfig before validation" ([TopologyDdcci.SuppliedModeV2.ModeControl]::DumpActive())

  $targetId = [TopologyDdcci.SuppliedModeV2.ModeControl]::GetSingleTargetId($TargetNeedle)
  $validationResult = [TopologyDdcci.SuppliedModeV2.ModeControl]::ValidateSupplied(
    $TargetNeedle,
    $PixelRate,
    $HorizontalSyncNumerator,
    $HorizontalSyncDenominator,
    $VerticalSyncNumerator,
    $VerticalSyncDenominator,
    [bool]$AllowChanges)
  Write-ExperimentLog "Validation result: $validationResult"

  if ($ValidateOnly) {
    Write-ExperimentLog "ValidateOnly completed. No display mode was applied."
    return
  }

  $probeList = @(& $controllerPath list 2>&1)
  $probeListExitCode = $LASTEXITCODE
  Write-ExperimentBlock "DP probe interface gate" (($probeList | ForEach-Object { $_.ToString() }) -join "`r`n")
  if ($probeListExitCode -ne 0) {
    throw "DP probe interface gate failed with exit code $probeListExitCode. No mode was applied."
  }

  Start-RecoveryWatchdog
  $script:ApplyAttempted = $true
  $applyResult = [TopologyDdcci.SuppliedModeV2.ModeControl]::ApplySupplied(
    $TargetNeedle,
    $PixelRate,
    $HorizontalSyncNumerator,
    $HorizontalSyncDenominator,
    $VerticalSyncNumerator,
    $VerticalSyncDenominator,
    [bool]$AllowChanges)
  Write-ExperimentLog "Apply result: $applyResult"
  Start-Sleep -Seconds 3
  Write-ExperimentBlock "DisplayConfig after supplied-mode apply" ([TopologyDdcci.SuppliedModeV2.ModeControl]::DumpActive())

  if (-not (Wait-ForVisibleDisplayConfirmation)) {
    Write-ExperimentLog "Immediate fallback: running DisplaySwitch.exe /extend"
    Start-Process `
      -FilePath (Join-Path $env:windir "System32\DisplaySwitch.exe") `
      -ArgumentList "/extend" `
      -WindowStyle Hidden
    Start-Sleep -Seconds 3
    throw "Display visibility was not confirmed. The DPCD sleep capture was not started."
  }
  Stop-RecoveryWatchdog

  Write-ExperimentLog "Starting controlled DPCD sleep capture. TargetId=$targetId MonitorIndex=$MonitorIndex ObserveSeconds=$ObserveAfterDisplayOffSeconds"
  & $captureScriptPath `
    -TargetId $targetId `
    -MonitorIndex $MonitorIndex `
    -ObserveAfterDisplayOffSeconds $ObserveAfterDisplayOffSeconds `
    -ControllerPath $controllerPath
  if ($LASTEXITCODE -ne 0) {
    throw "DPCD sleep capture failed with exit code $LASTEXITCODE."
  }
  Write-ExperimentLog "Controlled DPCD sleep capture completed."
} catch {
  Write-ExperimentLog "Experiment failed: $($_.Exception.Message)"
  throw
} finally {
  Stop-RecoveryWatchdog
  if ($script:ApplyAttempted) {
    try {
      Write-ExperimentLog ([TopologyDdcci.SuppliedModeV2.ModeControl]::RestoreOriginal())
      Start-Sleep -Seconds 3
      Write-ExperimentBlock "DisplayConfig after original restore" ([TopologyDdcci.SuppliedModeV2.ModeControl]::DumpActive())
    } catch {
      Write-ExperimentLog "Exact DisplayConfig restore failed: $($_.Exception.Message)"
      Write-ExperimentLog "Fallback: running DisplaySwitch.exe /extend"
      Start-Process `
        -FilePath (Join-Path $env:windir "System32\DisplaySwitch.exe") `
        -ArgumentList "/extend" `
        -WindowStyle Hidden
    }
  }
  Write-ExperimentLog "Experiment finished. Log=$experimentLog"
}
