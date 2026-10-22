# Installs Ravi for you (no admin needed): copies it to %LOCALAPPDATA%\Programs\Ravi,
# adds a Start menu entry and starts it. Ravi adds itself to "open at login" on first run
# (switch that off in its tray menu).  Easiest: double-click install.cmd next to this file.
$ErrorActionPreference = 'Stop'
$src  = $PSScriptRoot
$dest = Join-Path $env:LOCALAPPDATA 'Programs\Ravi'
$exe  = Join-Path $dest 'Ravi.exe'

if (-not (Test-Path (Join-Path $src 'Ravi.exe'))) {
    throw "Run this from the unzipped Ravi folder (Ravi.exe should be right next to install.ps1)."
}

Write-Host "Installing Ravi to $dest"
if (Test-Path $exe) {
    & $exe --quit
    Start-Sleep -Milliseconds 1200
}
Get-Process -Name Ravi -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force

if ($src -ne $dest) {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $dest -Recurse -Force
}
# files from a downloaded zip carry a "from the internet" mark; clear it so Windows doesn't ask every time
Get-ChildItem -Path $dest -Recurse -File | Unblock-File

$lnk   = Join-Path ([Environment]::GetFolderPath('Programs')) 'Ravi.lnk'
$shell = New-Object -ComObject WScript.Shell
$s = $shell.CreateShortcut($lnk)
$s.TargetPath       = $exe
$s.WorkingDirectory = $dest
$s.IconLocation     = "$exe,0"
$s.Description      = 'Ravi the Ravioli: stretch reminders'
$s.Save()

Start-Process -FilePath $exe -ArgumentList '--show'
Write-Host ""
Write-Host "Done. Ravi is in your tray (the ravioli by the clock; it may sit under the ^ arrow)."
Write-Host "Ctrl+Alt+R gives its card the keyboard. Find it again in the Start menu as Ravi."
Write-Host "Uninstall: double-click uninstall.cmd in $dest"
