
# Write-Host "`nInstalling fonts..." -ForegroundColor Yellow

# $fontUrl = "https://subodhgautam.github.io/new-repo/fonts/"
# # $fontUrl = "\assets\fonts"

# $fontDirectory = "$env:WINDIR\Fonts"

# New-Item -ItemType Directory -Path $fontDirectory -Force | Out-Null

# Write-Host "`nDone..." -ForegroundColor Green
# 1. Check if the current session is running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 2. If not admin, relaunch this exact script with elevated privileges
if (-not $isAdmin) {
    Write-Warning "Admin privileges missing. Launching an elevated session..."
    
    # Start a new PowerShell process as Administrator, passing this script's path
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"$PSCommandPath`"" -Verb RunAs
    
    # Close the current non-admin console
    Exit
}

# --- YOUR ACTUAL SCRIPT STARTS HERE ---
Write-Output "[STARTING] Script is now running with Admin privileges."
# Invoke-WebRequest ...




$fontUrl = "https://api.github.com/repos/subodhgautam/new-repo/contents/assets/fonts"
$fontDirectory = "$env:WINDIR\Fonts"

New-Item -ItemType Directory -Path $fontDirectory -Force | Out-Null

# Get the repository folder contents
$fonts = Invoke-RestMethod -Uri $fontUrl

foreach ($font in $fonts) {

    if ($font.type -ne "file") { continue }

    if ($font.name -notmatch '\.(ttf|otf)$') { continue }

    $destination = Join-Path $fontDirectory $font.name

    if (Test-Path $destination) {
        Write-Host "[SKIP] $($font.name) already exists."
        continue
    }

    Write-Host "[INSTALLING] $($font.name)"

    Invoke-WebRequest -Uri $font.download_url -OutFile $destination
}




Write-Host "" # Empty line for spacing
Write-Host "Press any key to exit..." -ForegroundColor Yellow

# This reads a single keypress from the console
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")