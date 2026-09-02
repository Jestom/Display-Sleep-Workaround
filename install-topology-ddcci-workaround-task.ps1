param(
  [switch]$StartNow,
  [string]$TaskName = "Topology DDC Sleep Workaround",
  [int]$WakeDebounceSeconds = 8,
  [int]$ApplyDelayMilliseconds = 0,
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
  [switch]$AllowMultipleTargets,
  [Alias("TargetNeedle")]
  [string[]]$TargetNeedles = @(),
  [int]$TargetId = -1,
  [int]$TargetOutputTechnology = -1,
  [string]$ProfileName = "Display",
  [string]$LogFilePrefix = "display-topology-ddcci",
  [ValidateRange(0, 36500)]
  [int]$LogRetentionDays = 30,
  [ValidateRange(0, 100000)]
  [int]$LogMaxFiles = 100,
  [ValidateRange(3, 120)]
  [int]$StartVerificationSeconds = 15,
  [switch]$EnableLog
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $root "topology-ddcci-workaround.ps1"
$launcherPath = Join-Path $root "start-topology-ddcci-hidden.vbs"
$recoveryStatePath = Join-Path $root "state\topology-removal-pending.json"

if (-not (Test-Path -LiteralPath $scriptPath)) {
  throw "Workaround script not found: $scriptPath"
}

if (-not (Test-Path -LiteralPath $launcherPath)) {
  throw "Hidden launcher not found: $launcherPath"
}

$TargetNeedles = @($TargetNeedles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($TargetNeedles.Count -eq 0 -and $TargetId -lt 0 -and $TargetOutputTechnology -lt 0) {
  throw "A target display criterion is required. Run .\topology-ddcci-workaround.ps1 -ListDisplays -NoLog, then install with -TargetNeedles, -TargetId, or -TargetOutputTechnology."
}
if (@($TargetNeedles | Where-Object { $_ -match "YOUR_MONITOR_ID" }).Count -gt 0) {
  throw "TargetNeedles still contains the README placeholder YOUR_MONITOR_ID. Run -ListDisplays and replace it with the actual monitor ID."
}

$compileArguments = @{
  CompileOnly = $true
  NoLog = $true
  TargetNeedles = $TargetNeedles
  TargetId = $TargetId
  TargetOutputTechnology = $TargetOutputTechnology
  ProfileName = $ProfileName
  LogFilePrefix = $LogFilePrefix
  TriggerMode = $TriggerMode
  IdleTimeoutSeconds = $IdleTimeoutSeconds
  IdlePollMilliseconds = $IdlePollMilliseconds
  LogRetentionDays = $LogRetentionDays
  LogMaxFiles = $LogMaxFiles
}
if ($AllowMultipleTargets) {
  $compileArguments.AllowMultipleTargets = $true
}
& $scriptPath @compileArguments | Out-Null

function Get-TopologyDdcciListenerProcess {
  return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $process = $_
    $process.ProcessId -ne $PID -and
    $process.CommandLine -and
    $process.CommandLine.IndexOf($scriptPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
  })
}

function Stop-TopologyDdcciListenerProcess {
  $needles = @(
    "topology-ddcci-workaround.ps1",
    "start-topology-ddcci-hidden.vbs",
    "c340-topology-ddcci-workaround.ps1",
    "start-c340-topology-ddcci-hidden.vbs"
  )
  Get-CimInstance Win32_Process |
    Where-Object {
      $process = $_
      $process.ProcessId -ne $PID -and
      $process.CommandLine -and
      ($needles | Where-Object { $process.CommandLine -like "*$_*" })
    } |
    ForEach-Object {
      try {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
        Write-Output "Stopped existing listener process: $($_.ProcessId)"
      } catch {
        Write-Warning ("Could not stop existing listener process {0}: {1}" -f $_.ProcessId, $_.Exception.Message)
      }
    }
}

function Complete-PendingTopologyRecoveryAfterListenerStop {
  if (-not (Test-Path -LiteralPath $recoveryStatePath)) {
    return
  }

  for ($attempt = 1; $attempt -le 20 -and (Test-Path -LiteralPath $recoveryStatePath); $attempt++) {
    Start-Sleep -Milliseconds 500
  }
  if (-not (Test-Path -LiteralPath $recoveryStatePath)) {
    return
  }

  Write-Warning "The stopped listener left a pending topology marker. Running DisplaySwitch.exe /extend before task registration."
  $displaySwitchPath = Join-Path $env:windir "System32\DisplaySwitch.exe"
  $recovery = Start-Process -FilePath $displaySwitchPath -ArgumentList "/extend" -WindowStyle Hidden -PassThru
  $recovery.WaitForExit()
  Remove-Item -LiteralPath $recoveryStatePath -Force -ErrorAction Stop
  Write-Output "Pending topology recovery completed before task registration."
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

$legacyTaskNames = @("C340 Topology DDC Sleep Workaround", "C340 DPMS NVIDIA Workaround")
foreach ($legacyTaskName in $legacyTaskNames) {
  if ($TaskName -ne $legacyTaskName) {
    $legacyTask = Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
    if ($legacyTask) {
      Stop-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
      try {
        Disable-ScheduledTask -TaskName $legacyTaskName -ErrorAction Stop | Out-Null
        Write-Warning "Disabled legacy scheduled task to prevent two topology listeners from running: $legacyTaskName"
      } catch {
        throw "Could not disable conflicting legacy scheduled task '$legacyTaskName': $($_.Exception.Message)"
      }
    }
  }
}

Stop-TopologyDdcciListenerProcess
Complete-PendingTopologyRecoveryAfterListenerStop

$actionArgs = @(
  "//B",
  "//Nologo",
  "$launcherPath",
  "-WakeDebounceSeconds", "$WakeDebounceSeconds",
  "-ApplyDelayMilliseconds", "$ApplyDelayMilliseconds",
  "-RestoreWakeDelayMilliseconds", "$RestoreWakeDelayMilliseconds",
  "-DisplayRestoreRetryCount", "$DisplayRestoreRetryCount",
  "-DisplayRestoreRetryDelayMilliseconds", "$DisplayRestoreRetryDelayMilliseconds",
  "-DdcPowerOnRetryCount", "$DdcPowerOnRetryCount",
  "-DdcPowerOnRetryDelayMilliseconds", "$DdcPowerOnRetryDelayMilliseconds",
  "-RemainingDisplayPowerMode", "$RemainingDisplayPowerMode",
  "-TriggerMode", "$TriggerMode",
  "-IdleTimeoutSeconds", "$IdleTimeoutSeconds",
  "-IdlePollMilliseconds", "$IdlePollMilliseconds",
  "-ProfileName", "$ProfileName",
  "-LogFilePrefix", "$LogFilePrefix",
  "-LogRetentionDays", "$LogRetentionDays",
  "-LogMaxFiles", "$LogMaxFiles"
)

if ($AllowMultipleTargets) {
  $actionArgs += "-AllowMultipleTargets"
}

if ($TargetNeedles.Count -gt 0) {
  $actionArgs += "-TargetNeedles"
  foreach ($needle in $TargetNeedles) {
    if (-not [string]::IsNullOrWhiteSpace($needle)) {
      $actionArgs += "$needle"
    }
  }
}

if ($TargetId -ge 0) {
  $actionArgs += "-TargetId"
  $actionArgs += "$TargetId"
}

if ($TargetOutputTechnology -ge 0) {
  $actionArgs += "-TargetOutputTechnology"
  $actionArgs += "$TargetOutputTechnology"
}

if (-not $EnableLog) {
  $actionArgs += "-NoLog"
}

function Quote-TaskArgument($Value) {
  $text = [string]$Value
  if ($text -notmatch '[\s"]') {
    return $text
  }
  return '"' + $text.Replace('"', '\"') + '"'
}

$actionArgs = ($actionArgs | ForEach-Object { Quote-TaskArgument $_ }) -join " "

$action = New-ScheduledTaskAction -Execute "$env:windir\System32\wscript.exe" -Argument $actionArgs
$trigger = New-ScheduledTaskTrigger -AtLogOn -User ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -MultipleInstances IgnoreNew `
  -RestartCount 3 `
  -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal `
  -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
  -LogonType Interactive `
  -RunLevel Limited

$registered = $false
try {
  Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Remove a selected display target using the configured Windows power-event or idle-preempt trigger, with optional DDC/CI for remaining displays." `
    -Force `
    -ErrorAction Stop | Out-Null
  $registered = $true
} catch {
  if ($existing) {
    Write-Warning ("Could not update the existing scheduled task registration: {0}" -f $_.Exception.Message)
    Write-Warning "The existing task registration was not changed. Run this installer from an elevated PowerShell window to update the task."
  } else {
    throw
  }
}

$hiddenLauncherStarted = $false
$listenerStarted = $false
$listenerProcessId = $null
if ($StartNow) {
  if ($registered) {
    Start-ScheduledTask -TaskName $TaskName
  } else {
    Start-Process -FilePath "$env:windir\System32\wscript.exe" -ArgumentList $actionArgs -WindowStyle Hidden
    $hiddenLauncherStarted = $true
  }
  $deadline = (Get-Date).AddSeconds($StartVerificationSeconds)
  $stableChecks = 0
  while ((Get-Date) -lt $deadline) {
    $listenerProcesses = @(Get-TopologyDdcciListenerProcess)
    if ($listenerProcesses.Count -gt 0) {
      $stableChecks++
      if ($stableChecks -ge 2) {
        $listenerStarted = $true
        $listenerProcessId = $listenerProcesses[0].ProcessId
        break
      }
    } else {
      $stableChecks = 0
    }
    Start-Sleep -Milliseconds 500
  }

  if (-not $listenerStarted) {
    $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    throw "The scheduled task was started, but no stable topology/DDC listener process was detected within $StartVerificationSeconds seconds. LastTaskResult=$($taskInfo.LastTaskResult). Run .\get-topology-ddcci-workaround-status.ps1 -TaskName '$TaskName' for diagnostics."
  }
}

Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName,State,TaskPath,@{Name="RegistrationUpdated";Expression={$registered}},@{Name="HiddenLauncherStarted";Expression={$hiddenLauncherStarted}},@{Name="ListenerStarted";Expression={$listenerStarted}},@{Name="ListenerProcessId";Expression={$listenerProcessId}},@{Name="TriggerMode";Expression={$TriggerMode}},@{Name="IdleTimeoutSeconds";Expression={$IdleTimeoutSeconds}},@{Name="AllowMultipleTargets";Expression={[bool]$AllowMultipleTargets}},@{Name="RemainingDisplayPowerMode";Expression={$RemainingDisplayPowerMode}},@{Name="LoggingEnabled";Expression={[bool]$EnableLog}},@{Name="LogRetentionDays";Expression={$LogRetentionDays}},@{Name="LogMaxFiles";Expression={$LogMaxFiles}}
