param(
  [string]$FilterRunId = ""
)

$ErrorActionPreference = "Stop"
$projectDir = Split-Path -Parent $PSScriptRoot
Set-Location $projectDir

$flutterBin = "C:\Users\gabri\flutter\bin\flutter.bat"
$dartBin = "C:\Users\gabri\flutter\bin\cache\dart-sdk\bin\dart.exe"
$adbBin = "C:\Users\gabri\AppData\Local\Android\Sdk\platform-tools\adb.exe"

$outBase = Join-Path $projectDir "docs\profiling\mis-borradores"
foreach ($sub in @("capturas", "trazas", "datos", "codigo")) {
  $dir = Join-Path $outBase $sub
  if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
}

$runs = @(
  @{
    id = "opt1_snapshot_optimized"
    defines = @(
      "--dart-define=PROFILE_SCENARIO=opt1_snapshot",
      "--dart-define=DRAFTS_BYPASS_CACHE=false"
    )
  },
  @{
    id = "opt1_snapshot_baseline"
    defines = @(
      "--dart-define=PROFILE_SCENARIO=opt1_snapshot",
      "--dart-define=DRAFTS_BYPASS_CACHE=true"
    )
  },
  @{
    id = "opt2_comparison_optimized"
    defines = @(
      "--dart-define=PROFILE_SCENARIO=opt2_comparison",
      "--dart-define=DRAFTS_BYPASS_COMPARISON_CACHE=false"
    )
  },
  @{
    id = "opt2_comparison_baseline"
    defines = @(
      "--dart-define=PROFILE_SCENARIO=opt2_comparison",
      "--dart-define=DRAFTS_BYPASS_COMPARISON_CACHE=true"
    )
  },
  @{
    id = "opt3_listview_optimized"
    defines = @(
      "--dart-define=PROFILE_SCENARIO=opt3_listview",
      "--dart-define=DRAFTS_EAGER_LIST=false"
    )
  },
  @{
    id = "opt3_listview_baseline"
    defines = @(
      "--dart-define=PROFILE_SCENARIO=opt3_listview",
      "--dart-define=DRAFTS_EAGER_LIST=true"
    )
  },
  @{
    id = "opt4_fingerprint_optimized"
    defines = @(
      "--dart-define=PROFILE_SCENARIO=opt4_fingerprint",
      "--dart-define=DRAFTS_BYPASS_FINGERPRINT=false"
    )
  },
  @{
    id = "opt4_fingerprint_baseline"
    defines = @(
      "--dart-define=PROFILE_SCENARIO=opt4_fingerprint",
      "--dart-define=DRAFTS_BYPASS_FINGERPRINT=true"
    )
  }
)

foreach ($run in $runs) {
  $runId = $run.id
  if ($FilterRunId -ne "" -and $runId -ne $FilterRunId) {
    continue
  }
  Write-Host "=========================================================="
  Write-Host "Starting profile run: $runId"
  Write-Host "=========================================================="

  $stdoutLog = Join-Path $outBase "datos\${runId}_flutter_stdout.log"
  $stderrLog = Join-Path $outBase "datos\${runId}_flutter_stderr.log"
  if (Test-Path $stdoutLog) { Remove-Item $stdoutLog -Force }
  if (Test-Path $stderrLog) { Remove-Item $stderrLog -Force }

  $argList = @(
    "run",
    "--no-pub",
    "--profile",
    "-d", "emulator-5554",
    "-t", "tool/profile_mis_borradores.dart",
    "--machine"
  ) + $run.defines

  $proc = Start-Process -FilePath $flutterBin -ArgumentList $argList -WorkingDirectory $projectDir -NoNewWindow -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog

  $httpUri = $null
  $deadline = (Get-Date).AddMinutes(4)

  while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) {
      Write-Host "Flutter process exited early with code $($proc.ExitCode)"
      if (Test-Path $stderrLog) { Get-Content $stderrLog | Write-Host }
      if (Test-Path $stdoutLog) { Get-Content $stdoutLog -Tail 40 | Write-Host }
      throw "Flutter run failed for $runId"
    }
    if (Test-Path $stdoutLog) {
      $content = Get-Content $stdoutLog -Raw -ErrorAction SilentlyContinue
      if ($content -match '"wsUri"\s*:\s*"(ws://127\.0\.0\.1:\d+/[^"]+/ws)"') {
        $wsUri = $Matches[1]
        $httpUri = $wsUri -replace '^ws://', 'http://' -replace '/ws$', '/'
        Write-Host "Detected VM Service URI: $httpUri"
        break
      }
    }
    Start-Sleep -Milliseconds 500
  }

  if (-not $httpUri) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "Timed out waiting for VM Service URI on $runId"
  }

  # Wait for database seeding, then clearVMTimeline from host and start scenario
  $reportReady = $false
  $scenarioStarted = $false
  $reportData = $null
  $scenarioDeadline = (Get-Date).AddMinutes(2)

  while ((Get-Date) -lt $scenarioDeadline) {
    try {
      $vmResp = Invoke-RestMethod -Uri "${httpUri}getVM" -Method Get -TimeoutSec 5
      $isolates = $vmResp.result.isolates
      $mainIso = $isolates | Where-Object { $_.name -like "*main*" } | Select-Object -First 1
      if (-not $mainIso -and $isolates.Count -gt 0) {
        $mainIso = $isolates[0]
      }
      if ($mainIso) {
        $isoId = [uri]::EscapeDataString($mainIso.id)
        $extResp = Invoke-RestMethod -Uri "${httpUri}ext.parchapp.getProfileReport?isolateId=$isoId" -Method Get -TimeoutSec 5
        if ($extResp.result) {
          if (-not $scenarioStarted -and $extResp.result.seeded -eq $true) {
            Write-Host "Database seeded. Clearing VM Timeline and starting scenario..."
            Invoke-RestMethod -Uri "${httpUri}clearVMTimeline" -Method Get -TimeoutSec 5 | Out-Null
            Invoke-RestMethod -Uri "${httpUri}ext.parchapp.startScenario?isolateId=$isoId" -Method Get -TimeoutSec 5 | Out-Null
            $scenarioStarted = $true
          }
          if ($extResp.result.ready -eq $true) {
            $reportReady = $true
            $reportData = $extResp.result.report
            break
          }
        }
      }
    } catch {
      # Extension may still be registering during isolate startup
    }
    Start-Sleep -Milliseconds 500
  }

  if (-not $reportReady) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "Timed out waiting for ext.parchapp.getProfileReport on $runId"
  }

  Write-Host "Scenario completed for $runId! Exporting data, timeline trace and screenshot..."

  $appJsonPath = Join-Path $outBase "datos\${runId}_app.json"
  $vmJsonPath = Join-Path $outBase "datos\${runId}_vm.json"
  $traceJsonPath = Join-Path $outBase "trazas\${runId}_timeline.json"
  $screenPath = Join-Path $outBase "capturas\${runId}_emulator.png"

  $reportData | ConvertTo-Json -Depth 12 | Set-Content -Path $appJsonPath -Encoding UTF8

  & $dartBin run tool/export_vm_profile.dart $httpUri $traceJsonPath $vmJsonPath

  # Capture emulator screenshot via adb exec-out screencap -p
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $adbBin
  $psi.Arguments = "-s emulator-5554 exec-out screencap -p"
  $psi.RedirectStandardOutput = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $adbProc = [System.Diagnostics.Process]::Start($psi)
  $fs = [System.IO.File]::OpenWrite($screenPath)
  $adbProc.StandardOutput.BaseStream.CopyTo($fs)
  $fs.Close()
  $adbProc.WaitForExit()

  Write-Host "Saved:"
  Write-Host "  App metrics : $appJsonPath"
  Write-Host "  VM metrics  : $vmJsonPath"
  Write-Host "  Timeline    : $traceJsonPath"
  Write-Host "  Screenshot  : $screenPath"

  # Terminate flutter run process tree cleanly
  & taskkill /PID $proc.Id /T /F | Out-Null
  Start-Sleep -Seconds 2
  if (Test-Path $stdoutLog) { Remove-Item $stdoutLog -Force -ErrorAction SilentlyContinue }
  if (Test-Path $stderrLog) { Remove-Item $stderrLog -Force -ErrorAction SilentlyContinue }
}

Write-Host "All requested profile runs completed successfully."
