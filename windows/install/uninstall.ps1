# Removes Ravi: quits it, takes it out of "open at login" and the Start menu, deletes the program folder.
# Your stretch history (%APPDATA%\Ravi) stays unless you pass -Purge.
param([switch]$Purge)
$ErrorActionPreference = 'Continue'
$dest = Join-Path $env:LOCALAPPDATA 'Programs\Ravi'
$exe  = Join-Path $dest 'Ravi.exe'

if (Test-Path $exe) { & $exe --quit; Start-Sleep -Milliseconds 1200 }
Get-Process -Name Ravi -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force

Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Ravi' -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path ([Environment]::GetFolderPath('Programs')) 'Ravi.lnk') -ErrorAction SilentlyContinue
Set-Location $env:TEMP
Remove-Item -Path $dest -Recurse -Force -ErrorAction SilentlyContinue

if ($Purge) {
    Remove-Item -Path (Join-Path $env:APPDATA 'Ravi') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Ravi removed, history included."
} else {
    Write-Host "Ravi removed. Your stretch history is still in $env:APPDATA\Ravi (run with -Purge to remove it too)."
}
