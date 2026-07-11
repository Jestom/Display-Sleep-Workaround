[CmdletBinding()]
param(
  [string]$PackagePath = (Join-Path $PSScriptRoot 'out\x64'),

  [ValidateRange(5, 120)]
  [int]$StartupTimeoutSeconds = 30,

  [ValidateRange(1, 30)]
  [int]$ArrivalDelaySeconds = 5,

  [ValidateRange(5, 60)]
  [int]$CleanupTimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'

function Assert-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window.'
  }
}

function Write-TestLog {
  param([string]$Message)

  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
  Write-Host $line
  Add-Content -LiteralPath $script:TestLogPath -Value $line -Encoding UTF8
}

function Invoke-Inspection {
  param([string]$Path)

  & $script:InspectionScript -OutputPath $Path -IncludeAllPaths
  return Get-Content -LiteralPath $Path -Raw
}

function Get-AvailableAnchorLines {
  param([string]$InspectionText)

  return @($InspectionText -split "`r?`n" | Where-Object {
      $_ -match '\bANCHOR ' -and $_ -match '\btargetAvailable=True\b'
    })
}

function Get-ActivePhysicalTargetKeys {
  param([string]$InspectionText)

  $keys = foreach ($line in ($InspectionText -split "`r?`n")) {
    if ($line -notmatch '\bPATH \d+ active=True\b') {
      continue
    }
    if ($line -match 'adapterPath=.*TopologyDdcciAnchor') {
      continue
    }
    if ($line -match '\btargetKey=([^\s]+)') {
      $Matches[1]
    }
  }

  return @($keys | Sort-Object -Unique)
}

function Format-KeySet {
  param([string[]]$Keys)

  if ($Keys.Count -eq 0) {
    return '<none>'
  }
  return ($Keys -join ',')
}

$workRoot = Split-Path -Parent $PSScriptRoot
$script:InspectionScript = Join-Path $workRoot 'diagnostics\inspect-displayconfig-anchor-candidates.ps1'
$controller = Join-Path $PackagePath 'TopologyAnchorController.exe'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logRoot = Join-Path $workRoot 'log\anchor-driver'
$diagnosticLogRoot = Join-Path $workRoot 'log\diagnostics'
$script:TestLogPath = Join-Path $logRoot "$timestamp-anchor-availability-test.log"
$controllerStdout = Join-Path $logRoot "$timestamp-anchor-controller.stdout.log"
$controllerStderr = Join-Path $logRoot "$timestamp-anchor-controller.stderr.log"
$controllerFailsafeSeconds = 120
$baselineLog = Join-Path $diagnosticLogRoot "$timestamp-anchor-baseline.log"
$connectedLog = Join-Path $diagnosticLogRoot "$timestamp-anchor-connected.log"
$cleanupLog = Join-Path $diagnosticLogRoot "$timestamp-anchor-cleanup.log"

Assert-Administrator

New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
New-Item -ItemType Directory -Path $diagnosticLogRoot -Force | Out-Null

if (-not (Test-Path -LiteralPath $controller)) {
  throw "Controller was not found: $controller. Build and install the anchor package first."
}
if (-not (Test-Path -LiteralPath $script:InspectionScript)) {
  throw "Inspection script was not found: $script:InspectionScript"
}

$existingController = @(Get-Process -Name 'TopologyAnchorController' -ErrorAction SilentlyContinue)
if ($existingController.Count -gt 0) {
  throw 'A TopologyAnchorController process is already running. Stop it before starting this isolated test.'
}

$controllerProcess = $null
$capturedFailure = $null
$baselinePhysicalTargets = @()

Write-TestLog 'Anchor availability test started. This script does not call SetDisplayConfig.'
try {
  Write-TestLog 'Capturing baseline DisplayConfig state.'
  $baselineText = Invoke-Inspection -Path $baselineLog
  $baselineAvailableAnchors = Get-AvailableAnchorLines -InspectionText $baselineText
  if ($baselineAvailableAnchors.Count -ne 0) {
    throw "Baseline already contains $($baselineAvailableAnchors.Count) available TopologyDdcciAnchor target(s)."
  }

  $baselinePhysicalTargets = Get-ActivePhysicalTargetKeys -InspectionText $baselineText
  if ($baselinePhysicalTargets.Count -eq 0) {
    throw 'No active physical DisplayConfig target was found in the baseline.'
  }
  Write-TestLog "Baseline active physical targets=$(Format-KeySet -Keys $baselinePhysicalTargets)"

  Write-TestLog 'Starting the temporary software-device controller.'
  $controllerProcess = Start-Process `
    -FilePath $controller `
    -ArgumentList '--duration-seconds', ([string]$controllerFailsafeSeconds) `
    -RedirectStandardOutput $controllerStdout `
    -RedirectStandardError $controllerStderr `
    -WindowStyle Hidden `
    -PassThru

  $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
  $ready = $false
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $controllerStdout) {
      $readyText = Get-Content -LiteralPath $controllerStdout -Raw -ErrorAction SilentlyContinue
      if ($readyText -match '(?m)^READY device=') {
        $ready = $true
        break
      }
    }
    if ($controllerProcess.HasExited) {
      break
    }
    Start-Sleep -Milliseconds 250
  }

  if (-not $ready) {
    $stderrText = ''
    $exitSummary = '<still-running>'
    if (Test-Path -LiteralPath $controllerStderr) {
      $stderrText = (Get-Content -LiteralPath $controllerStderr -Raw -ErrorAction SilentlyContinue).Trim()
    }
    if ($controllerProcess.HasExited) {
      $exitSummary = [string]$controllerProcess.ExitCode
    }
    throw "Anchor controller did not become ready within $StartupTimeoutSeconds seconds. Exit=$exitSummary Error=$stderrText"
  }

  Write-TestLog "Controller ready. Waiting $ArrivalDelaySeconds seconds for monitor arrival."
  Start-Sleep -Seconds $ArrivalDelaySeconds

  $connectedText = Invoke-Inspection -Path $connectedLog
  $availableAnchors = Get-AvailableAnchorLines -InspectionText $connectedText
  if ($availableAnchors.Count -ne 1) {
    throw "Expected exactly one available anchor target, found $($availableAnchors.Count)."
  }

  $anchorLine = $availableAnchors[0]
  if ($anchorLine -notmatch '\boutputTech=16\b') {
    throw "The available anchor does not report outputTech=16: $anchorLine"
  }
  if ($anchorLine -notmatch 'adapterPath=.*TopologyDdcciAnchor') {
    throw "The available target is not owned by TopologyDdcciAnchor: $anchorLine"
  }

  $activeState = '<unknown>'
  if ($anchorLine -match '\bactive=(True|False)\b') {
    $activeState = $Matches[1]
  }
  Write-TestLog "Availability gate passed while connected. AnchorActive=$activeState"
} catch {
  $capturedFailure = $_
} finally {
  if ($controllerProcess -and -not $controllerProcess.HasExited) {
    Write-TestLog 'Stopping the controller to withdraw the temporary software device.'
    Stop-Process -Id $controllerProcess.Id -Force -ErrorAction SilentlyContinue
    [void]$controllerProcess.WaitForExit(5000)
  }
}

try {
  if ('TopologyDdcciAnchorInspectionV3.PathInspector' -as [type]) {
    $cleanupDeadline = (Get-Date).AddSeconds($CleanupTimeoutSeconds)
    do {
      $cleanupProbe = [TopologyDdcciAnchorInspectionV3.PathInspector]::Inspect($true)
      $availableAfterStop = Get-AvailableAnchorLines -InspectionText $cleanupProbe
      if ($availableAfterStop.Count -eq 0) {
        break
      }
      Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $cleanupDeadline)
  }

  Write-TestLog 'Capturing DisplayConfig state after controller cleanup.'
  $cleanupText = Invoke-Inspection -Path $cleanupLog
  $availableAfterCleanup = Get-AvailableAnchorLines -InspectionText $cleanupText
  if ($availableAfterCleanup.Count -ne 0 -and -not $capturedFailure) {
    $capturedFailure = [System.Management.Automation.ErrorRecord]::new(
      [InvalidOperationException]::new("Anchor remained available after controller cleanup: $($availableAfterCleanup[0])"),
      'AnchorCleanupFailed',
      [System.Management.Automation.ErrorCategory]::InvalidResult,
      $null)
  }

  $cleanupPhysicalTargets = Get-ActivePhysicalTargetKeys -InspectionText $cleanupText
  $targetDifference = @(Compare-Object -ReferenceObject $baselinePhysicalTargets -DifferenceObject $cleanupPhysicalTargets)
  if ($targetDifference.Count -ne 0 -and -not $capturedFailure) {
    $message = 'Active physical target set changed after cleanup. Before={0} After={1}' -f `
      (Format-KeySet -Keys $baselinePhysicalTargets), `
      (Format-KeySet -Keys $cleanupPhysicalTargets)
    $capturedFailure = [System.Management.Automation.ErrorRecord]::new(
      [InvalidOperationException]::new($message),
      'PhysicalTopologyNotRestored',
      [System.Management.Automation.ErrorCategory]::InvalidResult,
      $null)
  }
} catch {
  if (-not $capturedFailure) {
    $capturedFailure = $_
  }
}

if ($capturedFailure) {
  Write-TestLog "FAIL: $($capturedFailure.Exception.Message)"
  Write-TestLog "Logs: Test=$script:TestLogPath Connected=$connectedLog Cleanup=$cleanupLog"
  throw $capturedFailure
}

Write-TestLog 'PASS: one available indirect-wired anchor was observed and then withdrawn; active physical targets were restored.'
Write-TestLog "Logs: Test=$script:TestLogPath Connected=$connectedLog Cleanup=$cleanupLog"
