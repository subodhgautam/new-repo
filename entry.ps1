# entry.ps1
# Compatible with: irm https://subodhgautam.github.io/new-repo/entry.ps1 | iex
# Uses built-in Start-Job; no ThreadJob module or WinGet required.

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$BaseUrl = "https://subodhgautam.github.io/new-repo"
$WorkRoot = Join-Path $env:TEMP "SubodhSetup"
$AssetsDir = Join-Path $WorkRoot "assets"
$ExtractDir = Join-Path $WorkRoot "extracted"
$LogsDir = Join-Path $WorkRoot "logs"
$VerifyScript = Join-Path $WorkRoot "verify.ps1"

@($WorkRoot, $AssetsDir, $ExtractDir, $LogsDir) | ForEach-Object {
    New-Item -ItemType Directory -Path $_ -Force | Out-Null
}

function Write-Section([string]$Text) {
    Write-Host "`n========== $Text ==========" -ForegroundColor Cyan
}

function Get-RemoteAsset {
    param([string]$RelativeUrl, [string]$Destination)

    $uri = "$BaseUrl/$($RelativeUrl.TrimStart('/'))"
    Write-Host "[DOWNLOAD] $uri" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $uri -OutFile $Destination -UseBasicParsing
    if (-not (Test-Path $Destination -PathType Leaf)) {
        throw "Download did not create: $Destination"
    }
    if ((Get-Item $Destination).Length -le 0) {
        throw "Downloaded file is empty: $Destination"
    }
    Write-Host "[DOWNLOADED] $([IO.Path]::GetFileName($Destination))" -ForegroundColor Green
}

Write-Section "DOWNLOAD ALL INSTALLERS AND ASSETS"

$downloadItems = @(
    @{ Url = "assets/executables/OfficeSetup.exe";        File = "OfficeSetup.exe" },
    @{ Url = "assets/executables/ChromeSetup.exe";        File = "ChromeSetup.exe" },
    @{ Url = "assets/executables/AnyDesk.exe";            File = "AnyDesk.exe" },
    @{ Url = "assets/executables/winrar-x64-723.exe";     File = "winrar-x64-723.exe" },
    @{ Url = "assets/nepali_romanised.zip";               File = "nepali_romanised.zip" },
    @{ Url = "assets/fonts.zip";                          File = "fonts.zip" },
    @{ Url = "scripts/verify.ps1";                        File = "verify.ps1" }
)

foreach ($item in $downloadItems) {
    Get-RemoteAsset -RelativeUrl $item.Url -Destination (Join-Path $AssetsDir $item.File)
}
Copy-Item (Join-Path $AssetsDir "verify.ps1") $VerifyScript -Force

Write-Section "START PARALLEL INSTALLATION JOBS"

$tasks = @(
    @{ Name = "Office";          Kind = "Office";  File = "OfficeSetup.exe" },
    @{ Name = "Chrome";          Kind = "Chrome";  File = "ChromeSetup.exe" },
    @{ Name = "AnyDesk";         Kind = "AnyDesk"; File = "AnyDesk.exe" },
    @{ Name = "WinRAR";          Kind = "WinRAR";  File = "winrar-x64-723.exe" },
    @{ Name = "Fonts";           Kind = "Fonts";   File = "fonts.zip" },
    @{ Name = "Nepali Romanized";Kind = "Nepali";  File = "nepali_romanised.zip" }
)

$jobs = @()
foreach ($task in $tasks) {
    $safeName = $task.Name -replace '[^a-zA-Z0-9]', '_'
    $statusPath = Join-Path $LogsDir "$safeName.status.json"
    $logPath = Join-Path $LogsDir "$safeName.log"
    $payloadPath = Join-Path $AssetsDir $task.File
    Remove-Item $logPath, $statusPath -Force -ErrorAction SilentlyContinue

    [pscustomobject]@{
        Name = $task.Name
        State = "Pending"
        Detail = "Waiting for worker"
        Started = $null
        Finished = $null
    } | ConvertTo-Json | Set-Content -Path $statusPath -Encoding UTF8

    $job = Start-Job -Name $task.Name -ArgumentList @(
        $task.Name, $task.Kind, $payloadPath, $WorkRoot, $ExtractDir,
        $statusPath, $logPath
    ) -ScriptBlock {
        param($Name, $Kind, $PayloadPath, $Root, $ExtractRoot, $StatusPath, $LogPath)

        $ErrorActionPreference = "Stop"

        function Write-WorkerLog([string]$Message) {
            $stamp = Get-Date -Format "HH:mm:ss"
            Add-Content -LiteralPath $LogPath -Value "[$stamp] $Message"
        }

        function Set-WorkerStatus([string]$State, [string]$Detail) {
            $obj = [pscustomobject]@{
                Name = $Name
                State = $State
                Detail = $Detail
                Started = $script:StartedAt
                Finished = if ($State -in @("Succeeded", "Failed")) { (Get-Date).ToString("s") } else { $null }
            }
            $temp = "$StatusPath.tmp"
            $obj | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
            Move-Item -LiteralPath $temp -Destination $StatusPath -Force
        }

        function Invoke-Installer {
            param([string]$FilePath, [string]$Arguments = "", [string]$WorkingDirectory = "")
            Write-WorkerLog "Launching: $([IO.Path]::GetFileName($FilePath)) $Arguments"
            $startParams = @{ FilePath = $FilePath; PassThru = $true; Wait = $true }
            if ($Arguments) { $startParams.ArgumentList = $Arguments }
            if ($WorkingDirectory) { $startParams.WorkingDirectory = $WorkingDirectory }
            $p = Start-Process @startParams
            Write-WorkerLog "Installer process exited with code $($p.ExitCode)"
            if ($p.ExitCode -notin @(0, 1641, 3010)) {
                throw "Installer returned exit code $($p.ExitCode)"
            }
        }

        $script:StartedAt = (Get-Date).ToString("s")
        try {
            Set-WorkerStatus "Running" "Worker started"
            Write-WorkerLog "WORKER STARTED. Kind=$Kind; Payload=$PayloadPath"

            if (-not (Test-Path -LiteralPath $PayloadPath -PathType Leaf)) {
                throw "Payload not found: $PayloadPath"
            }

            switch ($Kind) {
                "Office" {
                    Invoke-Installer -FilePath $PayloadPath
                }
                "Chrome" {
                    Invoke-Installer -FilePath $PayloadPath -Arguments "/silent /install"
                }
                "AnyDesk" {
                    $anyDeskDir = Join-Path ${env:ProgramFiles(x86)} "AnyDesk"
                    Invoke-Installer -FilePath $PayloadPath -Arguments "--install `"$anyDeskDir`" --silent"
                }
                "WinRAR" {
                    Invoke-Installer -FilePath $PayloadPath -Arguments "/S"
                }
                "Fonts" {
                    $dest = Join-Path $ExtractRoot "fonts"
                    New-Item -ItemType Directory -Path $dest -Force | Out-Null
                    Expand-Archive -LiteralPath $PayloadPath -DestinationPath $dest -Force
                    $fontFiles = @(Get-ChildItem -LiteralPath $dest -Recurse -File |
                        Where-Object { $_.Extension -match '^\.(ttf|otf|ttc)$' })
                    if ($fontFiles.Count -eq 0) { throw "No TTF, OTF, or TTC files found in fonts.zip" }

                    $userFontDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
                    New-Item -ItemType Directory -Path $userFontDir -Force | Out-Null
                    $fontReg = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
                    New-Item -Path $fontReg -Force | Out-Null

                    Add-Type -AssemblyName System.Drawing
                    $installed = 0
                    foreach ($font in $fontFiles) {
                        $target = Join-Path $userFontDir $font.Name
                        Copy-Item -LiteralPath $font.FullName -Destination $target -Force

                        $familyName = [IO.Path]::GetFileNameWithoutExtension($font.Name)
                        $collection = New-Object System.Drawing.Text.PrivateFontCollection
                        try {
                            $collection.AddFontFile($target)
                            if ($collection.Families.Count -gt 0) {
                                $familyName = $collection.Families[0].Name
                            }
                        } catch {
                            Write-WorkerLog "Could not read embedded font family name for $($font.Name); using filename."
                        } finally {
                            $collection.Dispose()
                        }

                        $formatName = if ($font.Extension -eq ".otf") { "OpenType" } else { "TrueType" }
                        New-ItemProperty -Path $fontReg -Name "$familyName ($formatName)" `
                            -Value $font.Name -PropertyType String -Force | Out-Null
                        $installed++
                    }

                    # Notify Windows that the font table changed.
                    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class FontBroadcast {
    [DllImport("gdi32.dll", CharSet=CharSet.Unicode)]
    public static extern int AddFontResourceW(string fileName);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr result);
}
"@ -ErrorAction SilentlyContinue

                    foreach ($font in $fontFiles) {
                        [void][FontBroadcast]::AddFontResourceW((Join-Path $userFontDir $font.Name))
                    }
                    $result = [UIntPtr]::Zero
                    [void][FontBroadcast]::SendMessageTimeout(
                        [IntPtr]0xffff, 0x001D, [UIntPtr]::Zero, $null, 2, 1000, [ref]$result
                    )
                    Write-WorkerLog "Processed $installed font files into the current user's Fonts directory."
                }
                "Nepali" {
                    $dest = Join-Path $ExtractRoot "nepali_romanised"
                    if (Test-Path -LiteralPath $dest) {
                        Remove-Item -LiteralPath $dest -Recurse -Force
                    }
                    New-Item -ItemType Directory -Path $dest -Force | Out-Null

                    # The archive is a multi-file bootstrapper: setup.exe needs its
                    # sibling roman_<arch>.msi files and the per-architecture DLLs,
                    # so extract everything before launching it.
                    Expand-Archive -LiteralPath $PayloadPath -DestinationPath $dest -Force
                    Write-WorkerLog "Extracted archive to $dest"

                    $setup = Get-ChildItem -LiteralPath $dest -Recurse -File |
                        Where-Object { $_.Name -ieq "setup.exe" } |
                        Sort-Object { $_.FullName.Length } |
                        Select-Object -First 1

                    if ($null -eq $setup) {
                        $msiName = if ([Environment]::Is64BitOperatingSystem) { "Roman_amd64.msi" } else { "Roman_i386.msi" }
                        $msi = Get-ChildItem -LiteralPath $dest -Recurse -File |
                            Where-Object { $_.Name -ieq $msiName } |
                            Select-Object -First 1
                        if ($null -eq $msi) {
                            throw "No setup.exe or $msiName found after extracting nepali_romanised.zip."
                        }
                        Write-WorkerLog "setup.exe not found; installing $($msi.Name) directly."
                        Invoke-Installer -FilePath "msiexec.exe" `
                            -Arguments "/i `"$($msi.FullName)`" /qn /norestart"
                    } else {
                        Write-WorkerLog "Running setup.exe from $($setup.DirectoryName)"
                        Invoke-Installer -FilePath $setup.FullName `
                            -WorkingDirectory $setup.DirectoryName
                    }
                }
                default {
                    throw "Unknown worker kind: $Kind"
                }
            }

            Set-WorkerStatus "Succeeded" "Installer process completed"
            Write-WorkerLog "WORKER FINISHED."
        }
        catch {
            $message = $_.Exception.Message
            try { Write-WorkerLog "ERROR: $message" } catch {}
            try { Set-WorkerStatus "Failed" $message } catch {}
            throw
        }
    }

    $jobs += [pscustomobject]@{
        Name = $task.Name
        Job = $job
        StatusPath = $statusPath
        LogPath = $logPath
        LogOffset = 0
    }
    Write-Host "[STARTED] $($task.Name) (Job ID: $($job.Id))" -ForegroundColor Green
}

Write-Section "MONITORING WORKERS"

$completed = $false
while (-not $completed) {
    $completed = $true
    $lines = @()

    foreach ($entry in $jobs) {
        $jobState = $entry.Job.State
        if ($jobState -in @("NotStarted", "Running", "Blocked", "AtBreakpoint")) {
            $completed = $false
        }

        if (Test-Path $entry.LogPath) {
            $allLines = @(Get-Content -LiteralPath $entry.LogPath)
            if ($allLines.Count -gt $entry.LogOffset) {
                for ($i = $entry.LogOffset; $i -lt $allLines.Count; $i++) {
                    Write-Host "[$($entry.Name)] $($allLines[$i])"
                }
                $entry.LogOffset = $allLines.Count
            }
        }

        $state = $jobState
        $detail = "Worker process: $jobState"
        if (Test-Path $entry.StatusPath) {
            try {
                $status = Get-Content -LiteralPath $entry.StatusPath -Raw | ConvertFrom-Json
                $state = $status.State
                $detail = $status.Detail
            } catch {}
        }
        Write-Progress -Id 1 -Activity "Software setup" `
            -Status "$($entry.Name): $state - $detail" `
            -PercentComplete ((@($jobs | Where-Object { $_.Job.State -in @("Completed","Failed","Stopped") }).Count / $jobs.Count) * 100)
    }

    if (-not $completed) { Start-Sleep -Seconds 1 }
}

# Flush any final log lines.
foreach ($entry in $jobs) {
    if (Test-Path $entry.LogPath) {
        $allLines = @(Get-Content -LiteralPath $entry.LogPath)
        for ($i = $entry.LogOffset; $i -lt $allLines.Count; $i++) {
            Write-Host "[$($entry.Name)] $($allLines[$i])"
        }
        $entry.LogOffset = $allLines.Count
    }
    Receive-Job -Job $entry.Job -ErrorAction SilentlyContinue | Out-Null
}
Write-Progress -Id 1 -Activity "Software setup" -Completed

Write-Section "FINAL VERIFICATION"
& $VerifyScript -Root $WorkRoot

Write-Section "SETUP FINISHED"
Write-Host "Logs and downloaded files: $WorkRoot" -ForegroundColor DarkCyan
Write-Host "If an item failed verification, inspect its log in: $LogsDir"
