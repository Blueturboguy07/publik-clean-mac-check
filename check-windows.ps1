# check-windows.ps1 <list> <runner>: downloads each public Windows file from its install URL, installs it silently,
# starts the installed app, and waits for its first event at a local listener. Then a second start with a made-up publik key.
# publikhq.com is blocked on this machine. Windows files are unsigned; this check cannot test the SmartScreen message.
param([string]$List, [string]$Runner, [string]$Only = "")
$ErrorActionPreference = 'Continue'; $ProgressPreference = 'SilentlyContinue'
$root = (Get-Location).Path; $R = Join-Path $root 'results'; New-Item -ItemType Directory -Force $R | Out-Null
$results = Join-Path $R 'results.jsonl'
$names = @{ astro='^chrome\.exe$'; cue='^cue\.exe$'; ghost='^ghost\.exe$'; iris='^iris\.exe$'; jobleft='^jobleft\.exe$'; moodledesk='^zenith\.exe$'; nitroai='^nitroai\.exe$'; publikclip='^publikclip-app\.exe$'; simplicity='^simplicity\.exe$'; surfcam='^surfcam\.exe$'; voicestudio='^voicestudio\.exe$'; whimprflow='^whimprflow.*\.exe$' }
$testKey = 'pk_test_cleanmac_0123456789abcdef0123456789abcdef'
function TopDirs { $l = @(); foreach ($p in @($env:LOCALAPPDATA, "$env:LOCALAPPDATA\Programs", $env:ProgramFiles, ${env:ProgramFiles(x86)})) { if (Test-Path $p) { $l += @(Get-ChildItem $p -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object FullName) } }; return $l }
function KillUnder($dirs) { foreach ($d in $dirs) { Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($d, [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force -ErrorAction SilentlyContinue } }
function Launch($exe, $wait, $L, $log) {
  Set-Content $L '' ; $t0 = Get-Date
  $p = Start-Process -FilePath $exe -PassThru -WorkingDirectory (Split-Path $exe) -RedirectStandardError "$L.err" -RedirectStandardOutput "$L.out"
  $secs = $null
  for ($i = 0; $i -lt $wait; $i++) { if (Select-String -Path $L -Pattern '"event": *"app_opened"' -Quiet) { $secs = [int]((Get-Date) - $t0).TotalSeconds; break }; Start-Sleep 1 }
  Start-Sleep 4
  $dir = Split-Path $exe
  $alive = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) })
  $up = $alive.Count -gt 0
  "started process ended: $($p.HasExited) exit code: $(if ($p.HasExited) { $p.ExitCode }) processes under the app folder: $($alive.Count)" | Add-Content $log
  Get-Content "$L.err" -ErrorAction SilentlyContinue | Select-String 'publik-telemetry' | Select-Object -First 4 | Add-Content $log
  return @{ opened = ($null -ne $secs); secs = $secs; up = $up }
}
foreach ($a in (Get-Content $List -Raw | ConvertFrom-Json)) {
  if ($a.runner -ne $Runner) { continue }
  if ($Only -and ($Only -split ',') -notcontains $a.slug) { continue }
  $log = Join-Path $R "$($a.slug)-$($a.file).log"; "=== $($a.slug) $($a.file) $($a.url)" | Tee-Object -FilePath $log
  $res = [ordered]@{ slug=$a.slug; file=$a.file; platform='windows'; runner=$Runner; downloaded=$false; signature=''; installed=$false; install_note=''; exe=''; opened=$false; secs=$null; event_app=''; event_version=''; still_up=$false; signed_in_seen=$false; note='' }
  $D = Join-Path $env:RUNNER_TEMP ([guid]::NewGuid().ToString()); New-Item -ItemType Directory $D | Out-Null; $f = Join-Path $D $a.file
  try { Invoke-WebRequest -Uri $a.url -OutFile $f -MaximumRetryCount 3; $res.downloaded = $true } catch { $res.note = "download failed: $_" }
  if ($res.downloaded) {
    $res.signature = (Get-AuthenticodeSignature $f).Status.ToString()
    $before = TopDirs
    if ($a.file -like '*.msi') { $p = Start-Process msiexec -ArgumentList '/i',"`"$f`"",'/qn','/norestart' -PassThru }
    elseif ($a.slug -eq 'iris') { $p = Start-Process $f -ArgumentList '--silent' -PassThru }
    else { $p = Start-Process $f -ArgumentList '/S' -PassThru }
    if (-not $p.WaitForExit(420000)) { $res.install_note = 'installer still running after 7 min'; $p | Stop-Process -Force -ErrorAction SilentlyContinue }
    Start-Sleep 5
    $new = @(TopDirs | Where-Object { $before -notcontains $_ })
    "new folders: $($new -join '; ')" | Add-Content $log
    KillUnder $new
    $pattern = $names[$a.slug]
    $exe = $null
    foreach ($d in $new) { $exe = Get-ChildItem $d -Recurse -Filter *.exe -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if ($exe) { break } }
    if (-not $exe -and $a.file -like '*arm64*') {
      # A silent install of this file leaves no files, also for the upstream file. Run the package inside the installer.
      $res.install_note = 'silent install left no files; ran the package inside the installer'
      $x = Join-Path $D 'x'; & 'C:\Program Files\7-Zip\7z.exe' x $f "-o$x" -y | Out-Null
      $pkg = Get-ChildItem $x -Recurse -Filter 'app-*.7z' | Select-Object -First 1
      if ($pkg) { & 'C:\Program Files\7-Zip\7z.exe' x $pkg.FullName "-o$x\app" -y | Out-Null; $exe = Get-ChildItem "$x\app" -Recurse -Filter *.exe | Where-Object { $_.Name -match $pattern } | Select-Object -First 1; $new = @("$x\app") }
    } elseif ($exe) { $res.installed = $true }
    if (-not $exe -and $a.file -notlike '*arm64*') { foreach ($d in $new) { $exe = Get-ChildItem $d -Recurse -Filter *.exe -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'unins|update|crashpad|setup' } | Sort-Object Length -Descending | Select-Object -First 1; if ($exe) { break } }; if ($exe) { $res.installed = $true; "picked the largest program: $($exe.FullName)" | Add-Content $log } }
    if ($exe) {
      $res.exe = $exe.FullName
      $port = Get-Random -Minimum 20000 -Maximum 40000; $L = Join-Path $D 'listener.jsonl'; Set-Content $L ''
      $lp = Start-Process python -ArgumentList "`"$root\listener.py`"",$port,"`"$L`"" -PassThru -WindowStyle Hidden
      for ($i = 0; $i -lt 40; $i++) { try { $c = (Invoke-WebRequest -Method Post -Uri "http://127.0.0.1:$port/ready" -TimeoutSec 2 -SkipHttpErrorCheck).StatusCode; if ($c -eq 204) { break } } catch {}; Start-Sleep -Milliseconds 500 }
      $env:PUBLIK_TELEMETRY_URL = "http://127.0.0.1:$port/api/v1/telemetry"; $env:PUBLIK_API_BASE_URL = "http://127.0.0.1:$port"; $env:PUBLIK_TELEMETRY_DEBUG = '1'; $env:PUBLIK_TELEMETRY_INTERVAL_SECONDS = '20'
      Remove-Item Env:PUBLIK_API_KEY -ErrorAction SilentlyContinue
      $wait = 60; if ($a.slug -eq 'astro') { $wait = 180 }
      $r1 = Launch $exe.FullName $wait $L $log
      $res.opened = $r1.opened; $res.secs = $r1.secs; $res.still_up = $r1.up
      $seen = Get-Content $L -ErrorAction SilentlyContinue | Where-Object { $_ -match 'app_opened|active_session' } | Select-Object -First 1
      if ($seen) { try { $j = $seen | ConvertFrom-Json; $res.event_app = $j.app; $res.event_version = $j.app_version } catch {} }
      if (-not $r1.opened) { Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$(Split-Path $exe.FullName)*" } | Select-Object Id,Path | Out-String | Add-Content $log; Get-Content "$L.err","$L.out" -ErrorAction SilentlyContinue | Select-Object -Last 20 | Add-Content $log }
      KillUnder $new; Start-Sleep 2
      if ($a.slug -ne 'astro') {
        $env:PUBLIK_API_KEY = $testKey; Set-Content "$L.auth" ''
        $null = Launch $exe.FullName $wait $L $log
        if (Select-String -Path "$L.auth" -Pattern "Bearer $testKey" -Quiet) { $res.signed_in_seen = $true }
        Remove-Item Env:PUBLIK_API_KEY -ErrorAction SilentlyContinue
        KillUnder $new; Start-Sleep 2
      }
      Stop-Process -Id $lp.Id -Force -ErrorAction SilentlyContinue
    } else { $res.note = "no installed program matches $pattern" }
  }
  $res | ConvertTo-Json -Compress | Tee-Object -Variable line | Write-Output; Add-Content $results $line
  Remove-Item $D -Recurse -Force -ErrorAction SilentlyContinue
}
