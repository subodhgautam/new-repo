
#requires -Version 5.1

# ============================================================
# SUBODH WINDOWS SETUP
# Concurrent installation bootstrapper
# ============================================================

$ErrorActionPreference = "Stop"

Write-Host "`nWelcome to Subodh's Windows Setup!" -ForegroundColor Cyan
Write-Host "Bootstrapper successfully downloaded." -ForegroundColor Green


# ============================================================
# 1. ADMINISTRATOR ELEVATION
# ============================================================

# $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# if (-not $isAdmin) {

#     Write-Warning "Administrator privileges missing. Relaunching..."

#     if (-not $PSCommandPath) {
#         throw "Save this script as entry.ps1 before running it."
#     }

#     $powerShellExe = (Get-Process -Id $PID).Path

#     Start-Process -FilePath $powerShellExe `
#         -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`"" `
#         -Verb RunAs

#     exit
# }



# ============================================================
# 1. ADMINISTRATOR ELEVATION (Works with Web Streams)
# ============================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Warning "Admin privileges missing. Launching an elevated session..."
    
    # Check if running via IEX/Web stream or as a local file
    if (-not $PSCommandPath) {
        # If running via IEX, relaunch by re-fetching the online URL
        $ScriptUrl = "https://subodhgautam.github.io/new-repo/entry.ps1"
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"irm $ScriptUrl | iex`"" -Verb RunAs
    } else {
        # If running as a saved local file, relaunch using the file path
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`"" -Verb RunAs
    }
    
    Exit
}


# ============================================================
# 2. CONFIGURATION
# ============================================================

$baseUrl = "https://subodhgautam.github.io/new-repo"

$configUrl = "$baseUrl/installer.winget"

$officeUrl = "$baseUrl/assets/executables/OfficeSetup.exe"

$chromeUrl = "$baseUrl/assets/executables/ChromeSetup.exe"

$fontsUrl = "$baseUrl/assets/fonts.zip"

$fontScriptUrl = "$baseUrl/scripts/fonts.ps1"

$nepaliUrl = "$baseUrl/assets/nepali_romanized.zip"

# If you know the expected installed file for Nepali Romanized,
# enter its full path here. Otherwise, registry detection is used.
$nepaliVerifyPath = ""


# ============================================================
# 3. TEMPORARY DIRECTORIES
# ============================================================

$setupDirectory = Join-Path $env:TEMP "SubodhSetup"

$downloadDirectory = Join-Path $setupDirectory "Downloads"

$extractedDirectory = Join-Path $setupDirectory "Extracted"

$logDirectory = Join-Path $setupDirectory "Logs"

$configPath = Join-Path $setupDirectory "installer.winget"

New-Item -ItemType Directory -Path $downloadDirectory -Force |
    Out-Null

New-Item -ItemType Directory -Path $extractedDirectory -Force |
    Out-Null

New-Item -ItemType Directory -Path $logDirectory -Force |
    Out-Null


# ============================================================
# 4. THREADJOB DEPENDENCY
# ============================================================


# if (-not (Get-Module -ListAvailable -Name ThreadJob)) {
#     Install-Module -Name ThreadJob -AllowClobber -Force
# }


Write-Host "`nChecking ThreadJob..." -ForegroundColor Yellow

if (-not (Get-Module -ListAvailable -Name ThreadJob)) {

    Write-Host "Installing ThreadJob module..." -ForegroundColor Yellow

    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.SecurityProtocolType]::Tls12

    Install-Module ThreadJob `
        -AllowClobber `
        -Scope CurrentUser `
        -Force `
        -Confirm:$false
}

Import-Module ThreadJob -ErrorAction Stop

Write-Host "[OK] ThreadJob ready." -ForegroundColor Green


# ============================================================
# 5. CENTRAL STATUS FILES
# ============================================================

$taskNames = @(
    "Office",
    "Chrome",
    "Fonts",
    "Nepali Romanized",
    "WinGet"
)

$statuses = @{}

foreach ($task in $taskNames) {

    $safeName = $task -replace '[^a-zA-Z0-9]', '_'

    $statuses[$task] = Join-Path $logDirectory "$safeName.json"

    [PSCustomObject]@{
        Task   = $task
        State  = "Pending"
        Detail = "Waiting to start"
        Time   = (Get-Date).ToString("s")
    } |
        ConvertTo-Json |
        Set-Content -Path $statuses[$task] -Encoding UTF8
}


# ============================================================
# 6. COMMON WORKER SCRIPT
# Each thread receives one independent installation pipeline.
# ============================================================

$pipelineScript = {

    param(
        $TaskName,
        $BaseUrl,
        $WorkRoot,
        $StatusPath,
        $NepaliVerifyPath
    )

    $ErrorActionPreference = "Stop"

    $ProgressPreference = "SilentlyContinue"


    # --------------------------------------------------------
    # STATUS REPORTING
    # --------------------------------------------------------

    function Set-TaskStatus {

        param(
            [string]$State,
            [string]$Detail
        )

        $status = [PSCustomObject]@{
            Task   = $TaskName
            State  = $State
            Detail = $Detail
            Time   = (Get-Date).ToString("s")
        }

        $temporaryStatus = "$StatusPath.tmp"

        $status |
            ConvertTo-Json |
            Set-Content -Path $temporaryStatus -Encoding UTF8

        Move-Item -Path $temporaryStatus `
            -Destination $StatusPath `
            -Force
    }


    # --------------------------------------------------------
    # DOWNLOAD HELPER
    # --------------------------------------------------------

    function Get-RemoteFile {

        param(
            [string]$Url,
            [string]$Destination
        )

        Set-TaskStatus "Downloading" "Downloading file..."

        Invoke-WebRequest `
            -Uri $Url `
            -OutFile $Destination `
            -UseBasicParsing `
            -ErrorAction Stop

        if (-not (Test-Path $Destination)) {
            throw "Download failed: file does not exist."
        }

        if ((Get-Item $Destination).Length -eq 0) {
            throw "Download failed: file is empty."
        }

        return $Destination
    }


    # --------------------------------------------------------
    # DIGITAL SIGNATURE VALIDATION
    # --------------------------------------------------------

    function Test-InstallerSignature {

        param(
            [string]$Path,
            [string]$ExpectedPublisher
        )

        $signature = Get-AuthenticodeSignature -FilePath $Path

        if ($signature.Status -ne "Valid") {
            throw "Installer signature is not valid: $($signature.Status)"
        }

        if ($signature.SignerCertificate.Subject -notmatch $ExpectedPublisher) {
            throw "Unexpected installer publisher: $($signature.SignerCertificate.Subject)"
        }
    }


    # --------------------------------------------------------
    # APPLICATION DETECTION
    # --------------------------------------------------------

    function Test-ChromeInstalled {

        $paths = @(
            "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
            "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
        )

        foreach ($path in $paths) {
            if (Test-Path $path) {
                return $true
            }
        }

        return $false
    }


    function Test-OfficeInstalled {

        $paths = @(
            "$env:ProgramFiles\Microsoft Office\root\Office16\WINWORD.EXE",
            "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\WINWORD.EXE"
        )

        foreach ($path in $paths) {
            if (Test-Path $path) {
                return $true
            }
        }

        return $false
    }


    function Test-NepaliInstalled {

        if ($NepaliVerifyPath) {
            return (Test-Path $NepaliVerifyPath)
        }

        $registryPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )

        foreach ($registryPath in $registryPaths) {

            $installedApps = Get-ItemProperty `
                -Path $registryPath `
                -ErrorAction SilentlyContinue

            if ($installedApps.DisplayName -match "Nepali.*Romanized|Romanized") {
                return $true
            }
        }

        return $false
    }

}
    # ========================================================
    # PIPELINE EXECUTION
    # ========================================================

    

        # ----------------------------------------------------
        # OFFICE
        # ----------------------------------------------------

        if ($TaskName -eq "Office") {

            if (Test-OfficeInstalled) {

                Set-TaskStatus "Skipped" "Office already detected."

                return
            }

            $installer = Join-Path $WorkRoot "Downloads\OfficeSetup.exe"

            Get-RemoteFile `
                -Url "$BaseUrl/assets/executables/OfficeSetup.exe" `
                -Destination $installer

            Test-InstallerSignature `
                -Path $installer `
                -ExpectedPublisher "Microsoft"

            Set-TaskStatus "Installing" "Starting Office installer."

            $process = Start-Process `
                -FilePath $installer `
                -Wait `
                -PassThru

            if ($process.ExitCode -notin @(0, 3010, 1641)) {
                throw "Office installer exited with code $($process.ExitCode)."
            }

            Set-TaskStatus "Verifying" "Checking Office installation."

            $installed = $false

            for ($i = 0; $i -lt 60; $i++) {

                if (Test-OfficeInstalled) {
                    $installed = $true
                    break
                }

                Start-Sleep -Seconds 10
            }

            if (-not $installed) {
                throw "Office installation could not be verified."
            }

            Set-TaskStatus "Completed" "Office successfully installed and verified."
        }


        # ----------------------------------------------------
        # CHROME
        # ----------------------------------------------------

        elseif ($TaskName -eq "Chrome") {

            if (Test-ChromeInstalled) {

                Set-TaskStatus "Skipped" "Chrome already detected."

                return
            }

            $installer = Join-Path $WorkRoot "Downloads\ChromeSetup.exe"

            Get-RemoteFile `
                -Url "$BaseUrl/assets/executables/ChromeSetup.exe" `
                -Destination $installer

            Test-InstallerSignature `
                -Path $installer `
                -ExpectedPublisher "Google"

            Set-TaskStatus "Installing" "Installing Google Chrome."

            $process = Start-Process `
                -FilePath $installer `
                -ArgumentList "/silent /install" `
                -Wait `
                -PassThru

            if ($process.ExitCode -notin @(0, 3010, 1641)) {
                throw "Chrome installer exited with code $($process.ExitCode)."
            }

            Set-TaskStatus "Verifying" "Checking Chrome installation."

            $installed = $false

            for ($i = 0; $i -lt 30; $i++) {

                if (Test-ChromeInstalled) {
                    $installed = $true
                    break
                }

                Start-Sleep -Seconds 4
            }

            if (-not $installed) {
                throw "Chrome installation could not be verified."
            }

            Set-TaskStatus "Completed" "Chrome successfully installed and verified."
        }


        # ----------------------------------------------------
        # FONTS
        # ----------------------------------------------------

        elseif ($TaskName -eq "Fonts") {

            $archive = Join-Path $WorkRoot "Downloads\Fonts.zip"

            $fontDirectory = Join-Path $WorkRoot "Extracted\Fonts"

            $fontScript = Join-Path $WorkRoot "fonts.ps1"

Get-RemoteFile `
    -Url "$BaseUrl/assets/fonts.zip" `
    -Destination $Archive

            Set-TaskStatus "Installing" "Extracting font archive."

            New-Item -ItemType Directory `
                -Path $fontDirectory `
                -Force | Out-Null

            Expand-Archive `
                -Path $archive `
                -DestinationPath $fontDirectory `
                -Force

            Get-RemoteFile `
                -Url "$BaseUrl/scripts/fonts.ps1" `
                -Destination $fontScript

            Set-TaskStatus "Installing" "Running fonts.ps1."

            & $fontScript -FontDirectory $fontDirectory

            if (-not $?) {
                throw "fonts.ps1 execution failed."
            }

            Set-TaskStatus "Verifying" "Checking installed fonts."

            $fontFiles = Get-ChildItem `
                -Path $fontDirectory `
                -Recurse `
                -File |
                Where-Object {
                    $_.Extension -match '^\.(ttf|otf|ttc)$'
                }

            if (-not $fontFiles) {
                throw "No font files found in extracted archive."
            }

            $installedFontDirectory = "$env:WINDIR\Fonts"

            $installedNames = @(
                Get-ChildItem -Path $installedFontDirectory -File |
                    Select-Object -ExpandProperty Name
            )

            $missingFonts = @(
                $fontFiles | Where-Object {
                    $_.Name -notin $installedNames
                }
            )

            if ($missingFonts.Count -gt 0) {
                throw "$($missingFonts.Count) font files could not be verified."
            }

            Set-TaskStatus "Completed" "$($fontFiles.Count) font files verified."
        }


        # ----------------------------------------------------
        # NEPALI ROMANIZED
        # ----------------------------------------------------

        elseif ($TaskName -eq "Nepali Romanized") {

            if (Test-NepaliInstalled) {

                Set-TaskStatus "Skipped" "Nepali Romanized already detected."

                return
            }

            $archive = Join-Path $WorkRoot "Downloads\NepaliRomanized.zip"

            $extractPath = Join-Path $WorkRoot "Extracted\NepaliRomanized"

            Get-RemoteFile `
                -Url "$BaseUrl/nepali_romanized.zip" `
                -Destination $archive

            Set-TaskStatus "Installing" "Extracting Nepali Romanized."

            New-Item -ItemType Directory `
                -Path $extractPath `
                -Force | Out-Null

            Expand-Archive `
                -Path $archive `
                -DestinationPath $extractPath `
                -Force

            # Find the included setup file.

            $setups = @(
                Get-ChildItem `
                    -Path $extractPath `
                    -Recurse `
                    -File |
                    Where-Object {
                        $_.Name -match 'setup' -and
                        $_.Extension -in @('.exe', '.msi', '.ps1')
                    }
            )

            if ($setups.Count -ne 1) {
                throw "Expected exactly one setup file, found $($setups.Count)."
            }

            $setup = $setups[0]

            Set-TaskStatus "Installing" "Running $($setup.Name)."

            if ($setup.Extension -eq ".msi") {

                $process = Start-Process `
                    -FilePath "msiexec.exe" `
                    -ArgumentList "/i `"$($setup.FullName)`" /passive /norestart" `
                    -Wait `
                    -PassThru
            }
            elseif ($setup.Extension -eq ".ps1") {

                $process = Start-Process `
                    -FilePath "powershell.exe" `
                    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($setup.FullName)`"" `
                    -Wait `
                    -PassThru
            }
            else {

                $process = Start-Process `
                    -FilePath $setup.FullName `
                    -Wait `
                    -PassThru
            }

            if ($process.ExitCode -notin @(0, 3010, 1641)) {
                throw "Nepali Romanized setup exited with code $($process.ExitCode)."
            }

            Set-TaskStatus "Verifying" "Checking Nepali Romanized installation."

            $installed = $false

            for ($i = 0; $i -lt 30; $i++) {

                if (Test-NepaliInstalled) {
                    $installed = $true
                    break
                }

                Start-Sleep -Seconds 4
            }

            if (-not $installed) {
                throw "Installer finished, but Nepali Romanized installation was not detected. Configure NepaliVerifyPath or its registry detection."
            }

            Set-TaskStatus "Completed" "Nepali Romanized successfully installed and verified."
        }


        # ----------------------------------------------------
        # WINGET
        # ----------------------------------------------------

#         elseif ($TaskName -eq "WinGet") {

#             $winget = Get-Command winget -ErrorAction SilentlyContinue

#             if (-not $winget) {
#             Set-TaskStatus "Downloading" "Updating WinGet sources."
#             & winget source update
#                 throw "WinGet is unavailable. Install Microsoft App Installer."
#             }

#             if ($LASTEXITCODE -ne 0) {
#                 throw "WinGet source update failed: $LASTEXITCODE"
#             }

#             $config = Join-Path $WorkRoot "installer.winget"

#             Get-RemoteFile `
#                 -Url "$BaseUrl/installer.winget" `
#                 -Destination $config

#             Set-TaskStatus "Installing" "Applying WinGet configuration."

#             & winget configure --file $config

#             if ($LASTEXITCODE -ne 0) {
#                 throw "WinGet configuration failed: $LASTEXITCODE"
#             }

#             Set-TaskStatus "Verifying" "WinGet configuration completed successfully."

#             Set-TaskStatus "Completed" "WinGet configuration applied successfully."
#         }

#     }
#     catch {

#         Set-TaskStatus "Failed" $_.Exception.Message

#         throw
#     }
# }














elseif ($TaskName -eq "WinGet") {

    # $winget = Get-Command winget -ErrorAction SilentlyContinue
    $winget = Get-Command winget -ErrorAction 

    if (-not $winget) {
        throw "WinGet is unavailable."
    }

    $config = Join-Path $WorkRoot "installer.winget"

    Write-Host "`n[WINGET] Executable: $($winget.Source)"

    # STEP 1: Check existing installations
    Set-TaskStatus "Checking" "Checking installed packages."

    Write-Host "`n[WINGET] Checking WinRAR..."

    & $winget.Source list --id RARLab.WinRAR --exact
    $winrarExitCode = $LASTEXITCODE

    Write-Host "[WINGET] WinRAR query exit code: $winrarExitCode"

    Write-Host "`n[WINGET] Checking AnyDesk..."

    & $winget.Source list --id AnyDeskSoftwareGmbH.AnyDesk --exact
    $anydeskExitCode = $LASTEXITCODE

    Write-Host "[WINGET] AnyDesk query exit code: $anydeskExitCode"

    # STEP 2: Refresh sources
    Set-TaskStatus "Updating Sources" "Refreshing package metadata."

    Write-Host "`n[WINGET] Updating sources..."

    & $winget.Source source update --verbose-logs
    $sourceExitCode = $LASTEXITCODE

    Write-Host "[WINGET] Source update exit code: $sourceExitCode"

    if ($sourceExitCode -ne 0) {
        throw "Source update failed: exit code $sourceExitCode"
    }

    # STEP 3: Download configuration
    Write-Host "`n[WINGET] Downloading configuration..."

    Get-RemoteFile `
        -Url "$BaseUrl/installer.winget" `
        -Destination $config

    # STEP 4: Inspect configuration
    Write-Host "`n[WINGET] Displaying configuration..."

    & $winget.Source configure show --file $config

    # STEP 5: Test desired state WITHOUT applying it
    Set-TaskStatus "Testing" "Checking configuration against current system."

    Write-Host "`n[WINGET] Testing configuration..."

    & $winget.Source configure test --file $config --verbose-logs
    $testExitCode = $LASTEXITCODE

    Write-Host "[WINGET] Configuration test exit code: $testExitCode"

    # STEP 6: Apply configuration
    Set-TaskStatus "Installing" "Applying WinGet configuration."

    Write-Host "`n[WINGET] Applying configuration..."
    Write-Host "[WINGET] Watch the output below for prompts and package operations."

    & $winget.Source configure --file $config `
        --accept-configuration-agreements `
        --verbose-logs

    $configExitCode = $LASTEXITCODE

    Write-Host "`n[WINGET] Configuration exit code: $configExitCode"

    if ($configExitCode -ne 0) {
        throw "Configuration failed: exit code $configExitCode"
    }

    Set-TaskStatus "Completed" "Configuration command completed successfully."
}


# ============================================================
# 7. START ALL FIVE PIPELINES
# ============================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "    SUBODH WINDOWS SETUP" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Starting all installation pipelines..." -ForegroundColor Yellow

$jobs = @()

foreach ($task in $taskNames) {

    $jobs += Start-ThreadJob `
        -Name $task `
        -ScriptBlock $pipelineScript `
        -ArgumentList @(
            $task,
            $baseUrl,
            $setupDirectory,
            $statuses[$task],
            $nepaliVerifyPath
        )
}

Write-Host "[OK] All five pipelines started." -ForegroundColor Green












# ============================================================
# 8. DEVELOPMENT MONITOR
# ============================================================

Write-Host "`nMonitoring installations in DEBUG MODE..." -ForegroundColor Cyan

$terminalStates = @("Completed", "Failed", "Stopped")

while ($true) {

    foreach ($job in $jobs) {

        # Receive new output from each worker.
        # Receive-Job consumes output already received, so it
        # does not repeatedly print the same messages.
        Receive-Job -Job $job -ErrorAction Continue

        # Display job state.
        Write-Host "[$($job.Name)] Job state: $($job.State)" `
            -ForegroundColor DarkGray
    }

    $activeJobs = @(
        $jobs | Where-Object {
            $_.State -notin $terminalStates
        }
    )

    if ($activeJobs.Count -eq 0) {
        break
    }

    Start-Sleep -Seconds 2
}


# ============================================================
# 9. COLLECT AND DIAGNOSE WORKERS
# ============================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "         WORKER DIAGNOSTICS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

foreach ($job in $jobs) {

    Write-Host "`n----------------------------------------"
    Write-Host "WORKER: $($job.Name)" -ForegroundColor Cyan
    Write-Host "JOB STATE: $($job.State)"

    # Display any remaining output.
    Receive-Job -Job $job -ErrorAction Continue

    # Inspect worker errors.
    foreach ($child in $job.ChildJobs) {

        if ($child.Error.Count -gt 0) {

            Write-Host "`nERRORS:" -ForegroundColor Red

            foreach ($errorItem in $child.Error) {
                Write-Host $errorItem.ToString() -ForegroundColor Red
            }
        }

        if ($child.JobStateInfo.Reason) {
            Write-Host "`nJOB FAILURE REASON:" -ForegroundColor Red
            Write-Host $child.JobStateInfo.Reason
        }
    }

    # A worker must never silently remain Pending.
    $statusFile = $statuses[$job.Name]

    $existing = Get-Content $statusFile -Raw | ConvertFrom-Json

    if ($existing.State -eq "Pending") {

        $detail = "Worker ended without updating its status. Job state: $($job.State)"

        [PSCustomObject]@{
            Task   = $job.Name
            State  = "Failed"
            Detail = $detail
            Time   = (Get-Date).ToString("s")
        } |
            ConvertTo-Json |
            Set-Content $statusFile -Encoding UTF8

        Write-Host "[DIAGNOSTIC FAILURE] $detail" -ForegroundColor Red
    }
}

Remove-Job -Job $jobs -Force


# ============================================================
# 10. FINAL REPORT
# ============================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "             FINAL REPORT" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$finalResults = foreach ($task in $taskNames) {

    Get-Content $statuses[$task] -Raw | ConvertFrom-Json
}

foreach ($result in $finalResults) {

    $color = switch ($result.State) {
        "Completed" { "Green" }
        "Skipped"   { "Cyan" }
        "Failed"    { "Red" }
        default     { "Yellow" }
    }

    Write-Host "[$($result.State)] $($result.Task)" -ForegroundColor $color
    Write-Host "    $($result.Detail)" -ForegroundColor Gray
}

$successCount = @(
    $finalResults | Where-Object {
        $_.State -in @("Completed", "Skipped")
    }
).Count

$failedCount = @(
    $finalResults | Where-Object {
        $_.State -eq "Failed"
    }
).Count

Write-Host "`nSuccessful: $successCount / 5" -ForegroundColor Green
Write-Host "Failed:     $failedCount / 5" -ForegroundColor Red

Write-Host "`nSetup process finished." -ForegroundColor Cyan



































# ============================================================
# 11. OPEN PROGRAMS AND FEATURES
# ============================================================

Write-Host "`nOpening Programs and Features..." -ForegroundColor Cyan

Start-Process `
    -FilePath "$env:WINDIR\System32\control.exe" `
    -ArgumentList "/name Microsoft.ProgramsAndFeatures"


# ============================================================
# 12. EXIT
# ============================================================

Write-Host "`nPress any key to exit..." -ForegroundColor Yellow

try {
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
catch {
    Read-Host "Press Enter to exit"
}

# irm https://get.activated.win | iex