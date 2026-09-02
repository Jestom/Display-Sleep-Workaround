param(
  [string]$TaskName = "Topology DDC Sleep Workaround",
  [Alias("TargetNeedle")]
  [string[]]$TargetNeedles = @(),
  [int]$TargetId = -1,
  [int]$TargetOutputTechnology = -1,
  [switch]$AllowMultipleTargets,
  [ValidateRange(1, 50)]
  [int]$RecentLogCount = 5
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$workaroundPath = Join-Path $root "topology-ddcci-workaround.ps1"
$statePath = Join-Path $root "state\topology-removal-pending.json"
$logDirectory = Join-Path $root "log"

Write-Output "[Scheduled task]"
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
  $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
  [pscustomobject]@{
    TaskName = $task.TaskName
    State = $task.State
    LastRunTime = $taskInfo.LastRunTime
    LastTaskResult = $taskInfo.LastTaskResult
    NextRunTime = $taskInfo.NextRunTime
    ExecutionTimeLimit = $task.Settings.ExecutionTimeLimit
    Action = (($task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join "; ")
  } | Format-List | Out-String | Write-Output
} else {
  Write-Output "Not installed: $TaskName"
}

Write-Output "[Listener processes]"
$listenerNames = @("topology-ddcci-workaround.ps1", "start-topology-ddcci-hidden.vbs")
$listeners = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  $process = $_
  $process.CommandLine -and ($listenerNames | Where-Object { $process.CommandLine -like "*$_*" })
})
if ($listeners.Count -gt 0) {
  $listeners | Select-Object ProcessId, ParentProcessId, Name, CommandLine | Format-List | Out-String | Write-Output
} else {
  Write-Output "No listener process found."
}

Write-Output "[Crash recovery]"
if (Test-Path -LiteralPath $statePath) {
  try {
    Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json | Format-List | Out-String | Write-Output
  } catch {
    Write-Warning "Recovery marker exists but is not valid JSON: $statePath"
  }
} else {
  Write-Output "No pending topology recovery marker."
}

Write-Output "[Active DisplayConfig topology]"
& $workaroundPath -ListDisplays -NoLog

$TargetNeedles = @($TargetNeedles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($TargetNeedles.Count -gt 0 -or $TargetId -ge 0 -or $TargetOutputTechnology -ge 0) {
  Write-Output "[Target preflight]"
  $arguments = @{
    CompileOnly = $true
    NoLog = $true
    TargetNeedles = $TargetNeedles
    TargetId = $TargetId
    TargetOutputTechnology = $TargetOutputTechnology
  }
  if ($AllowMultipleTargets) {
    $arguments.AllowMultipleTargets = $true
  }
  try {
    & $workaroundPath @arguments
  } catch {
    Write-Warning ("Target preflight failed: {0}" -f $_.Exception.Message)
  }
}

Write-Output "[Recent logs]"
if (Test-Path -LiteralPath $logDirectory) {
  $logs = @(Get-ChildItem -LiteralPath $logDirectory -File -Filter "*.log" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First $RecentLogCount)
  if ($logs.Count -gt 0) {
    $logs | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize | Out-String | Write-Output
  } else {
    Write-Output "No runtime logs found."
  }
} else {
  Write-Output "Log directory does not exist."
}
