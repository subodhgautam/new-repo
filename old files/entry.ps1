Write-Host "Welcome to Subodh's Windows Setup!"

Write-Host "Bootstrapper successfully downloaded."

# escalate garni block.

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 2. If not admin, relaunch this exact script with elevated privileges
if (-not $isAdmin) {
    Write-Warning "Admin privileges missing. Launching an elevated session..."
    
    # Start a new PowerShell process as Administrator, passing this script's path
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"$PSCommandPath`"" -Verb RunAs
    
    # Close the current non-admin console
    Exit
}




$ErrorActionPreference = "Stop"

# Configuration URL
$configUrl = "https://subodhgautam.github.io/new-repo/installer.winget"


# Temporary working directory
$tempDirectory = Join-Path $env:TEMP "SubodhSetup"
$configPath = Join-Path $tempDirectory "installer.winget"





# microsoft office ko block,,,,
$officeSetupUrl = "https://subodhgautam.github.io/new-repo/assets/executables"






# fonta ko block...

$scriptUrl = "https://subodhgautam.github.io/new-repo/fonts.ps1"
$scriptPath = Join-Path $env:TEMP "fonts.ps1"

Invoke-WebRequest -Uri $scriptUrl -OutFile $scriptPath

& $scriptPath




# standard apps ko block

try {
    Write-Host "`n==================================" -ForegroundColor Cyan
    Write-Host "   SUBODH WINDOWS SETUP" -ForegroundColor Cyan
    Write-Host "==================================`n" -ForegroundColor Cyan

    # 1. Check WinGet
    Write-Host "[1/3] Checking WinGet..." -ForegroundColor Yellow

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "WinGet is not available. Install or update App Installer first."
    }

    Write-Host "[OK] WinGet found." -ForegroundColor Green
    winget source update
    # 2. Download configuration
    Write-Host "`n[2/3] Downloading configuration..." -ForegroundColor Yellow

    New-Item -ItemType Directory -Path $tempDirectory -Force |
        Out-Null

    Invoke-WebRequest `
        -Uri $configUrl `
        -OutFile $configPath `
        -UseBasicParsing

    if (-not (Test-Path $configPath)) {
        throw "Configuration download failed."
    }

    Write-Host "[OK] Configuration downloaded." -ForegroundColor Green

    # 3. Apply configuration
    Write-Host "`n[3/3] Applying WinGet configuration..." -ForegroundColor Yellow

    & winget configure --file $configPath

    if ($LASTEXITCODE -ne 0) {
        throw "WinGet configuration failed. Exit code: $LASTEXITCODE"
    }

    Write-Host "`n==================================" -ForegroundColor Green
    Write-Host "       SETUP COMPLETED!" -ForegroundColor Green
    Write-Host "==================================`n" -ForegroundColor Green
}
catch {
    Write-Host "`nSETUP FAILED: $_" -ForegroundColor Red
}


Write-Host "`nInstalling fonts..." -ForegroundColor Yellow

$fontUrl = "https://subodhgautam.github.io/new-repo/fonts/"
$fontDirectory = "$env:WINDIR\Fonts"

New-Item -ItemType Directory -Path $fontDirectory -Force | Out-Null




# finally control panel ma jana lai,,,,,,,

# Start-Process control.exe
Write-Host "`nOpening Programs and Features..." -ForegroundColor Cyan

Start-Process -FilePath "$env:WINDIR\System32\control.exe" `
    -ArgumentList "/name Microsoft.ProgramsAndFeatures" `
    -WindowStyle Normal





    # close garni block, press any key wala effect lyauna;
    # exit garna lai
# ;;;;;;;;;;;;;;;;;;;;;

Write-Host "" # Empty line for spacing
Write-Host "Press any key to exit..." -ForegroundColor Yellow

# This reads a single keypress from the console
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")