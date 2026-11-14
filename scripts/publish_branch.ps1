# Use with a GitHub account that has WRITE permission to jjBurgur/Kasher.
# Creates a NEW branch. It never force-pushes or modifies main directly.
param([string]$RepoUrl="https://github.com/jjBurgur/Kasher.git")
$ErrorActionPreference="Stop"
$source=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$target=Join-Path $env:TEMP ("Kasher-publish-"+[guid]::NewGuid().ToString('N'))
$branch="feature/kasher-pos-core-"+(Get-Date -Format 'yyyyMMddHHmmss')
git clone $RepoUrl $target
if ($LASTEXITCODE -ne 0) {throw "Cannot clone repository"}
Push-Location $target
try {
  git switch -c $branch
  Get-ChildItem -LiteralPath $source -Force | Where-Object {$_.Name -ne '.git'} | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
  }
  git add -A
  git commit -m "feat: add Kasher Flutter POS and transactional branch backend"
  if ($LASTEXITCODE -ne 0) {throw "Git commit failed"}
  git push -u origin $branch
  if ($LASTEXITCODE -ne 0) {throw "Push denied. Verify GitHub WRITE permission."}
  Write-Host "Branch published: $branch"
  Write-Host "Open GitHub and create a Pull Request into main after CI passes."
} finally { Pop-Location }
