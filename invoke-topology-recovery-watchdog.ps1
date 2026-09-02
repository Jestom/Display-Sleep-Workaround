param(
  [Parameter(Mandatory = $true)]
  [int]$ParentProcessId,
  [Parameter(Mandatory = $true)]
  [string]$StatePath,
  [Parameter(Mandatory = $true)]
  [string]$RecoveryLogPath
)

$ErrorActionPreference = "Stop"

function Write-RecoveryLog($Message) {
  $parent = Split-Path -Parent $RecoveryLogPath
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
  Add-Content -LiteralPath $RecoveryLogPath -Value $line -Encoding UTF8
}

try {
  $parentProcess = Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue
  if ($parentProcess) {
    $parentProcess.WaitForExit()
  }

  if (-not (Test-Path -LiteralPath $StatePath)) {
    exit 0
  }

  Write-RecoveryLog "Listener process $ParentProcessId exited with a pending topology marker. Running DisplaySwitch.exe /extend."
  $displaySwitchPath = Join-Path $env:windir "System32\DisplaySwitch.exe"
  $process = Start-Process -FilePath $displaySwitchPath -ArgumentList "/extend" -WindowStyle Hidden -PassThru
  $process.WaitForExit()
  Remove-Item -LiteralPath $StatePath -Force -ErrorAction Stop
  Write-RecoveryLog "Crash recovery completed and the pending topology marker was removed."
} catch {
  try {
    Write-RecoveryLog ("Crash recovery failed: {0}" -f $_.Exception.Message)
  } catch {
  }
  exit 1
}
