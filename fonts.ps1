
 
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 2. If not admin, relaunch this exact script with elevated privileges
if (-not $isAdmin) {
    Write-Warning "Admin privileges missing. Launching an elevated session..."
    
    # Start a new PowerShell process as Administrator, passing this script's path
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"$PSCommandPath`"" -Verb RunAs
    
    # Close the current non-admin console
    Exit
}

 
Write-Output "[STARTING] Script is now running with Admin privileges."
 $fontUrl = "https://api.github.com/repos/subodhgautam/new-repo/contents/assets/fonts"

$downloadDirectory = Join-Path $env:TEMP "MyFonts"

New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null

$fonts = Invoke-RestMethod -Uri $fontUrl

foreach ($font in $fonts) {

    if ($font.type -ne "file") { continue }
    if ($font.name -notmatch '\.(ttf|otf|ttc)$') { continue }

    $destination = Join-Path $downloadDirectory $font.name

    Write-Host "[DOWNLOADING] $($font.name)"

    Invoke-WebRequest -Uri $font.download_url -OutFile $destination
}

Write-Host "`nDownload stage complete." -ForegroundColor Green
Write-Host "Files saved to: $downloadDirectory"



# # installs garna

Write-Host "Opening fonts folder..."
Start-Process explorer.exe -ArgumentList "`"$downloadDirectory`""




# exit garna lai
# ;;;;;;;;;;;;;;;;;;;;;

Write-Host "" # Empty line for spacing
Write-Host "Press any key to exit..." -ForegroundColor Yellow

# This reads a single keypress from the console
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")