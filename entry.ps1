Write-Host "Welcome to Subodh's Windows Setup!"

Write-Host "Bootstrapper successfully downloaded."



$ErrorActionPreference = "Stop"

# Configuration URL
$configUrl = "https://subodhgautam.github.io/new-repo/installer.winget"


# Temporary working directory
$tempDirectory = Join-Path $env:TEMP "SubodhSetup"
$configPath = Join-Path $tempDirectory "installer.winget"



$scriptUrl = "https://subodhgautam.github.io/new-repo/fonts.ps1"
$scriptPath = Join-Path $env:TEMP "fonts.ps1"

Invoke-WebRequest -Uri $scriptUrl -OutFile $scriptPath

& $scriptPath


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






# Start-Process control.exe
Write-Host "`nOpening Programs and Features..." -ForegroundColor Cyan

Start-Process -FilePath "$env:WINDIR\System32\control.exe" `
    -ArgumentList "/name Microsoft.ProgramsAndFeatures" `
    -WindowStyle Normal