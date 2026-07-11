[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Label,
  [ValidateRange(5, 180)]
  [int]$ObserveAfterDisplayOffSeconds = 120,
  [ValidateRange(60, 3600)]
  [int]$MaxWaitForDisplayOffSeconds = 900,
  [ValidateRange(1, 30)]
  [int]$PostWakeCaptureSeconds = 5,
  [ValidateSet("Natural", "LowPower", "Off")]
  [string]$DisplayPowerTrigger = "Natural",
  [ValidateRange(1, 60)]
  [int]$TriggerAfterSeconds = 5,
  [switch]$CaptureDpcd,
  [uint32]$DpcdTargetId = 0,
  [ValidateRange(-1, 64)]
  [int]$DpcdMonitorIndex = -1,
  [string]$DpcdControllerPath = "",
  [switch]$NoAutoWake,
  [switch]$SkipEtl,
  [switch]$KeepExpandedTrace,
  [switch]$NoArchive
)

$childMarkerName = "TOPOLOGY_DDCCI_NATURAL_SLEEP_CHILD"
if ([Environment]::GetEnvironmentVariable($childMarkerName, "Process") -ne "1") {
  $entryScriptPath = $MyInvocation.MyCommand.Path
  $powershellPath = $null
  try {
    $powershellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  } catch {
    $powershellPath = $null
  }
  if ([string]::IsNullOrWhiteSpace($powershellPath) -or -not (Test-Path -LiteralPath $powershellPath)) {
    $powershellPath = Join-Path $PSHOME "powershell.exe"
  }

  $childArguments = @(
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-STA",
    "-File", $entryScriptPath,
    "-Label", $Label,
    "-ObserveAfterDisplayOffSeconds", "$ObserveAfterDisplayOffSeconds",
    "-MaxWaitForDisplayOffSeconds", "$MaxWaitForDisplayOffSeconds",
    "-PostWakeCaptureSeconds", "$PostWakeCaptureSeconds",
    "-DisplayPowerTrigger", $DisplayPowerTrigger,
    "-TriggerAfterSeconds", "$TriggerAfterSeconds"
  )
  if ($NoAutoWake) { $childArguments += "-NoAutoWake" }
  if ($SkipEtl) { $childArguments += "-SkipEtl" }
  if ($KeepExpandedTrace) { $childArguments += "-KeepExpandedTrace" }
  if ($NoArchive) { $childArguments += "-NoArchive" }
  if ($CaptureDpcd) {
    $childArguments += @(
      "-CaptureDpcd",
      "-DpcdTargetId", "$DpcdTargetId",
      "-DpcdMonitorIndex", "$DpcdMonitorIndex"
    )
    if (-not [string]::IsNullOrWhiteSpace($DpcdControllerPath)) {
      $childArguments += @("-DpcdControllerPath", $DpcdControllerPath)
    }
  }

  $previousMarker = [Environment]::GetEnvironmentVariable($childMarkerName, "Process")
  $childExitCode = 1
  try {
    [Environment]::SetEnvironmentVariable($childMarkerName, "1", "Process")
    & $powershellPath @childArguments
    $childExitCode = $LASTEXITCODE
  } finally {
    [Environment]::SetEnvironmentVariable($childMarkerName, $previousMarker, "Process")
  }

  if ($childExitCode -ne 0) {
    throw "The isolated natural-sleep capture process failed with exit code $childExitCode."
  }
  return
}

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$logRoot = Join-Path $projectRoot "log\diagnostics"
$safeLabel = ($Label -replace "[^A-Za-z0-9._-]+", "-").Trim("-")
if ([string]::IsNullOrWhiteSpace($safeLabel)) {
  throw "Label must contain at least one filename-safe character."
}

$captureName = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $safeLabel
$outputDirectory = Join-Path $logRoot $captureName
$captureLog = Join-Path $outputDirectory "capture.log"
$resultPath = Join-Path $outputDirectory "result.txt"
$providerPath = Join-Path $scriptRoot "natural-sleep-providers.txt"
$etlPath = Join-Path $outputDirectory "natural-display-sleep.etl"
$expandedTracePath = Join-Path $outputDirectory "natural-display-sleep.csv"
$relevantEventsPath = Join-Path $outputDirectory "relevant-events.txt"
$relativeEventsPath = Join-Path $outputDirectory "relevant-events-relative.txt"
$sessionName = "TopologyDdcciNaturalSleep-$PID"

if ([string]::IsNullOrWhiteSpace($DpcdControllerPath)) {
  $DpcdControllerPath = Join-Path $projectRoot "dp-link-probe\out\x64\TopologyDpProbeCtl.exe"
}

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

function Write-CaptureLog {
  param([string]$Message)

  $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
  Write-Host $line
  Add-Content -LiteralPath $captureLog -Value $line -Encoding UTF8
}

function Save-CommandOutput {
  param(
    [string]$Name,
    [scriptblock]$Command
  )

  $path = Join-Path $outputDirectory $Name
  try {
    & $Command 2>&1 | Out-File -LiteralPath $path -Encoding UTF8 -Width 4096
  } catch {
    ("Capture failed: {0}" -f $_.Exception.Message) | Out-File -LiteralPath $path -Encoding UTF8
  }
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

function Assert-DpcdCaptureReady {
  if (-not $CaptureDpcd) {
    return
  }
  if ($DisplayPowerTrigger -ne "Off") {
    throw "Synchronized DPCD capture requires -DisplayPowerTrigger Off."
  }
  if ($DpcdTargetId -eq 0) {
    throw "Synchronized DPCD capture requires a nonzero -DpcdTargetId."
  }
  if (-not (Test-Path -LiteralPath $DpcdControllerPath)) {
    throw "DP link probe controller not found: $DpcdControllerPath"
  }

  $gateOutput = @(& $DpcdControllerPath list 2>&1)
  $gateExitCode = $LASTEXITCODE
  $gateOutput |
    ForEach-Object { $_.ToString() } |
    Out-File -LiteralPath (Join-Path $outputDirectory "dpcd-interface-gate.txt") -Encoding UTF8 -Width 4096
  if ($gateExitCode -ne 0) {
    throw "DP link probe interface gate failed with exit code $gateExitCode."
  }
  Write-CaptureLog "DPCD interface gate passed. TargetId=$DpcdTargetId MonitorIndex=$DpcdMonitorIndex"
}

function Save-DpcdSnapshot {
  param([string]$Name)

  if (-not $CaptureDpcd) {
    return
  }

  $arguments = @("snapshot", "--target", [string]$DpcdTargetId)
  if ($DpcdMonitorIndex -ge 0) {
    $arguments += @("--monitor", [string]$DpcdMonitorIndex)
  }

  $snapshotPath = Join-Path $outputDirectory ("dpcd-{0}.txt" -f $Name)
  Write-CaptureLog "DPCD snapshot started: $Name"
  $snapshotOutput = @(& $DpcdControllerPath @arguments 2>&1)
  $snapshotExitCode = $LASTEXITCODE
  $snapshotOutput |
    ForEach-Object { $_.ToString() } |
    Out-File -LiteralPath $snapshotPath -Encoding UTF8 -Width 4096
  Write-CaptureLog "DPCD snapshot finished: $Name ExitCode=$snapshotExitCode"
  if ($snapshotExitCode -ne 0) {
    throw "DPCD snapshot '$Name' failed with exit code $snapshotExitCode."
  }
}

function Save-DisplayConfigSnapshot {
  param([string]$Name)

  $wrapperPath = Join-Path $projectRoot "topology-ddcci-workaround.ps1"
  $powershellPath = Get-CurrentPowerShellPath
  $outputPath = Join-Path $outputDirectory ("displayconfig-{0}.txt" -f $Name)
  try {
    & $powershellPath `
      -NoProfile `
      -ExecutionPolicy Bypass `
      -STA `
      -File $wrapperPath `
      -ListDisplays `
      -NoLog 2>&1 | Out-File -LiteralPath $outputPath -Encoding UTF8 -Width 4096
  } catch {
    ("DisplayConfig capture failed: {0}" -f $_.Exception.Message) | Out-File -LiteralPath $outputPath -Encoding UTF8
  }
}

function Save-SystemSnapshot {
  param([string]$Name)

  Write-CaptureLog "Capturing system snapshot: $Name"
  Save-DisplayConfigSnapshot $Name

  Save-CommandOutput "video-controllers-$Name.json" {
    Get-CimInstance Win32_VideoController |
      Select-Object Name, Status, PNPDeviceID, DriverVersion, DriverDate, VideoProcessor, CurrentHorizontalResolution, CurrentVerticalResolution, CurrentRefreshRate |
      ConvertTo-Json -Depth 4
  }
  Save-CommandOutput "monitor-connections-$Name.json" {
    Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams |
      Select-Object Active, InstanceName, VideoOutputTechnology |
      ConvertTo-Json -Depth 4
  }
  Save-CommandOutput "pnp-display-monitor-$Name.txt" {
    Get-PnpDevice -Class Display, Monitor | Format-List Status, Class, FriendlyName, InstanceId
  }
  Save-CommandOutput "nvidia-smi-$Name.txt" {
    & nvidia-smi.exe -q
  }
}

function Resolve-SystemDriverPath {
  param([string]$PathName)

  if ([string]::IsNullOrWhiteSpace($PathName)) {
    return $null
  }

  $path = [Environment]::ExpandEnvironmentVariables($PathName.Trim().Trim('"'))
  if ($path.StartsWith("\??\", [StringComparison]::OrdinalIgnoreCase)) {
    $path = $path.Substring(4)
  }
  if ($path.StartsWith("\SystemRoot\", [StringComparison]::OrdinalIgnoreCase)) {
    $path = Join-Path $env:windir $path.Substring("\SystemRoot\".Length)
  } elseif ($path.StartsWith("System32\", [StringComparison]::OrdinalIgnoreCase)) {
    $path = Join-Path $env:windir $path
  }
  return $path
}

function Save-NvidiaCustomDisplayRegistryState {
  $summaryPath = Join-Path $outputDirectory "nvidia-custom-display-registry-search.txt"
  $binaryDirectory = Join-Path $outputDirectory "nvidia-custom-display-values"
  $roots = @(
    "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\nvlddmkm",
    "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Video",
    "Registry::HKEY_CURRENT_USER\Software\NVIDIA Corporation"
  )
  $summary = New-Object System.Collections.Generic.List[string]
  $matchCount = 0

  foreach ($root in $roots) {
    $summary.Add("ScanRoot=$root")
    if (-not (Test-Path -LiteralPath $root)) {
      $summary.Add("  RootNotFound")
      continue
    }

    $keys = @()
    try {
      $keys += Get-Item -LiteralPath $root -ErrorAction Stop
      $keys += @(Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue)
    } catch {
      $summary.Add(("  EnumerationFailed={0}" -f $_.Exception.Message))
      continue
    }

    foreach ($key in $keys) {
      try {
        foreach ($valueName in $key.GetValueNames()) {
          $value = $key.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
          $valueText = if ($value -is [byte[]]) {
            [Text.Encoding]::ASCII.GetString($value) + [Text.Encoding]::Unicode.GetString($value)
          } elseif ($value -is [string[]]) {
            $value -join "`n"
          } else {
            [string]$value
          }

          if ($valueName -notmatch "CustomDisplay" -and $valueText -notmatch "CUST:") {
            continue
          }

          $matchCount++
          $displayValueName = if ([string]::IsNullOrEmpty($valueName)) { "(Default)" } else { $valueName }
          $summary.Add(("  Match={0}\{1}" -f $key.Name, $displayValueName))
          $valueType = if ($null -eq $value) { "null" } else { $value.GetType().FullName }
          $summary.Add(("  ValueType={0}" -f $valueType))

          if ($value -is [byte[]]) {
            New-Item -ItemType Directory -Path $binaryDirectory -Force | Out-Null
            $safeValueName = ($displayValueName -replace "[^A-Za-z0-9._-]+", "-").Trim("-")
            if ([string]::IsNullOrWhiteSpace($safeValueName)) { $safeValueName = "value" }
            $binaryPath = Join-Path $binaryDirectory ("{0:D3}-{1}.bin" -f $matchCount, $safeValueName)
            [IO.File]::WriteAllBytes($binaryPath, $value)
            $hash = Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256
            $summary.Add(("  BinaryFile={0}" -f $binaryPath))
            $summary.Add(("  Length={0} SHA256={1}" -f $value.Length, $hash.Hash))
          } else {
            $summary.Add(("  Value={0}" -f $valueText))
          }
        }
      } catch {
        $summary.Add(("  ReadFailed={0}: {1}" -f $key.Name, $_.Exception.Message))
      }
    }
  }

  $summary.Add("MatchCount=$matchCount")
  $summary | Out-File -LiteralPath $summaryPath -Encoding UTF8 -Width 8192
}

function Write-NvidiaDisplayStateSummary {
  $summaryPath = Join-Path $outputDirectory "nvidia-display-state-summary.txt"
  $files = @(Get-ChildItem -LiteralPath $outputDirectory -Filter "nvidia-smi-*.txt" -ErrorAction SilentlyContinue |
    Sort-Object @{ Expression = {
      if ($_.BaseName -eq "nvidia-smi-before") { 0 }
      elseif ($_.BaseName -like "nvidia-smi-display-off-plus-*") { 1 }
      elseif ($_.BaseName -eq "nvidia-smi-after-wake") { 2 }
      else { 3 }
    } }, Name)

  $lines = foreach ($file in $files) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    $values = @{}
    foreach ($field in @("Display Attached", "Display Active", "Performance State", "Average Power Draw", "Instantaneous Power Draw")) {
      $match = [regex]::Match($content, ("(?m)^\s*{0}\s*:\s*(.+?)\s*$" -f [regex]::Escape($field)))
      $values[$field] = if ($match.Success) { $match.Groups[1].Value.Trim() } else { "not-found" }
    }
    "Phase={0} DisplayAttached={1} DisplayActive={2} PerformanceState={3} AveragePowerDraw={4} InstantaneousPowerDraw={5}" -f `
      $file.BaseName.Substring("nvidia-smi-".Length),
      $values["Display Attached"],
      $values["Display Active"],
      $values["Performance State"],
      $values["Average Power Draw"],
      $values["Instantaneous Power Draw"]
  }

  $lines | Out-File -LiteralPath $summaryPath -Encoding UTF8 -Width 4096
}

function Save-StaticState {
  Save-CommandOutput "os.json" {
    Get-CimInstance Win32_OperatingSystem |
      Select-Object Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime |
      ConvertTo-Json -Depth 3
  }
  Save-CommandOutput "signed-display-drivers.json" {
    Get-CimInstance Win32_PnPSignedDriver |
      Where-Object { $_.DeviceClass -in @("DISPLAY", "MONITOR") } |
      Select-Object DeviceName, DeviceClass, DeviceID, DriverProviderName, DriverVersion, DriverDate, InfName, IsSigned |
      ConvertTo-Json -Depth 4
  }
  Save-CommandOutput "power-active-scheme.txt" {
    & powercfg.exe /getactivescheme
    & powercfg.exe /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE
  }
  Save-CommandOutput "power-requests.txt" {
    & powercfg.exe /requests
  }
  Save-CommandOutput "processes.csv" {
    Get-CimInstance Win32_Process |
      Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine |
      ConvertTo-Csv -NoTypeInformation
  }
  Save-NvidiaCustomDisplayRegistryState

  Save-CommandOutput "nvlddmkm-file.txt" {
    & sc.exe qc nvlddmkm
    $driver = Get-CimInstance Win32_SystemDriver -Filter "Name='nvlddmkm'" | Select-Object -First 1
    if (-not $driver) {
      throw "Win32_SystemDriver did not return nvlddmkm."
    }
    $driver | Select-Object Name, State, StartMode, PathName | Format-List
    $nvidiaDriverPath = Resolve-SystemDriverPath ([string]$driver.PathName)
    "ResolvedPath=$nvidiaDriverPath"
    if ([string]::IsNullOrWhiteSpace($nvidiaDriverPath) -or -not (Test-Path -LiteralPath $nvidiaDriverPath)) {
      throw "The resolved nvlddmkm path does not exist: $nvidiaDriverPath"
    }
    Get-Item -LiteralPath $nvidiaDriverPath | Select-Object FullName, Length, CreationTimeUtc, LastWriteTimeUtc, VersionInfo | Format-List
    Get-FileHash -LiteralPath $nvidiaDriverPath -Algorithm SHA256 | Format-List
  }

  try {
    & dispdiag.exe -out (Join-Path $outputDirectory "dispdiag-before.dat") | Out-Null
  } catch {
    Write-CaptureLog ("dispdiag before capture failed: {0}" -f $_.Exception.Message)
  }
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
    throw "A topology/DDC listener is still running. Stop it before natural-sleep capture. $summary"
  }
}

function Test-IsAdministrator {
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-EtlCapture {
  if ($SkipEtl) {
    Write-CaptureLog "ETW capture skipped by parameter."
    return $false
  }
  if (-not (Test-IsAdministrator)) {
    throw "Run this diagnostic from an elevated PowerShell window, or use -SkipEtl for state-only capture."
  }
  if (-not (Test-Path -LiteralPath $providerPath)) {
    throw "ETW provider configuration not found: $providerPath"
  }

  Write-CaptureLog "Starting ETW session $sessionName"
  $logmanOutput = @(& logman.exe create trace $sessionName -ow -o $etlPath -pf $providerPath -f bincirc -max 256 -ets 2>&1)
  $logmanOutput | Out-File -LiteralPath (Join-Path $outputDirectory "logman-start.txt") -Encoding UTF8
  if ($LASTEXITCODE -ne 0) {
    throw "logman could not start the ETW session. See logman-start.txt. ExitCode=$LASTEXITCODE"
  }
  return $true
}

function Stop-EtlCapture {
  param([bool]$Started)

  if (-not $Started) {
    return
  }
  Write-CaptureLog "Stopping ETW session $sessionName"
  @(& logman.exe stop $sessionName -ets 2>&1) |
    Out-File -LiteralPath (Join-Path $outputDirectory "logman-stop.txt") -Encoding UTF8
}

function Expand-RelevantEtlEvents {
  if ($SkipEtl -or -not (Test-Path -LiteralPath $etlPath)) {
    return
  }

  try {
    Write-CaptureLog "Expanding ETW trace for relevant-event filtering."
    @(& tracerpt.exe $etlPath -of CSV -o $expandedTracePath -y 2>&1) |
      Out-File -LiteralPath (Join-Path $outputDirectory "tracerpt.txt") -Encoding UTF8
    if (Test-Path -LiteralPath $expandedTracePath) {
      $relevantPattern = "DevicePoweredOn|DevicePreparation|SuspendRequestSent|IrpRequestSentD3|IrpRequestSentD0|ConsoleDisplayState|MonitorPower|DxgkCheckMonitorPowerState|VidPn|Hot.?Plug|Hpd|ChildStatus|LinkTraining|SetPowerState"
      Select-String `
        -LiteralPath $expandedTracePath `
        -Pattern $relevantPattern |
        ForEach-Object { $_.Line } |
        Out-File -LiteralPath $relevantEventsPath -Encoding UTF8 -Width 8192
      if ($script:DisplayOffAt -and (Test-Path -LiteralPath $relevantEventsPath)) {
        $displayOffFileTime = $script:DisplayOffAt.ToUniversalTime().ToFileTimeUtc()
        $timeline = foreach ($line in Get-Content -LiteralPath $relevantEventsPath) {
          $timestampMatch = [regex]::Match($line, ",\s*(\d{18})\s*,")
          $eventMatch = [regex]::Match($line, "(DevicePoweredOn|DevicePreparation|SuspendRequestSent|IrpRequestSentD3|IrpRequestSentD0|ConsoleDisplayState|MonitorPower|DxgkCheckMonitorPowerState|VidPn|Hot.?Plug|Hpd|ChildStatus|LinkTraining|SetPowerState)", [Text.RegularExpressions.RegexOptions]::IgnoreCase)
          if ($timestampMatch.Success -and $eventMatch.Success) {
            $eventFileTime = [long]$timestampMatch.Groups[1].Value
            $relativeSeconds = ($eventFileTime - $displayOffFileTime) / 10000000.0
            "{0,12:+0.000000;-0.000000;0.000000}  {1,-24}  {2}" -f $relativeSeconds, $eventMatch.Groups[1].Value, $eventFileTime
          }
        }
        @(
          "DisplayOffAt=$($script:DisplayOffAt.ToString('o'))"
          "DisplayOffFileTime=$displayOffFileTime"
          "RelativeSeconds  Event                     EventFileTime"
        ) + @($timeline) | Out-File -LiteralPath $relativeEventsPath -Encoding UTF8 -Width 4096
      }
    }
  } catch {
    Write-CaptureLog ("ETW expansion failed: {0}" -f $_.Exception.Message)
  } finally {
    if (-not $KeepExpandedTrace -and (Test-Path -LiteralPath $expandedTracePath)) {
      Remove-Item -LiteralPath $expandedTracePath -Force -ErrorAction SilentlyContinue
    }
  }
}

Add-Type -AssemblyName System.Windows.Forms

if (-not ("TopologyDdcciNaturalSleepTraceV1.PowerSettingWindow" -as [type])) {
  Add-Type -ReferencedAssemblies "System.Windows.Forms" -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace TopologyDdcciNaturalSleepTraceV1 {
  public sealed class PowerSettingWindow : NativeWindow, IDisposable {
    public Action<string, int> Callback { get; set; }
    private IntPtr consoleNotify = IntPtr.Zero;
    private IntPtr monitorNotify = IntPtr.Zero;
    private const int WM_POWERBROADCAST = 0x0218;
    private const int PBT_POWERSETTINGCHANGE = 0x8013;
    private const int DEVICE_NOTIFY_WINDOW_HANDLE = 0;

    public PowerSettingWindow() { CreateHandle(new CreateParams()); }

    public void Register(Guid consoleDisplayStateGuid, Guid monitorPowerOnGuid) {
      consoleNotify = RegisterPowerSettingNotification(Handle, ref consoleDisplayStateGuid, DEVICE_NOTIFY_WINDOW_HANDLE);
      monitorNotify = RegisterPowerSettingNotification(Handle, ref monitorPowerOnGuid, DEVICE_NOTIFY_WINDOW_HANDLE);
      if (consoleNotify == IntPtr.Zero || monitorNotify == IntPtr.Zero) {
        throw new InvalidOperationException("RegisterPowerSettingNotification failed.");
      }
    }

    protected override void WndProc(ref Message message) {
      if (message.Msg == WM_POWERBROADCAST && message.WParam.ToInt32() == PBT_POWERSETTINGCHANGE) {
        POWERBROADCAST_SETTING setting = (POWERBROADCAST_SETTING)Marshal.PtrToStructure(message.LParam, typeof(POWERBROADCAST_SETTING));
        int value = setting.DataLength >= 4
          ? Marshal.ReadInt32(message.LParam, Marshal.SizeOf(typeof(Guid)) + sizeof(uint))
          : 0;
        Action<string, int> callback = Callback;
        if (callback != null) callback(setting.PowerSetting.ToString("D"), value);
      }
      base.WndProc(ref message);
    }

    public void Dispose() {
      if (consoleNotify != IntPtr.Zero) UnregisterPowerSettingNotification(consoleNotify);
      if (monitorNotify != IntPtr.Zero) UnregisterPowerSettingNotification(monitorNotify);
      consoleNotify = IntPtr.Zero;
      monitorNotify = IntPtr.Zero;
      DestroyHandle();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POWERBROADCAST_SETTING {
      public Guid PowerSetting;
      public uint DataLength;
      public byte Data;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid settingGuid, int flags);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterPowerSettingNotification(IntPtr handle);
  }

  public static class InputWake {
    private const uint MOUSEEVENTF_MOVE = 0x0001;

    public static void Pulse() {
      mouse_event(MOUSEEVENTF_MOVE, 1, 0, 0, UIntPtr.Zero);
      mouse_event(MOUSEEVENTF_MOVE, unchecked((uint)-1), 0, 0, UIntPtr.Zero);
    }

    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
  }

  public static class DisplayPower {
    private static readonly IntPtr HWND_BROADCAST = new IntPtr(0xFFFF);
    private const uint WM_SYSCOMMAND = 0x0112;
    private const uint SC_MONITORPOWER = 0xF170;
    private const uint SMTO_ABORTIFHUNG = 0x0002;

    public static void Send(int state) {
      UIntPtr result;
      IntPtr sent = SendMessageTimeout(
        HWND_BROADCAST,
        WM_SYSCOMMAND,
        new IntPtr(SC_MONITORPOWER),
        new IntPtr(state),
        SMTO_ABORTIFHUNG,
        5000,
        out result);
      if (sent == IntPtr.Zero) {
        throw new InvalidOperationException("SendMessageTimeout(SC_MONITORPOWER) failed. Win32Error=" + Marshal.GetLastWin32Error());
      }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(
      IntPtr hWnd,
      uint message,
      IntPtr wParam,
      IntPtr lParam,
      uint flags,
      uint timeout,
      out UIntPtr result);
  }
}
"@
}

$script:CaptureCompleted = $false
$script:DisplayOffObserved = $false
$script:ConsoleDisplayOffObserved = $false
$script:ConsoleDisplayOffAt = $null
$script:DisplayOnAfterOffObserved = $false
$script:DisplayOffAt = $null
$script:DisplayOnAt = $null
$script:ObservationStartReason = ""
$script:WakeRequested = $false
$script:Outcome = "not-started"
$script:ObservationTimer = $null
$script:PostWakeTimer = $null
$script:MaxWaitTimer = $null
$script:TriggerTimer = $null
$script:DpcdCaptureFailed = $false

function Complete-CaptureMessageLoop {
  param([string]$Outcome)

  if ($script:CaptureCompleted) {
    return
  }
  $script:CaptureCompleted = $true
  $script:Outcome = $Outcome
  if ($script:ObservationTimer) { $script:ObservationTimer.Stop() }
  if ($script:PostWakeTimer) { $script:PostWakeTimer.Stop() }
  if ($script:MaxWaitTimer) { $script:MaxWaitTimer.Stop() }
  if ($script:TriggerTimer) { $script:TriggerTimer.Stop() }
  [System.Windows.Forms.Application]::ExitThread()
}

function Start-DisplayOffObservation {
  param([string]$Reason)

  if ($script:DisplayOffObserved) {
    return
  }
  $script:DisplayOffObserved = $true
  $script:DisplayOffAt = Get-Date
  $script:ObservationStartReason = $Reason
  $script:MaxWaitTimer.Stop()
  Write-CaptureLog "$Reason; starting ${ObserveAfterDisplayOffSeconds}s observation window."
  $script:ObservationTimer.Start()
}

$etlStarted = $false
$window = $null

try {
  Assert-NoConflictingListener
  Assert-DpcdCaptureReady
  Write-CaptureLog "Display-sleep capture started. Label=$Label DisplayPowerTrigger=$DisplayPowerTrigger Output=$outputDirectory"
  Write-CaptureLog "Do not use the mouse or keyboard until the script wakes the display or asks for manual wake."
  Save-StaticState
  Save-SystemSnapshot "before"
  $etlStarted = Start-EtlCapture

  $script:ObservationTimer = New-Object System.Windows.Forms.Timer
  $script:ObservationTimer.Interval = $ObserveAfterDisplayOffSeconds * 1000
  $script:ObservationTimer.add_Tick({
    $script:ObservationTimer.Stop()
    Write-CaptureLog "Display-off observation marker reached at +${ObserveAfterDisplayOffSeconds}s."
    if ($CaptureDpcd) {
      try {
        Save-DpcdSnapshot "display-off-plus-${ObserveAfterDisplayOffSeconds}s"
      } catch {
        $script:DpcdCaptureFailed = $true
        Write-CaptureLog "Post-off DPCD snapshot failed: $($_.Exception.Message)"
      }
    }
    Save-SystemSnapshot "display-off-plus-${ObserveAfterDisplayOffSeconds}s"
    if ($NoAutoWake) {
      $script:WakeRequested = $true
      Write-CaptureLog "Auto wake is disabled. Wake the display manually now."
    } else {
      $script:WakeRequested = $true
      Write-CaptureLog "Sending a minimal mouse-move input to wake the display."
      [TopologyDdcciNaturalSleepTraceV1.InputWake]::Pulse()
      if ($DisplayPowerTrigger -ne "Natural" -and -not $script:PostWakeTimer.Enabled) {
        Write-CaptureLog "Starting fallback post-wake capture timer for explicit display-power trigger."
        $script:PostWakeTimer.Start()
      }
    }
  })

  $script:PostWakeTimer = New-Object System.Windows.Forms.Timer
  $script:PostWakeTimer.Interval = $PostWakeCaptureSeconds * 1000
  $script:PostWakeTimer.add_Tick({
    $script:PostWakeTimer.Stop()
    Save-SystemSnapshot "after-wake"
    Complete-CaptureMessageLoop "display-off-and-wake-observed"
  })

  $script:MaxWaitTimer = New-Object System.Windows.Forms.Timer
  $script:MaxWaitTimer.Interval = $MaxWaitForDisplayOffSeconds * 1000
  $script:MaxWaitTimer.add_Tick({
    $script:MaxWaitTimer.Stop()
    Write-CaptureLog "Timed out waiting for natural display-off."
    Complete-CaptureMessageLoop "display-off-timeout"
  })

  $script:TriggerTimer = New-Object System.Windows.Forms.Timer
  $script:TriggerTimer.Interval = $TriggerAfterSeconds * 1000
  $script:TriggerTimer.add_Tick({
    $script:TriggerTimer.Stop()
    try {
      $state = if ($DisplayPowerTrigger -eq "LowPower") { 1 } else { 2 }
      if ($CaptureDpcd) {
        Save-DpcdSnapshot "before-display-off"
      }
      Write-CaptureLog "TriggerAfterSeconds elapsed; sending SC_MONITORPOWER state=$state ($DisplayPowerTrigger)."
      [TopologyDdcciNaturalSleepTraceV1.DisplayPower]::Send($state)
      Start-DisplayOffObservation "Explicit $DisplayPowerTrigger trigger sent"
    } catch {
      Write-CaptureLog "Explicit display-power trigger failed: $($_.Exception.Message)"
      Complete-CaptureMessageLoop "display-power-trigger-failed"
    }
  })

  $window = New-Object TopologyDdcciNaturalSleepTraceV1.PowerSettingWindow
  $window.Callback = [System.Action[string,int]]{
    param($settingGuid, $value)

    $guid = $settingGuid.ToLowerInvariant()
    if ($guid -eq "6fe69556-704a-47a0-8f24-c28d936fda47") {
      Write-CaptureLog "ConsoleDisplayState=$value"
      if ($value -eq 0) {
        $script:ConsoleDisplayOffObserved = $true
        if (-not $script:ConsoleDisplayOffAt) {
          $script:ConsoleDisplayOffAt = Get-Date
        }
        if ($DisplayPowerTrigger -ne "Natural" -and
            $script:DisplayOffObserved -and
            $script:ObservationStartReason -like "Explicit * trigger sent") {
          $script:ObservationTimer.Stop()
          $script:DisplayOffAt = $script:ConsoleDisplayOffAt
          $script:ObservationStartReason = "Console display-off observed after explicit $DisplayPowerTrigger trigger"
          Write-CaptureLog "Actual console display-off arrived after the explicit trigger; restarting the full ${ObserveAfterDisplayOffSeconds}s observation window."
          $script:ObservationTimer.Start()
        } elseif (-not $script:DisplayOffObserved) {
          Start-DisplayOffObservation "Console display-off observed"
        }
      } elseif ($value -eq 1 -and
                $script:DisplayOffObserved -and
                -not $script:DisplayOnAfterOffObserved -and
                ($DisplayPowerTrigger -eq "Natural" -or $script:WakeRequested)) {
        $script:DisplayOnAfterOffObserved = $true
        $script:DisplayOnAt = Get-Date
        Write-CaptureLog "Display-on observed after the sleep window; post-wake capture starts in ${PostWakeCaptureSeconds}s."
        $script:ObservationTimer.Stop()
        $script:PostWakeTimer.Start()
      }
    } elseif ($guid -eq "02731015-4510-4526-99e6-e517ebd1aea4") {
      Write-CaptureLog "MonitorPowerOn=$value"
    }
  }

  $consoleGuid = [Guid]"6fe69556-704a-47a0-8f24-c28d936fda47"
  $monitorGuid = [Guid]"02731015-4510-4526-99e6-e517ebd1aea4"
  $window.Register($consoleGuid, $monitorGuid)
  if ($DisplayPowerTrigger -eq "Natural") {
    $script:Outcome = "waiting-for-natural-display-off"
    $script:MaxWaitTimer.Start()
  } else {
    $script:Outcome = "waiting-for-explicit-display-power-trigger"
    Write-CaptureLog "Explicit $DisplayPowerTrigger trigger armed in $TriggerAfterSeconds seconds."
    $script:TriggerTimer.Start()
  }
  [System.Windows.Forms.Application]::Run()
  if (-not $script:CaptureCompleted) {
    throw "The Windows Forms message loop exited before the capture completed. No valid natural-sleep result was recorded."
  }
  if ($script:Outcome -eq "display-power-trigger-failed") {
    throw "The explicit display-power trigger failed."
  }
} catch {
  $script:Outcome = "failed"
  Write-CaptureLog ("Capture failed: {0}" -f $_.Exception.Message)
  throw
} finally {
  if ($script:ObservationTimer) { $script:ObservationTimer.Stop(); $script:ObservationTimer.Dispose() }
  if ($script:PostWakeTimer) { $script:PostWakeTimer.Stop(); $script:PostWakeTimer.Dispose() }
  if ($script:MaxWaitTimer) { $script:MaxWaitTimer.Stop(); $script:MaxWaitTimer.Dispose() }
  if ($script:TriggerTimer) { $script:TriggerTimer.Stop(); $script:TriggerTimer.Dispose() }
  if ($window) { $window.Dispose() }
  Stop-EtlCapture $etlStarted

  try {
    & dispdiag.exe -out (Join-Path $outputDirectory "dispdiag-after.dat") | Out-Null
  } catch {
    Write-CaptureLog ("dispdiag after capture failed: {0}" -f $_.Exception.Message)
  }

  @(
    "Label=$Label"
    "Outcome=$($script:Outcome)"
    "DisplayOffObserved=$($script:DisplayOffObserved)"
    "ConsoleDisplayOffObserved=$($script:ConsoleDisplayOffObserved)"
    "ConsoleDisplayOffAt=$($script:ConsoleDisplayOffAt)"
    "ObservationStartReason=$($script:ObservationStartReason)"
    "DisplayOffAt=$($script:DisplayOffAt)"
    "DisplayOnAfterOffObserved=$($script:DisplayOnAfterOffObserved)"
    "DisplayOnAt=$($script:DisplayOnAt)"
    "ObserveAfterDisplayOffSeconds=$ObserveAfterDisplayOffSeconds"
    "DisplayPowerTrigger=$DisplayPowerTrigger"
    "TriggerAfterSeconds=$TriggerAfterSeconds"
    "CaptureDpcd=$CaptureDpcd"
    "DpcdTargetId=$DpcdTargetId"
    "DpcdMonitorIndex=$DpcdMonitorIndex"
    "DpcdCaptureFailed=$($script:DpcdCaptureFailed)"
    "EtlStarted=$etlStarted"
  ) | Out-File -LiteralPath $resultPath -Encoding UTF8

  Write-NvidiaDisplayStateSummary
  Expand-RelevantEtlEvents
  Write-CaptureLog "Natural display-sleep capture finished. Outcome=$($script:Outcome)"

  if (-not $NoArchive) {
    try {
      $archivePath = "$outputDirectory.zip"
      Compress-Archive -Path (Join-Path $outputDirectory "*") -DestinationPath $archivePath -CompressionLevel Optimal -Force
      Write-CaptureLog "Archive created: $archivePath"
    } catch {
      Write-CaptureLog ("Archive creation failed: {0}" -f $_.Exception.Message)
    }
  }
}
