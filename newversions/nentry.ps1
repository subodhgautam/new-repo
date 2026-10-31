# nentry.ps1
# Compatible with: irm https://subodhgautam.github.io/new-repo/newversions/nentry.ps1 | iex
# Every app downloads and installs in parallel. Uses Start-ThreadJob when available,
# otherwise falls back to a built-in in-process RunspacePool (fast, no extra module).

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::DefaultConnectionLimit = 16

$BaseUrl = "https://subodhgautam.github.io/new-repo"
$WorkRoot = Join-Path $env:TEMP "SubodhSetup"
$AssetsDir = Join-Path $WorkRoot "assets"
$ExtractDir = Join-Path $WorkRoot "extracted"
$LogsDir = Join-Path $WorkRoot "logs"
$VerifyScript = Join-Path $WorkRoot "verify.ps1"
# Replace "this.url" with the full URL to run at the end when Office is installed.
# Leave it empty to disable the post-install command.
$PostInstallUrl = "this.url"

@($WorkRoot, $AssetsDir, $ExtractDir, $LogsDir) | ForEach-Object {
    New-Item -ItemType Directory -Path $_ -Force | Out-Null
}

function Write-Section([string]$Text) {
    Write-Host ""
    Write-Host ("=" * 68) -ForegroundColor DarkCyan
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host ("=" * 68) -ForegroundColor DarkCyan
}

function Test-OfficeInstalled {
    $paths = @()
    if ($env:ProgramFiles) {
        $paths += Join-Path $env:ProgramFiles "Microsoft Office\root\Office16\WINWORD.EXE"
        $paths += Join-Path $env:ProgramFiles "Microsoft Office\Office16\WINWORD.EXE"
    }
    if (${env:ProgramFiles(x86)}) {
        $paths += Join-Path ${env:ProgramFiles(x86)} "Microsoft Office\root\Office16\WINWORD.EXE"
        $paths += Join-Path ${env:ProgramFiles(x86)} "Microsoft Office\Office16\WINWORD.EXE"
    }
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $true }
    }
    return $false
}

function Get-WorkerEngine {
    if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
        return "ThreadJob"
    }
    try {
        Import-Module ThreadJob -ErrorAction Stop
        if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
            return "ThreadJob"
        }
    } catch {}
    return "Runspace"
}

$WorkerEngine = Get-WorkerEngine
if ($WorkerEngine -eq "ThreadJob") {
    $EngineLabel = "Start-ThreadJob (in-process threads)"
} else {
    $EngineLabel = "Built-in RunspacePool (in-process, fast fallback)"
}

$tasks = @(
    @{ Name = "Office";           Kind = "Office";   Url = "assets/executables/OfficeSetup.exe";    File = "OfficeSetup.exe" },
    @{ Name = "Chrome";           Kind = "Chrome";   Url = "assets/executables/ChromeSetup.exe";    File = "ChromeSetup.exe" },
    @{ Name = "AnyDesk";          Kind = "AnyDesk";  Url = "assets/executables/AnyDesk.exe";        File = "AnyDesk.exe" },
    @{ Name = "WinRAR";           Kind = "WinRAR";   Url = "assets/executables/winrar-x64-723.exe"; File = "winrar-x64-723.exe" },
    @{ Name = "Fonts";            Kind = "Fonts";    Url = "assets/fonts.zip";                      File = "fonts.zip" },
    @{ Name = "Nepali Romanized"; Kind = "Nepali";   Url = "assets/nepali_romanised.zip";           File = "nepali_romanised.zip" },
    @{ Name = "Verify";           Kind = "Verify";   Url = "newversions/nverify.ps1";               File = "nverify.ps1"; Target = $VerifyScript }
)

$workerScript = {
    param($Name, $Kind, $Url, $PayloadPath, $Root, $ExtractRoot, $StatusPath, $LogPath)

    $ErrorActionPreference = "Stop"
    $ProgressPreference = "SilentlyContinue"

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

    function Invoke-Download {
        param([string]$Uri, [string]$Destination)

        $parent = Split-Path -Parent $Destination
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $part = "$Destination.part"

        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Write-WorkerLog "DOWNLOADING $Uri"
                Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                Invoke-WebRequest -Uri $Uri -OutFile $part -UseBasicParsing

                $item = Get-Item -LiteralPath $part -ErrorAction Stop
                if ($item.Length -le 0) { throw "Downloaded file is empty" }

                Move-Item -LiteralPath $part -Destination $Destination -Force
                Write-WorkerLog ("DOWNLOADED {0} ({1} MB)" -f [IO.Path]::GetFileName($Destination), [Math]::Round($item.Length / 1MB, 1))
                return
            } catch {
                Write-WorkerLog "Download attempt $attempt failed: $($_.Exception.Message)"
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
    }

    function Invoke-Installer {
        param(
            [string]$FilePath,
            [string]$Arguments = "",
            [string]$WorkingDirectory = "",
            [int[]]$AllowedExitCodes = @(0, 1641, 3010)
        )
        Write-WorkerLog "Launching: $([IO.Path]::GetFileName($FilePath)) $Arguments"
        $startParams = @{ FilePath = $FilePath; PassThru = $true; Wait = $true }
        if ($Arguments) { $startParams.ArgumentList = $Arguments }
        if ($WorkingDirectory) { $startParams.WorkingDirectory = $WorkingDirectory }
        $p = Start-Process @startParams
        Write-WorkerLog "Installer process exited with code $($p.ExitCode)"
        if ($p.ExitCode -notin $AllowedExitCodes) {
            throw "Installer returned exit code $($p.ExitCode)"
        }
        return $p.ExitCode
    }

    function Test-OfficeInstalled {
        $paths = @()
        if ($env:ProgramFiles) {
            $paths += Join-Path $env:ProgramFiles "Microsoft Office\root\Office16\WINWORD.EXE"
            $paths += Join-Path $env:ProgramFiles "Microsoft Office\Office16\WINWORD.EXE"
        }
        if (${env:ProgramFiles(x86)}) {
            $paths += Join-Path ${env:ProgramFiles(x86)} "Microsoft Office\root\Office16\WINWORD.EXE"
            $paths += Join-Path ${env:ProgramFiles(x86)} "Microsoft Office\Office16\WINWORD.EXE"
        }
        foreach ($path in $paths) {
            if (Test-Path -LiteralPath $path -PathType Leaf) { return $true }
        }
        return $false
    }

    function Test-ChromeInstalled {
        $paths = @()
        if ($env:ProgramFiles) {
            $paths += Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"
        }
        if (${env:ProgramFiles(x86)}) {
            $paths += Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"
        }
        if ($env:LOCALAPPDATA) {
            $paths += Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe"
        }
        foreach ($path in $paths) {
            if (Test-Path -LiteralPath $path -PathType Leaf) { return $true }
        }
        return $false
    }

    $script:StartedAt = (Get-Date).ToString("s")
    try {
        Set-WorkerStatus "Downloading" "Fetching $([IO.Path]::GetFileName($PayloadPath))"
        Write-WorkerLog "WORKER STARTED. Kind=$Kind; Url=$Url"

        Invoke-Download -Uri $Url -Destination $PayloadPath

        if ($Kind -eq "Verify") {
            Set-WorkerStatus "Succeeded" "Verification script ready"
            Write-WorkerLog "WORKER FINISHED."
            return
        }

        Set-WorkerStatus "Installing" "Launching installer"
        Write-WorkerLog "INSTALLING from $PayloadPath"

        switch ($Kind) {
            "Office" {
                try {
                    Invoke-Installer -FilePath $PayloadPath
                } catch {
                    if (Test-OfficeInstalled) {
                        Write-WorkerLog "Office installer reported an error, but Office is present; continuing."
                    } else {
                        throw
                    }
                }
            }
            "Chrome" {
                $chromeOk = $false
                for ($attempt = 1; $attempt -le 2; $attempt++) {
                    try {
                        Invoke-Installer -FilePath $PayloadPath -Arguments "/silent /install"
                    } catch {
                        Write-WorkerLog "Chrome installer attempt $attempt reported: $($_.Exception.Message)"
                    }

                    # The web installer can exit before the background install finishes.
                    for ($wait = 0; $wait -lt 60; $wait++) {
                        if (Test-ChromeInstalled) { $chromeOk = $true; break }
                        Start-Sleep -Seconds 2
                    }
                    if ($chromeOk) { break }
                    if ($attempt -lt 2) {
                        Write-WorkerLog "Chrome not detected yet; retrying installer."
                        Start-Sleep -Seconds 5
                    }
                }
                if (-not $chromeOk) {
                    throw "Chrome was not detected after 2 install attempts."
                }
                Write-WorkerLog "Chrome installation verified."
            }
            "AnyDesk" {
                $anyDeskDir = Join-Path ${env:ProgramFiles(x86)} "AnyDesk"
                Invoke-Installer -FilePath $PayloadPath -Arguments "--install `"$anyDeskDir`" --silent"
            }
            "WinRAR" {
                Invoke-Installer -FilePath $PayloadPath -Arguments "/S"
            }
            "Fonts" {
                Set-WorkerStatus "Installing" "Extracting and registering fonts"
                $dest = Join-Path $ExtractRoot "fonts"
                if (Test-Path -LiteralPath $dest) {
                    Remove-Item -LiteralPath $dest -Recurse -Force
                }
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
                Set-WorkerStatus "Installing" "Extracting and running Nepali Romanized setup"
                $dest = Join-Path $ExtractRoot "nepali_romanised"
                if (Test-Path -LiteralPath $dest) {
                    Remove-Item -LiteralPath $dest -Recurse -Force
                }
                New-Item -ItemType Directory -Path $dest -Force | Out-Null

                # Multi-file bootstrapper: setup.exe needs its sibling
                # roman_<arch>.msi files and the per-architecture DLLs.
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

Write-Section "START PARALLEL DOWNLOAD + INSTALL WORKERS"
Write-Host "  Engine: $EngineLabel" -ForegroundColor DarkGray
if ($WorkerEngine -eq "Runspace") {
    Write-Host "  Start-ThreadJob is not installed; using the built-in fast fallback." -ForegroundColor Yellow
}

$RunspacePool = $null
if ($WorkerEngine -eq "Runspace") {
    $RunspacePool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(2, $tasks.Count))
    $RunspacePool.Open()
}

$jobs = @()
foreach ($task in $tasks) {
    $safeName = $task.Name -replace '[^a-zA-Z0-9]', '_'
    $statusPath = Join-Path $LogsDir "$safeName.status.json"
    $logPath = Join-Path $LogsDir "$safeName.log"
    $payloadPath = if ($task.ContainsKey("Target")) { $task.Target } else { Join-Path $AssetsDir $task.File }
    $uri = "$BaseUrl/$($task.Url.TrimStart('/'))"
    Remove-Item $logPath, $statusPath -Force -ErrorAction SilentlyContinue

    [pscustomobject]@{
        Name = $task.Name
        State = "Pending"
        Detail = "Waiting for worker"
        Started = $null
        Finished = $null
    } | ConvertTo-Json | Set-Content -Path $statusPath -Encoding UTF8

    $workerParams = @{
        Name = $task.Name
        Kind = $task.Kind
        Url = $uri
        PayloadPath = $payloadPath
        Root = $WorkRoot
        ExtractRoot = $ExtractDir
        StatusPath = $statusPath
        LogPath = $logPath
    }

    if ($WorkerEngine -eq "ThreadJob") {
        $job = Start-ThreadJob -Name $task.Name -ArgumentList @(
            $task.Name, $task.Kind, $uri, $payloadPath, $WorkRoot, $ExtractDir,
            $statusPath, $logPath
        ) -ScriptBlock $workerScript

        $jobs += [pscustomobject]@{
            Name = $task.Name
            Engine = "ThreadJob"
            Job = $job
            PowerShell = $null
            Handle = $null
            StatusPath = $statusPath
            LogPath = $logPath
            LogOffset = 0
        }
        Write-Host "[STARTED] $($task.Name) (ThreadJob ID: $($job.Id))" -ForegroundColor Green
    } else {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $RunspacePool
        [void]$ps.AddScript($workerScript.ToString())
        foreach ($key in $workerParams.Keys) {
            [void]$ps.AddParameter($key, $workerParams[$key])
        }
        $handle = $ps.BeginInvoke()

        $jobs += [pscustomobject]@{
            Name = $task.Name
            Engine = "Runspace"
            Job = $null
            PowerShell = $ps
            Handle = $handle
            StatusPath = $statusPath
            LogPath = $logPath
            LogOffset = 0
        }
        Write-Host "[STARTED] $($task.Name) (Runspace worker)" -ForegroundColor Green
    }
}

function Test-WorkerComplete($entry) {
    if ($entry.Engine -eq "Runspace") {
        return $entry.Handle.IsCompleted
    }
    return $entry.Job.State -in @("Completed", "Failed", "Stopped")
}

Write-Section "MONITORING WORKERS"

$completed = $false
while (-not $completed) {
    $completed = $true

    foreach ($entry in $jobs) {
        $isDone = Test-WorkerComplete $entry
        if (-not $isDone) { $completed = $false }

        if (Test-Path $entry.LogPath) {
            $allLines = @(Get-Content -LiteralPath $entry.LogPath)
            if ($allLines.Count -gt $entry.LogOffset) {
                for ($i = $entry.LogOffset; $i -lt $allLines.Count; $i++) {
                    Write-Host "[$($entry.Name)] $($allLines[$i])"
                }
                $entry.LogOffset = $allLines.Count
            }
        }

        $state = if ($isDone) { "Completed" } else { "Running" }
        $detail = if ($isDone) { "Worker finished" } else { "Working" }
        if (Test-Path $entry.StatusPath) {
            try {
                $status = Get-Content -LiteralPath $entry.StatusPath -Raw | ConvertFrom-Json
                $state = $status.State
                $detail = $status.Detail
            } catch {}
        }

        $doneCount = @($jobs | Where-Object { Test-WorkerComplete $_ }).Count
        Write-Progress -Id 1 -Activity "Software setup" `
            -Status "$($entry.Name): $state - $detail" `
            -PercentComplete (($doneCount / $jobs.Count) * 100)
    }

    if (-not $completed) { Start-Sleep -Milliseconds 500 }
}

# Flush any final log lines and clean up workers.
foreach ($entry in $jobs) {
    if (Test-Path $entry.LogPath) {
        $allLines = @(Get-Content -LiteralPath $entry.LogPath)
        for ($i = $entry.LogOffset; $i -lt $allLines.Count; $i++) {
            Write-Host "[$($entry.Name)] $($allLines[$i])"
        }
        $entry.LogOffset = $allLines.Count
    }

    if ($entry.Engine -eq "Runspace") {
        try {
            [void]$entry.PowerShell.EndInvoke($entry.Handle)
        } catch {
            Write-Host "[$($entry.Name)] Worker error: $($_.Exception.Message)" -ForegroundColor Red
        }
        $entry.PowerShell.Dispose()
    } else {
        Receive-Job -Job $entry.Job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
    }
}
if ($RunspacePool) { $RunspacePool.Dispose() }
Write-Progress -Id 1 -Activity "Software setup" -Completed

if (Test-Path -LiteralPath $VerifyScript -PathType Leaf) {
    # Run the downloaded script in-memory so ExecutionPolicy Restricted cannot block it.
    $verifyContent = Get-Content -LiteralPath $VerifyScript -Raw
    & ([scriptblock]::Create($verifyContent)) -Root $WorkRoot
} else {
    Write-Section "FINAL VERIFICATION"
    Write-Warning "Verification script was not downloaded: $VerifyScript"
}

if ($PostInstallUrl -and $PostInstallUrl -ne "this.url") {
    if (Test-OfficeInstalled) {
        Write-Section "RUNNING OFFICE POST-INSTALL COMMAND"
        try {
            irm $PostInstallUrl | iex
        } catch {
            Write-Warning "Post-install command failed: $($_.Exception.Message)"
        }
    } else {
        Write-Host "Skipping post-install command: Microsoft Office was not detected." -ForegroundColor Yellow
    }
}

Write-Host "`nOpening Control Panel..." -ForegroundColor DarkCyan
try { Start-Process "control.exe" } catch { Write-Warning "Could not open Control Panel: $($_.Exception.Message)" }

Write-Section "SETUP FINISHED"
Write-Host "Logs and downloaded files: $WorkRoot" -ForegroundColor DarkCyan
Write-Host "If an item failed verification, inspect its log in: $LogsDir"
