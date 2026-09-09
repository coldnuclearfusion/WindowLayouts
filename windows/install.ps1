# Build WindowLayouts (Windows), install it to %LOCALAPPDATA%\Programs\WindowLayouts and start it.
# Requires the .NET 8 SDK (https://dotnet.microsoft.com/download).
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
Write-Host "Installed: $dest"
