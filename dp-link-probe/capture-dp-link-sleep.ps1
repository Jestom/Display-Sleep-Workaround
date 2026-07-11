[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [uint32]$TargetId,

  [ValidateRange(1, 900)]
  [int]$ObserveAfterDisplayOffSeconds = 120,

  [Alias('AdapterIndex')]
  [int]$MonitorIndex = -1,

  [string]$ControllerPath = (Join-Path $PSScriptRoot 'out\x64\TopologyDpProbeCtl.exe')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ControllerPath)) {
  throw "Controller not found: $ControllerPath"
}

$logRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'log\diagnostics'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $logRoot "$timestamp-dp-link-readonly.log"

if (-not ('TopologyDpProbe.NativeMethods' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace TopologyDpProbe
{
    public static class NativeMethods
    {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            uint msg,
            IntPtr wParam,
            IntPtr lParam,
            uint flags,
            uint timeout,
            out IntPtr result);
    }
}
'@
}

function Write-Log {
  param([string]$Message)

  $line = '{0:yyyy-MM-dd HH:mm:ss.fff} {1}' -f (Get-Date), $Message
  $line | Tee-Object -FilePath $logPath -Append
}

function Invoke-ProbeSnapshot {
  param([string]$Label)

  Write-Log "Snapshot=$Label"
  $arguments = @('snapshot', '--target', [string]$TargetId)
  if ($MonitorIndex -ge 0) {
    $arguments += @('--monitor', [string]$MonitorIndex)
  }

  & $ControllerPath @arguments 2>&1 |
    ForEach-Object { $_.ToString() } |
    Tee-Object -FilePath $logPath -Append
  Write-Log "SnapshotExitCode=$LASTEXITCODE"
}

function Set-MonitorPower {
  param([int]$State)

  $result = [IntPtr]::Zero
  $sendResult = [TopologyDpProbe.NativeMethods]::SendMessageTimeout(
    [IntPtr]0xffff,
    0x0112,
    [IntPtr]0xf170,
    [IntPtr]$State,
    0x0002,
    1000,
    [ref]$result)

  Write-Log "SC_MONITORPOWER state=$State sendResult=$sendResult lastError=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

$listenerNames = @(
  'topology-ddcci-workaround.ps1',
  'c340-topology-ddcci-workaround.ps1'
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
  }) -join '; '
  throw "A topology/DDC listener is running. Stop it before DP link capture. $summary"
}

Write-Log "Read-only DP link capture started. TargetId=$TargetId MonitorIndex=$MonitorIndex ObserveSeconds=$ObserveAfterDisplayOffSeconds"
Write-Log 'This capture invokes no DPCD write operation. A read can still cause the display miniport to service AUX and should be treated as an observation side effect.'

try {
  $listOutput = @(& $ControllerPath list 2>&1)
  $listExitCode = $LASTEXITCODE
  $listOutput |
    ForEach-Object { $_.ToString() } |
    Tee-Object -FilePath $logPath -Append
  if ($listExitCode -ne 0) {
    throw "DP interface gate failed with exit code $listExitCode. Do not run DPCD capture."
  }

  Invoke-ProbeSnapshot -Label 'before-display-off'
  Write-Log 'Requesting an explicit SC_MONITORPOWER off transition for the controlled A/B probe.'
  Set-MonitorPower -State 2
  Write-Log "No probe calls will be made for $ObserveAfterDisplayOffSeconds seconds."
  Start-Sleep -Seconds $ObserveAfterDisplayOffSeconds
  Invoke-ProbeSnapshot -Label 'after-display-off'
}
finally {
  Set-MonitorPower -State -1
  Write-Log "Capture finished. Log=$logPath"
}

[pscustomobject]@{
  TargetId = $TargetId
  MonitorIndex = $MonitorIndex
  ObserveAfterDisplayOffSeconds = $ObserveAfterDisplayOffSeconds
  Log = $logPath
}
