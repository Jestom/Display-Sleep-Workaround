param(
  [string]$TaskName = "Topology DDC Sleep Workaround"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$recoveryStatePath = Join-Path $root "state\topology-removal-pending.json"

function Stop-TopologyDdcciListenerProcess {
  $needles = @("topology-ddcci-workaround.ps1", "start-topology-ddcci-hidden.vbs")
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
        Write-Output "Stopped listener process: $($_.ProcessId)"
      } catch {
        Write-Warning ("Could not stop listener process {0}: {1}" -f $_.ProcessId, $_.Exception.Message)
      }
    }
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    Write-Output "Removed scheduled task: $TaskName"
  } catch {
    Write-Warning ("Could not unregister scheduled task: {0}" -f $_.Exception.Message)
  }
} else {
  Write-Output "Scheduled task was not installed: $TaskName"
}

Stop-TopologyDdcciListenerProcess

if (Test-Path -LiteralPath $recoveryStatePath) {
  for ($attempt = 1; $attempt -le 10 -and (Test-Path -LiteralPath $recoveryStatePath); $attempt++) {
    Start-Sleep -Milliseconds 500
  }
}

if (Test-Path -LiteralPath $recoveryStatePath) {
  Write-Warning "A pending topology recovery marker remained after listener shutdown. Running DisplaySwitch.exe /extend."
  $displaySwitchPath = Join-Path $env:windir "System32\DisplaySwitch.exe"
  $recovery = Start-Process -FilePath $displaySwitchPath -ArgumentList "/extend" -WindowStyle Hidden -PassThru
  $recovery.WaitForExit()
  Remove-Item -LiteralPath $recoveryStatePath -Force -ErrorAction Stop
  Write-Output "Pending topology recovery completed."
}
