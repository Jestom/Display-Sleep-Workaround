[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$TargetNeedle,

  [ValidateSet("ListModes", "LowPower", "ModeTransition", "D3dKeepAlive")]
  [string]$Strategy = "ListModes",

  [uint32]$TemporaryWidth = 0,
  [uint32]$TemporaryHeight = 0,
  [uint32]$TemporaryRefreshRate = 0,

  [ValidateRange(100, 10000)]
  [int]$KeepAliveIntervalMilliseconds = 1000,

  [ValidateRange(1, 60)]
  [int]$TriggerAfterSeconds = 5,

  [ValidateRange(20, 180)]
  [int]$ObserveAfterDisplayOffSeconds = 120,

  [ValidateRange(60, 3600)]
  [int]$MaxWaitForDisplayOffSeconds = 900,

  [ValidateRange(15, 120)]
  [int]$VisibilityConfirmationSeconds = 45,

  [string]$Label = "",
  [switch]$CompileOnly,
  [switch]$SkipEtl,
  [switch]$KeepExpandedTrace,
  [switch]$NoArchive
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$bridgePath = Join-Path $scriptRoot "ActivePathSleepExperiment.cs"
$captureScriptPath = Join-Path $scriptRoot "capture-natural-display-sleep.ps1"
$logRoot = Join-Path $projectRoot "log\diagnostics"
$runToken = "{0}-active-path-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $Strategy.ToLowerInvariant()
$experimentLog = Join-Path $logRoot "$runToken.log"
$watchdogMarker = Join-Path $logRoot "$runToken-watchdog.txt"
$script:WatchdogProcess = $null
$modeTransition = $null
$d3dKeepAlive = $null

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
  $listenerNames = @("topology-ddcci-workaround.ps1", "c340-topology-ddcci-workaround.ps1")
  $listeners = @(Get-CimInstance Win32_Process | Where-Object {
    $process = $_
    $process.ProcessId -ne $PID -and
    $process.CommandLine -and
    ($listenerNames | Where-Object { $process.CommandLine -like "*$_*" })
  })
  if ($listeners.Count -gt 0) {
    $summary = ($listeners | ForEach-Object { "PID=$($_.ProcessId) Name=$($_.Name)" }) -join "; "
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
    -ArgumentList @("-NoLogo", "-NoProfile", "-WindowStyle", "Hidden", "-EncodedCommand", $encodedCommand) `
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
  Write-Host "A temporary display mode was applied and the screen may blink."
  Write-Host "After the image is fully visible, press ENTER within $VisibilityConfirmationSeconds seconds."
  Write-Host "If the display remains blank, do not press anything; automatic recovery will run."
  Write-Host ""

  $deadline = (Get-Date).AddSeconds($VisibilityConfirmationSeconds)
  try {
    while ((Get-Date) -lt $deadline) {
      if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter) {
          Write-ExperimentLog "User confirmed that the image is visible after the temporary mode transition."
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
  throw "Native experiment bridge not found: $bridgePath"
}
if (-not (Test-Path -LiteralPath $captureScriptPath)) {
  throw "Display-sleep capture script not found: $captureScriptPath"
}

if (-not ("TopologyDdcci.ActivePathExperimentV1.ActivePathInspector" -as [type])) {
  Add-Type -Path $bridgePath
}

if ($CompileOnly) {
  Write-Host "Active-path experiment bridge compiled successfully. ABI: $([TopologyDdcci.ActivePathExperimentV1.ActivePathInspector]::GetAbiSummary())"
  return
}

if ($Strategy -eq "ListModes") {
  [TopologyDdcci.ActivePathExperimentV1.ActivePathInspector]::ListModes($TargetNeedle)
  return
}

if (-not $SkipEtl -and -not (Test-IsAdministrator)) {
  throw "Run this experiment from an elevated PowerShell window so ETW capture can start, or use -SkipEtl."
}
if ($Strategy -eq "ModeTransition" -and $Host.Name -ne "ConsoleHost") {
  throw "Run the ModeTransition experiment from an interactive PowerShell ConsoleHost. Host=$($Host.Name)"
}
if ($Strategy -eq "ModeTransition" -and
    ($TemporaryWidth -eq 0 -or $TemporaryHeight -eq 0 -or $TemporaryRefreshRate -eq 0)) {
  throw "ModeTransition requires -TemporaryWidth, -TemporaryHeight, and -TemporaryRefreshRate. Run -Strategy ListModes first."
}

Assert-NoConflictingListener
$targetDescription = [TopologyDdcci.ActivePathExperimentV1.ActivePathInspector]::DescribeSingleTarget($TargetNeedle)

if ([string]::IsNullOrWhiteSpace($Label)) {
  $Label = switch ($Strategy) {
    "LowPower" { "active-path-low-power" }
    "ModeTransition" { "active-path-mode-transition-$TemporaryWidth`x$TemporaryHeight-$TemporaryRefreshRate`hz" }
    "D3dKeepAlive" { "active-path-d3d-keepalive" }
  }
}

$captureArguments = @(
  "-NoLogo",
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-STA",
  "-File", $captureScriptPath,
  "-Label", $Label,
  "-ObserveAfterDisplayOffSeconds", "$ObserveAfterDisplayOffSeconds",
  "-MaxWaitForDisplayOffSeconds", "$MaxWaitForDisplayOffSeconds"
)
if ($Strategy -eq "LowPower") {
  $captureArguments += @(
    "-DisplayPowerTrigger", "LowPower",
    "-TriggerAfterSeconds", "$TriggerAfterSeconds"
  )
}
if ($SkipEtl) { $captureArguments += "-SkipEtl" }
if ($KeepExpandedTrace) { $captureArguments += "-KeepExpandedTrace" }
if ($NoArchive) { $captureArguments += "-NoArchive" }

try {
  Write-ExperimentLog "Active-path display-sleep experiment started. Strategy=$Strategy TargetNeedle=$TargetNeedle Label=$Label"
  Write-ExperimentLog "No display path will be removed and no display configuration will be saved to the persistence database."
  Write-ExperimentLog "TARGET $targetDescription"

  switch ($Strategy) {
    "LowPower" {
      Write-ExperimentLog "The capture will send SC_MONITORPOWER state=1 after $TriggerAfterSeconds seconds."
    }
    "ModeTransition" {
      Write-ExperimentLog "Requested temporary mode: ${TemporaryWidth}x${TemporaryHeight} @ ${TemporaryRefreshRate}Hz"
      Start-RecoveryWatchdog
      $modeTransition = [TopologyDdcci.ActivePathExperimentV1.TemporaryDisplayMode]::Apply(
        $TargetNeedle,
        $TemporaryWidth,
        $TemporaryHeight,
        $TemporaryRefreshRate)
      Start-Sleep -Seconds 3
      Write-ExperimentLog "Temporary mode status: $($modeTransition.GetStatus())"
      if (-not (Wait-ForVisibleDisplayConfirmation)) {
        throw "Display visibility was not confirmed. The sleep capture was not started."
      }
      Stop-RecoveryWatchdog
    }
    "D3dKeepAlive" {
      $d3dKeepAlive = [TopologyDdcci.ActivePathExperimentV1.D3dKeepAlive]::Create($TargetNeedle)
      $d3dKeepAlive.Start($KeepAliveIntervalMilliseconds)
      Start-Sleep -Seconds 2
      $d3dKeepAlive.ThrowIfFailed()
      Write-ExperimentLog "D3D keep-alive started: $($d3dKeepAlive.GetStatus())"
      Write-ExperimentLog "The D3D device has no swap chain, window, present call, or DISPLAY_REQUIRED request."
    }
  }

  Write-ExperimentLog "Starting display-sleep capture. ObserveAfterDisplayOffSeconds=$ObserveAfterDisplayOffSeconds"
  $powershellPath = Get-CurrentPowerShellPath
  & $powershellPath @captureArguments
  if ($LASTEXITCODE -ne 0) {
    throw "Display-sleep capture failed with exit code $LASTEXITCODE."
  }
  Write-ExperimentLog "Display-sleep capture completed."
} catch {
  Write-ExperimentLog "Experiment failed: $($_.Exception.Message)"
  throw
} finally {
  Stop-RecoveryWatchdog
  if ($d3dKeepAlive) {
    try {
      Write-ExperimentLog "D3D keep-alive final status: $($d3dKeepAlive.GetStatus())"
      $d3dKeepAlive.Dispose()
      Write-ExperimentLog "D3D keep-alive stopped."
    } catch {
      Write-ExperimentLog "D3D keep-alive cleanup failed: $($_.Exception.Message)"
    }
  }
  if ($modeTransition) {
    try {
      Write-ExperimentLog ($modeTransition.Restore())
      $modeTransition.Dispose()
    } catch {
      Write-ExperimentLog "Temporary display mode restore failed: $($_.Exception.Message)"
      Write-ExperimentLog "Fallback: running DisplaySwitch.exe /extend"
      Start-Process -FilePath (Join-Path $env:windir "System32\DisplaySwitch.exe") -ArgumentList "/extend" -WindowStyle Hidden
    }
  }
  Write-ExperimentLog "Experiment finished. Log=$experimentLog"
}
