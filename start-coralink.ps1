#requires -Version 5
<#
    Coralink launcher (Windows). One command to bring the server online via Tailscale.

      powershell -ExecutionPolicy Bypass -File .\start-coralink.ps1            # start
      powershell -ExecutionPolicy Bypass -File .\start-coralink.ps1 -Stop      # stop
      powershell -ExecutionPolicy Bypass -File .\start-coralink.ps1 -Status    # status

    Double-click Coralink.cmd to start.
#>
[CmdletBinding()]
param(
    [int]$Port = 8080,
    [switch]$Stop,
    [switch]$Status
)

$ErrorActionPreference = "Stop"
$Root       = $PSScriptRoot
$ServerDir  = Join-Path $Root "server"
$Tailscale  = "C:\Program Files\Tailscale"
$PidFile    = Join-Path $ServerDir ".server.pid"

function Say($m)  { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }

# Tailscale is usually not on PATH — add it for this session.
if (Test-Path (Join-Path $Tailscale "tailscale.exe")) {
    if (($env:Path -split ';') -notcontains $Tailscale) { $env:Path += ";$Tailscale" }
}

function Get-ListeningPids([int]$p) {
    Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique
}

function Stop-Server {
    Say "Stopping Coralink server"
    $pid1 = $null
    if (Test-Path $PidFile) { $pid1 = (Get-Content $PidFile -ErrorAction SilentlyContinue) }
    foreach ($candidate in @($pid1) + (Get-ListeningPids $Port)) {
        if ($candidate) {
            $proc = Get-Process -Id $candidate -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -like "node*") {
                Warn "Killing node PID $candidate"
                Stop-Process -Id $candidate -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Remove-Item $PidFile -ErrorAction SilentlyContinue
    Ok "Stopped."
}

function Show-Status {
    Say "Coralink status"
    $tscmd = Join-Path $Tailscale "tailscale.exe"
    if (-not (Test-Path $tscmd)) { Warn "Tailscale not found in $Tailscale"; return }
    $state = (& $tscmd status --json 2>$null | ConvertFrom-Json)
    Ok ("Tailscale: " + $state.BackendState)
    $dns = $state.Self.DNSName
    $link = if ($dns) { "https://" + ($dns -replace '\.$','') } else { "https://<machine>.<tailnet>.ts.net" }
    $listening = Get-ListeningPids $Port
    if ($listening) { Ok "Server: running on 127.0.0.1:$Port (PID $listening)" } else { Warn "Server: NOT running" }
    & $tscmd serve status 2>&1 | Out-Host
    Write-Host ""
    Ok "Link: $link"
}

if ($Stop)   { Stop-Server; return }
if ($Status) { Show-Status; return }

# --- start path -----------------------------------------------------------
Say "Checking prerequisites"
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "Node.js not found. Install Node 24+." }
$nodeMajor = [int](((node -v) -replace 'v','' -split '\.')[0])
if ($nodeMajor -lt 24) { throw "Node $((node -v)) is too old, need 24+." }
Ok "Node $((node -v))"

$tscmd = Join-Path $Tailscale "tailscale.exe"
if (-not (Test-Path $tscmd)) { throw "Tailscale not found at $tscmd. Install it and sign in." }
$tsState = (& $tscmd status --json 2>$null | ConvertFrom-Json).BackendState
if ($tsState -ne "Running") { Warn "Tailscale backend is '$tsState'. Opening login..."; & $tscmd up; return }
Ok "Tailscale connected"

Say "Preparing .env"
$EnvFile = Join-Path $ServerDir ".env"
if (-not (Test-Path $EnvFile)) {
    $jwt = -join ((48..57)+(97..122) | Get-Random -Count 64 | ForEach-Object { [char]$_ })
    $pep = -join ((48..57)+(97..122) | Get-Random -Count 64 | ForEach-Object { [char]$_ })
    $dbPath = Join-Path $ServerDir "data\coralink.db"
    @(
        "NODE_ENV=production",
        "HOST=127.0.0.1",
        "PORT=$Port",
        "JWT_SECRET=$jwt",
        "AUTH_PEPPER=$pep",
        "DB_PATH=$dbPath",
        "ALLOWED_ORIGINS=*",
        "MESSAGE_TTL_DAYS=30",
        "WS_MAX_CONNECTIONS=3",
        "LOG_LEVEL=info"
    ) | Set-Content -Encoding UTF8 $EnvFile
    Ok "Created $EnvFile"
} else { Ok "Reusing $EnvFile" }

Say "Installing dependencies"
if (-not (Test-Path (Join-Path $ServerDir "node_modules"))) {
    Push-Location $ServerDir; npm install --omit=dev; Pop-Location
    Ok "Installed"
} else { Ok "Already present" }

Say "Starting server on 127.0.0.1:$Port"
$existing = Get-ListeningPids $Port
if ($existing) {
    Ok "Already running (PID $existing), skipping start"
} else {
    $p = Start-Process -FilePath "node" `
        -ArgumentList @("--env-file=.env", "src/index.js") `
        -WorkingDirectory $ServerDir -WindowStyle Minimized -PassThru
    Set-Content -Path $PidFile -Value $p.Id
    $healthy = $false
    for ($i = 0; $i -lt 15; $i++) {
        try { Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2 | Out-Null; $healthy = $true; break }
        catch { Start-Sleep -Milliseconds 600 }
    }
    if ($healthy) { Ok "Server healthy (PID $($p.Id))" } else { Warn "Server did not answer /health, check the node window" }
}

Say "Publishing via tailscale serve"
$serveOut = (& $tscmd serve status 2>&1 | Out-String)
if ($serveOut -match "No serve config" -or $serveOut -notmatch "proxy") {
    & $tscmd serve --bg "http://127.0.0.1:$Port" 2>&1 | Out-Host
} else {
    Ok "Serve already configured"
}

$dns = (& $tscmd status --json 2>$null | ConvertFrom-Json).Self.DNSName
$link = if ($dns) { "https://" + ($dns -replace '\.$','') } else { "https://<machine>.<tailnet>.ts.net" }

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Green
Write-Host "  Coralink is live on your tailnet" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Green
Write-Host "  Server link for the app:  $link" -ForegroundColor White
Write-Host ""
Write-Host "  Stop:    powershell -File .\start-coralink.ps1 -Stop"
Write-Host "  Status:  powershell -File .\start-coralink.ps1 -Status"
Write-Host "=====================================================" -ForegroundColor Green
