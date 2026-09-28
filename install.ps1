# Loom Letter installer for Windows (per-user install).
#
#   powershell -ExecutionPolicy Bypass -File install.ps1              install / update
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall   remove (keeps your log file)
#
# Set LOOMLETTER_FUSION_DIR to install somewhere else.
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $here 'Fusion'

if ($env:LOOMLETTER_FUSION_DIR) {
    $fusion = $env:LOOMLETTER_FUSION_DIR
} else {
    $fusion = Join-Path $env:APPDATA 'Blackmagic Design\DaVinci Resolve\Support\Fusion'
}

$script   = Join-Path $fusion 'Scripts\Utility\Loom Letter.lua'
$titles   = Join-Path $fusion 'Templates\Edit\Titles\Loom Letter'
$previews = Join-Path $fusion 'LoomLetter\previews'
$logs     = Join-Path $fusion 'LoomLetter\logs'

if ($Uninstall) {
    Remove-Item -Force -ErrorAction SilentlyContinue $script
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $titles, $previews
    Write-Host "Loom Letter removed from $fusion"
    Write-Host "(logs are kept in $logs)"
    Write-Host 'Restart DaVinci Resolve to finish.'
    exit 0
}

if (-not (Test-Path $src)) {
    Write-Error "Can't find $src - run this script from the Loom Letter folder."
}

foreach ($dir in @((Split-Path -Parent $script), $titles, $previews, $logs)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

Copy-Item -Force (Join-Path $src 'Scripts\Utility\Loom Letter.lua') $script
# replace the template folder so renamed/removed presets don't linger
Get-ChildItem -Path $titles -Filter '*.setting' -ErrorAction SilentlyContinue | Remove-Item -Force
Copy-Item -Force (Join-Path $src 'Templates\Edit\Titles\Loom Letter\*.setting') $titles
Copy-Item -Force (Join-Path $src 'LoomLetter\previews\*.png') $previews

$count = (Get-ChildItem -Path $titles -Filter '*.setting').Count
Write-Host "Loom Letter installed to $fusion"
Write-Host '  panel:   Scripts\Utility\Loom Letter.lua'
Write-Host "  titles:  $count templates in Templates\Edit\Titles\Loom Letter"
Write-Host ''
Write-Host 'Restart DaVinci Resolve, then open Workspace > Scripts > Loom Letter.'
