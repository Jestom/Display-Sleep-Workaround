BeforeAll {
  $script:Root = Split-Path -Parent $PSScriptRoot
  . (Join-Path $script:Root "topology-ddcci-runtime-utils.ps1")
}

Describe "Target match cardinality" {
  It "accepts exactly one matching path" {
    $preview = [pscustomobject]@{ ActivePathCount = 2; MatchedPathCount = 1; KeptPathCount = 1; Criteria = "test" }
    { Assert-TopologyTargetMatchCardinality -Preview $preview } | Should -Not -Throw
  }

  It "rejects multiple matching paths by default" {
    $preview = [pscustomobject]@{ ActivePathCount = 3; MatchedPathCount = 2; KeptPathCount = 1; Criteria = "test" }
    { Assert-TopologyTargetMatchCardinality -Preview $preview } | Should -Throw "*AllowMultipleTargets*"
  }

  It "accepts multiple paths only with explicit opt-in" {
    $preview = [pscustomobject]@{ ActivePathCount = 3; MatchedPathCount = 2; KeptPathCount = 1; Criteria = "test" }
    { Assert-TopologyTargetMatchCardinality -Preview $preview -AllowMultipleTargets } | Should -Not -Throw
  }

  It "continues to reject removal of every active path" {
    $preview = [pscustomobject]@{ ActivePathCount = 1; MatchedPathCount = 1; KeptPathCount = 0; Criteria = "test" }
    { Assert-TopologyTargetMatchCardinality -Preview $preview } | Should -Throw "*every active display path*"
  }
}

Describe "Log retention" {
  It "reserves one file slot for the new runtime log" {
    1..4 | ForEach-Object {
      $path = Join-Path $TestDrive ("display-topology-ddcci-0{0}.log" -f $_)
      Set-Content -LiteralPath $path -Value $_
      (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddMinutes(-$_)
    }

    $remove = @(Get-TopologyLogFilesToRemove -Directory $TestDrive -Prefix "display-topology-ddcci" -RetentionDays 0 -MaxFiles 3)
    $remove.Count | Should -Be 2
  }

  It "removes logs older than the retention period" {
    $oldPath = Join-Path $TestDrive "age-test-old.log"
    $newPath = Join-Path $TestDrive "age-test-new.log"
    Set-Content -LiteralPath $oldPath -Value "old"
    Set-Content -LiteralPath $newPath -Value "new"
    (Get-Item -LiteralPath $oldPath).LastWriteTime = (Get-Date).AddDays(-31)

    $remove = @(Get-TopologyLogFilesToRemove -Directory $TestDrive -Prefix "age-test" -RetentionDays 30 -MaxFiles 0)
    $remove.FullName | Should -Contain $oldPath
    $remove.FullName | Should -Not -Contain $newPath
  }
}

Describe "Scheduled task lifetime" {
  It "uses an unlimited execution time" {
    $installer = Get-Content -LiteralPath (Join-Path $script:Root "install-topology-ddcci-workaround-task.ps1") -Raw
    $installer | Should -Match "ExecutionTimeLimit \(\[TimeSpan\]::Zero\)"
  }
}

Describe "Crash recovery marker" {
  It "records enough process identity to distinguish a reused PID" {
    $startTime = [datetime]::Parse("2026-09-02T01:02:03Z").ToUniversalTime()
    $preview = [pscustomobject]@{ ActivePathCount = 2; MatchedPathCount = 1; KeptPathCount = 1 }
    $marker = New-TopologyRecoveryMarkerData `
      -ParentProcessId 1234 `
      -ParentProcessStartTimeUtc $startTime `
      -ProfileName "Test" `
      -Criteria "needles=[DISPLAY#TEST]" `
      -Preview $preview

    $marker.SchemaVersion | Should -Be 2
    $marker.ParentProcessId | Should -Be 1234
    [datetime]::Parse($marker.ParentProcessStartTimeUtc).ToUniversalTime() | Should -Be $startTime
  }
}
