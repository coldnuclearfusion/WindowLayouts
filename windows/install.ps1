# WindowLayouts (Windows) 빌드 → %LOCALAPPDATA%\Programs\WindowLayouts 설치 → 실행
# 필요: .NET 8 SDK (https://dotnet.microsoft.com/download)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

dotnet publish WindowLayouts\WindowLayouts.csproj -c Release -r win-x64 --self-contained false `
  -p:PublishSingleFile=true -o build\publish

$dest = Join-Path $env:LOCALAPPDATA "Programs\WindowLayouts"
Get-Process WindowLayouts -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item build\publish\* $dest -Recurse -Force
Start-Process (Join-Path $dest "WindowLayouts.exe")
Write-Host "설치됨: $dest"
