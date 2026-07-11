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
  [Alias("TargetNeedle")]
  [string[]]$TargetNeedles = @(),
  [int]$TargetId = -1,
  [int]$TargetOutputTechnology = -1,
  [string]$ProfileName = "Display",
  [string]$LogFilePrefix = "display-topology-ddcci",
  [switch]$EnableLog
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $root "topology-ddcci-workaround.ps1"
$launcherPath = Join-Path $root "start-topology-ddcci-hidden.vbs"

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
  TargetNeedles = $TargetNeedles
  TargetId = $TargetId
  TargetOutputTechnology = $TargetOutputTechnology
  ProfileName = $ProfileName
  LogFilePrefix = $LogFilePrefix
  TriggerMode = $TriggerMode
  IdleTimeoutSeconds = $IdleTimeoutSeconds
  IdlePollMilliseconds = $IdlePollMilliseconds
}
& $scriptPath @compileArguments | Out-Null

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
  "-LogFilePrefix", "$LogFilePrefix"
)

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
  -ExecutionTimeLimit (New-TimeSpan -Days 30) `
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
if ($StartNow) {
  if ($registered) {
    Start-ScheduledTask -TaskName $TaskName
  } else {
    Start-Process -FilePath "$env:windir\System32\wscript.exe" -ArgumentList $actionArgs -WindowStyle Hidden
    $hiddenLauncherStarted = $true
  }
  Start-Sleep -Seconds 1
}

Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName,State,TaskPath,@{Name="RegistrationUpdated";Expression={$registered}},@{Name="HiddenLauncherStarted";Expression={$hiddenLauncherStarted}},@{Name="TriggerMode";Expression={$TriggerMode}},@{Name="IdleTimeoutSeconds";Expression={$IdleTimeoutSeconds}},@{Name="RemainingDisplayPowerMode";Expression={$RemainingDisplayPowerMode}},@{Name="LoggingEnabled";Expression={[bool]$EnableLog}}
