# Historical diagnostic. The 2026-07-10 physical test rejected this strategy;
# it is retained for reproducibility and is not a production dependency.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$TargetNeedle,

  [string]$Label = "native-nvapi-force-commit-vidpn",

  [ValidateRange(20, 180)]
  [int]$ObserveAfterDisplayOffSeconds = 120,

  [ValidateRange(60, 3600)]
  [int]$MaxWaitForDisplayOffSeconds = 900,

  [ValidateRange(15, 120)]
  [int]$VisibilityConfirmationSeconds = 45,

  [switch]$QueryOnly,
  [switch]$SkipEtl,
  [switch]$KeepExpandedTrace,
  [switch]$NoArchive
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$bridgePath = Join-Path $scriptRoot "NvApiDisplayCommit.cs"
$captureScriptPath = Join-Path $scriptRoot "capture-natural-display-sleep.ps1"
$displayListScriptPath = Join-Path $projectRoot "topology-ddcci-workaround.ps1"
$logRoot = Join-Path $projectRoot "log\diagnostics"
$runToken = "{0}-nvapi-force-commit-vidpn" -f (Get-Date -Format "yyyyMMdd-HHmmss")
$experimentLog = Join-Path $logRoot "$runToken.log"
$watchdogMarker = Join-Path $logRoot "$runToken-watchdog.txt"
$script:WatchdogProcess = $null
$script:NvApiInitialized = $false
$script:CommitApplied = $false
$script:RecoveryInvoked = $false

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

function Get-ActiveDisplayConfigText {
  $powershellPath = Get-CurrentPowerShellPath
  $output = & $powershellPath `
    -NoLogo `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -STA `
    -File $displayListScriptPath `
    -ListDisplays `
    -NoLog 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "DisplayConfig listing failed with exit code $LASTEXITCODE. Output=$($output -join ' | ')"
  }
  return (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Assert-SingleMatchingDisplay {
  param([string]$DisplayConfigText)

  $pathLines = @(($DisplayConfigText -split "`r?`n") | Where-Object { $_ -match "^PATH\s+\d+\s" })
  if ($pathLines.Count -ne 1) {
    throw "This experiment requires exactly one active DisplayConfig path; found $($pathLines.Count)."
  }
  if ($pathLines[0].IndexOf($TargetNeedle, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw "The only active DisplayConfig path does not match TargetNeedle='$TargetNeedle'. Actual=$($pathLines[0])"
  }
}

function Get-NvidiaDisplayState {
  try {
    $result = & nvidia-smi.exe `
      --query-gpu=name,driver_version,pstate,display_active,display_mode,power.draw `
      --format=csv,noheader 2>&1
    if ($LASTEXITCODE -ne 0) {
      return "nvidia-smi query failed: $result"
    }
    return ([string]($result | Select-Object -First 1)).Trim()
  } catch {
    return "nvidia-smi query failed: $($_.Exception.Message)"
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

function Invoke-DisplayRecovery {
  $script:RecoveryInvoked = $true
  Write-ExperimentLog "Recovery: running DisplaySwitch.exe /extend"
  Start-Process `
    -FilePath (Join-Path $env:windir "System32\DisplaySwitch.exe") `
    -ArgumentList "/extend" `
    -WindowStyle Hidden
  Start-Sleep -Seconds 3
}

function Wait-ForVisibleDisplayConfirmation {
  Write-Host ""
  Write-Host "NVAPI re-submitted the exact current display configuration with NV_FORCE_COMMIT_VIDPN."
  Write-Host "After the image is fully visible, press ENTER within $VisibilityConfirmationSeconds seconds."
  Write-Host "If the display remains blank, do not press anything; automatic recovery will run."
  Write-Host ""

  $deadline = (Get-Date).AddSeconds($VisibilityConfirmationSeconds)
  try {
    while ((Get-Date) -lt $deadline) {
      if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter) {
          Write-ExperimentLog "User confirmed that the display image is visible after NVAPI force commit."
          return $true
        }
      }
      Start-Sleep -Milliseconds 100
    }
  } catch {
    throw "Timed visibility confirmation requires an interactive ConsoleHost: $($_.Exception.Message)"
  }

  Write-ExperimentLog "Visibility confirmation timed out."
  return $false
}

if (-not [Environment]::Is64BitProcess) {
  throw "Run this diagnostic from a 64-bit PowerShell process."
}
if (-not (Test-Path -LiteralPath $bridgePath)) {
  throw "NVAPI bridge source not found: $bridgePath"
}
if (-not (Test-Path -LiteralPath $displayListScriptPath)) {
  throw "DisplayConfig listing script not found: $displayListScriptPath"
}
if (-not $QueryOnly -and -not (Test-Path -LiteralPath $captureScriptPath)) {
  throw "Natural-sleep capture script not found: $captureScriptPath"
}
if (-not $QueryOnly -and -not $SkipEtl -and -not (Test-IsAdministrator)) {
  throw "Run this experiment from an elevated PowerShell window so ETW capture can start, or use -SkipEtl."
}
if (-not $QueryOnly -and $Host.Name -ne "ConsoleHost") {
  throw "Run this experiment from an interactive PowerShell ConsoleHost. Host=$($Host.Name)"
}

Assert-NoConflictingListener

if (-not ("TopologyDdcci.NvApiDiagnosticV1.NvApiDisplayCommit" -as [type])) {
  Add-Type -Path $bridgePath
}

if ([string]::IsNullOrWhiteSpace($Label)) {
  $Label = "native-nvapi-force-commit-vidpn"
}

$captureArguments = @(
  "-NoLogo",
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", $captureScriptPath,
  "-Label", $Label,
  "-ObserveAfterDisplayOffSeconds", "$ObserveAfterDisplayOffSeconds",
  "-MaxWaitForDisplayOffSeconds", "$MaxWaitForDisplayOffSeconds"
)
if ($SkipEtl) { $captureArguments += "-SkipEtl" }
if ($KeepExpandedTrace) { $captureArguments += "-KeepExpandedTrace" }
if ($NoArchive) { $captureArguments += "-NoArchive" }

try {
  Write-ExperimentLog "NVAPI force-CommitVidPn experiment started. TargetNeedle=$TargetNeedle QueryOnly=$QueryOnly"
  Write-ExperimentLog "This experiment does not create or save a custom resolution and does not change DisplayConfig topology."

  $displayConfigBefore = Get-ActiveDisplayConfigText
  Assert-SingleMatchingDisplay $displayConfigBefore
  Write-ExperimentBlock "DisplayConfig before NVAPI" $displayConfigBefore
  Write-ExperimentLog "NVIDIA before NVAPI: $(Get-NvidiaDisplayState)"

  Write-ExperimentLog ([TopologyDdcci.NvApiDiagnosticV1.NvApiDisplayCommit]::Initialize())
  $script:NvApiInitialized = $true
  Write-ExperimentBlock "NVAPI current configuration" ([TopologyDdcci.NvApiDiagnosticV1.NvApiDisplayCommit]::DumpCurrent())

  if ($QueryOnly) {
    Write-ExperimentLog "QueryOnly completed; no display configuration was applied."
    return
  }

  Start-RecoveryWatchdog
  # The native call can apply successfully and then fail during post-apply verification.
  # Mark the display as potentially changed before entering the bridge.
  $script:CommitApplied = $true
  $commitResult = [TopologyDdcci.NvApiDiagnosticV1.NvApiDisplayCommit]::ValidateAndForceCommitSingleDisplay()
  Write-ExperimentLog "NVAPI force-commit result: $commitResult"
  Start-Sleep -Seconds 3

  $displayConfigAfter = Get-ActiveDisplayConfigText
  Write-ExperimentBlock "DisplayConfig after NVAPI" $displayConfigAfter
  Write-ExperimentBlock "NVAPI configuration after force commit" ([TopologyDdcci.NvApiDiagnosticV1.NvApiDisplayCommit]::DumpCurrent())
  Write-ExperimentLog "NVIDIA after NVAPI: $(Get-NvidiaDisplayState)"
  if (-not [string]::Equals($displayConfigBefore, $displayConfigAfter, [StringComparison]::Ordinal)) {
    throw "The Windows DisplayConfig text changed after NVAPI force commit; natural-sleep capture is aborted."
  }

  if (-not (Wait-ForVisibleDisplayConfirmation)) {
    Invoke-DisplayRecovery
    throw "Display visibility was not confirmed. The natural-sleep capture was not started."
  }
  Stop-RecoveryWatchdog

  Write-ExperimentLog "Starting natural-sleep capture. Label=$Label ObserveAfterDisplayOffSeconds=$ObserveAfterDisplayOffSeconds"
  $powershellPath = Get-CurrentPowerShellPath
  & $powershellPath @captureArguments
  if ($LASTEXITCODE -ne 0) {
    throw "Natural-sleep capture failed with exit code $LASTEXITCODE."
  }
  Write-ExperimentLog "Natural-sleep capture completed. Label=$Label"
} catch {
  Write-ExperimentLog "Experiment failed: $($_.Exception.Message)"
  if ($script:CommitApplied -and -not $script:RecoveryInvoked) {
    try {
      Invoke-DisplayRecovery
    } catch {
      Write-ExperimentLog "Immediate display recovery failed: $($_.Exception.Message)"
    }
  }
  throw
} finally {
  Stop-RecoveryWatchdog
  if ($script:NvApiInitialized) {
    try {
      Write-ExperimentLog ([TopologyDdcci.NvApiDiagnosticV1.NvApiDisplayCommit]::Shutdown())
    } catch {
      Write-ExperimentLog "NvAPI_Unload failed: $($_.Exception.Message)"
    }
  }
  Write-ExperimentLog "Experiment finished. Log=$experimentLog"
}
