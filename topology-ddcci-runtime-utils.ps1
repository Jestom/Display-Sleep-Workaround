function Assert-TopologyTargetMatchCardinality {
  param(
    [Parameter(Mandatory = $true)]
    $Preview,
    [switch]$AllowMultipleTargets,
    [switch]$AllowZeroActivePaths,
    [string]$Context = "preflight"
  )

  if ([int]$Preview.MatchedPathCount -eq 0) {
    throw "No active path matched target criteria during ${Context}: $($Preview.Criteria)"
  }
  if ([int]$Preview.MatchedPathCount -gt 1 -and -not $AllowMultipleTargets) {
    throw "Target criteria matched $($Preview.MatchedPathCount) active paths during ${Context}. Refusing to modify multiple displays by default. Use -AllowMultipleTargets only after verifying every matched path. Criteria=$($Preview.Criteria)"
  }
  if ([int]$Preview.KeptPathCount -eq 0 -and -not $AllowZeroActivePaths) {
    throw "The selected target includes every active display path during ${Context}. Single-display removal requires the explicit experimental mode and is not enabled by default."
  }
}

function Get-TopologyLogFilesToRemove {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Directory,
    [Parameter(Mandatory = $true)]
    [string]$Prefix,
    [ValidateRange(0, 36500)]
    [int]$RetentionDays = 30,
    [ValidateRange(0, 100000)]
    [int]$MaxFiles = 100,
    [datetime]$Now = (Get-Date)
  )

  if (-not (Test-Path -LiteralPath $Directory)) {
    return @()
  }

  $files = @(Get-ChildItem -LiteralPath $Directory -File -Filter "${Prefix}-*.log" -ErrorAction SilentlyContinue)
  if ($files.Count -eq 0) {
    return @()
  }

  $removeByPath = @{}
  if ($RetentionDays -gt 0) {
    $cutoff = $Now.AddDays(-$RetentionDays)
    foreach ($file in $files) {
      if ($file.LastWriteTime -lt $cutoff) {
        $removeByPath[$file.FullName] = $file
      }
    }
  }

  if ($MaxFiles -gt 0) {
    $survivors = @($files |
      Where-Object { -not $removeByPath.ContainsKey($_.FullName) } |
      Sort-Object LastWriteTime -Descending)
    $existingAllowance = [Math]::Max(0, $MaxFiles - 1)
    if ($survivors.Count -gt $existingAllowance) {
      foreach ($file in @($survivors | Select-Object -Skip $existingAllowance)) {
        $removeByPath[$file.FullName] = $file
      }
    }
  }

  return @($removeByPath.Values | Sort-Object FullName)
}

function New-TopologyRecoveryMarkerData {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ParentProcessId,
    [Parameter(Mandatory = $true)]
    [datetime]$ParentProcessStartTimeUtc,
    [Parameter(Mandatory = $true)]
    [string]$ProfileName,
    [Parameter(Mandatory = $true)]
    [string]$Criteria,
    [Parameter(Mandatory = $true)]
    $Preview
  )

  return [ordered]@{
    SchemaVersion = 2
    Status = "topology-removal-armed"
    CreatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    ParentProcessId = $ParentProcessId
    ParentProcessStartTimeUtc = $ParentProcessStartTimeUtc.ToUniversalTime().ToString("o")
    ProfileName = $ProfileName
    Criteria = $Criteria
    ActivePathCount = [int]$Preview.ActivePathCount
    MatchedPathCount = [int]$Preview.MatchedPathCount
    KeptPathCount = [int]$Preview.KeptPathCount
  }
}
