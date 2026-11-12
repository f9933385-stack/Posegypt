# Kasher Windows development launcher — localhost only, not certified for production
param([string]$StoreName='سوبرماركت جديد',[string]$BranchName='الفرع الرئيسي')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path $PSScriptRoot).Path
$server = Join-Path $root 'kasher_server.exe'
$app = Join-Path $root 'kasher_app.exe'
if (!(Test-Path $server) -or !(Test-Path $app)) {
  throw 'The bundle must include kasher_server.exe and kasher_app.exe in the same directory.'
}
$dataDir = Join-Path $env:LOCALAPPDATA 'Kasher\data'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$db = Join-Path $dataDir 'kasher.sqlite3'
if (!(Test-Path $db)) {
  Write-Host 'First-run setup: choose an admin password of at least 12 characters.'
  $credential = Read-Host 'Admin password' -AsSecureString
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential)
  try {
    $env:KASHER_ADMIN_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if ($env:KASHER_ADMIN_PASSWORD.Length -lt 12) { throw 'Password too short' }
    & $server "--db=$db" "--name=$StoreName" "--branch=$BranchName" init
    if ($LASTEXITCODE -ne 0) { throw 'Initialization failed' }
    Write-Host 'Keep the tenant_id from above and enter it in the app login screen.'
  } finally {
    Remove-Item Env:\KASHER_ADMIN_PASSWORD -ErrorAction SilentlyContinue
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
  }
}
$launchedServer = $null
try {
  $healthy = $false
  try {
    $status = Invoke-RestMethod 'http://127.0.0.1:8787/health' -TimeoutSec 2
    if ($status.status -eq 'ok') { $healthy = $true }
  } catch {}
  if (!$healthy) {
    $log = Join-Path $dataDir 'server.out.log'
    $err = Join-Path $dataDir 'server.err.log'
    $argsLine = '--db="' + $db + '" serve'
    $launchedServer = Start-Process -FilePath $server -ArgumentList $argsLine -PassThru -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $err
    for ($i=0; $i -lt 20; $i++) {
      Start-Sleep -Milliseconds 500
      if ($launchedServer.HasExited) { throw "Server failed to start: see $err" }
      try {
        $status = Invoke-RestMethod 'http://127.0.0.1:8787/health' -TimeoutSec 2
        if ($status.status -eq 'ok') { $healthy = $true; break }
      } catch {}
    }
  }
  if (!$healthy) { throw 'The local branch host did not become healthy.' }
  Start-Process -FilePath $app -Wait
} finally {
  if ($null -ne $launchedServer -and !$launchedServer.HasExited) {
    Stop-Process -Id $launchedServer.Id -ErrorAction SilentlyContinue
  }
}
