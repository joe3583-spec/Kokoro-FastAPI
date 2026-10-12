# Diagnostic Windows launcher for Kokoro-FastAPI.
# Does not change synthesis, models, or the official startup script.
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
Set-Location $root
$logDir = Join-Path $root "diagnostics"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$serverLog = Join-Path $logDir "server-$stamp.log"
$healthLog = Join-Path $logDir "health-$stamp.csv"
$summary = Join-Path $logDir "exit-$stamp.txt"
$env:PHONEMIZER_ESPEAK_LIBRARY = "C:\Program Files\eSpeak NG\libespeak-ng.dll"
$env:PYTHONUTF8 = "1"
$env:PROJECT_ROOT = $root
$env:USE_GPU = "false"
$env:PYTHONPATH = "$root;$root/api"
$env:MODEL_DIR = "src/models"
$env:VOICES_DIR = "src/voices/v1_0"
$env:WEB_PLAYER_PATH = Join-Path $root "web"
$port = Get-NetTCPConnection -LocalPort 8880 -State Listen -ErrorAction SilentlyContinue
if ($port) {
    Write-Host "Port 8880 is already in use. Stop the existing server before running diagnostics." -ForegroundColor Yellow
    $port | Select-Object LocalAddress, LocalPort, OwningProcess | Format-Table
    exit 2
}
$uv = (Get-Command uv -ErrorAction Stop).Source
$arguments = @("run", "--no-sync", "--extra", "cpu", "python", "-u", "-m", "uvicorn", "api.src.main:app", "--host", "127.0.0.1", "--port", "8880", "--log-level", "info", "--access-log")
"timestamp,process_alive,port_listening,health_ok,working_set_mb" | Set-Content -Path $healthLog -Encoding utf8
Write-Host "Starting Kokoro. Server output: $serverLog"
Write-Host "Connection observations: $healthLog"
# Run in its own process to retain an exit code even on abrupt termination.
$p = Start-Process -FilePath $uv -ArgumentList $arguments -WorkingDirectory $root -RedirectStandardOutput $serverLog -RedirectStandardError (Join-Path $logDir "stderr-$stamp.log") -PassThru -NoNewWindow
try {
    while (-not $p.HasExited) {
        $p.Refresh()
        $listening = [bool](Get-NetTCPConnection -LocalPort 8880 -State Listen -ErrorAction SilentlyContinue)
        $healthy = $false
        if ($listening) {
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8880/health" -TimeoutSec 2
                $healthy = ($response.StatusCode -eq 200)
            } catch {}
        }
        $rss = [math]::Round($p.WorkingSet64 / 1MB, 1)
        "$(Get-Date -Format o),$($true),$listening,$healthy,$rss" | Add-Content -Path $healthLog
        Start-Sleep -Seconds 5
        $p.Refresh()
    }
} finally {
    $p.Refresh()
    "Kokoro server process exited at $(Get-Date -Format o). Exit code: $($p.ExitCode)" | Set-Content -Path $summary
    Write-Host "Server exited. Review diagnostics in $logDir" -ForegroundColor Yellow
    Get-Content $summary
}
