# engine.ps1
# Shared parallel installer engine used by entry.ps1 and newversions/nentry.ps1.
# Every app downloads and installs in parallel. Uses Start-ThreadJob when available,
# otherwise falls back to a built-in in-process RunspacePool (fast, no extra module).

param(
    [string]$BaseUrl = "https://subodhgautam.github.io/new-repo",
    [string]$VerifyRelativeUrl = "scripts/verify.ps1",
    [string]$VerifyFileName = "verify.ps1"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::DefaultConnectionLimit = 16

$OfficeProductId = "O365ProPlusRetail"
$OfficeLanguage = "en-us"
$WorkRoot = Join-Path $env:TEMP "SubodhSetup"
$AssetsDir = Join-Path $WorkRoot "assets"
$ExtractDir = Join-Path $WorkRoot "extracted"
$LogsDir = Join-Path $WorkRoot "logs"
$VerifyScript = Join-Path $WorkRoot $VerifyFileName

@($WorkRoot, $AssetsDir, $ExtractDir, $LogsDir) | ForEach-Object {
    New-Item -ItemType Directory -Path $_ -Force | Out-Null
}

function Write-Section([string]$Text) {
    Write-Host ""
    Write-Host ("=" * 68) -ForegroundColor DarkCyan
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host ("=" * 68) -ForegroundColor DarkCyan
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
    @{ Name = "Verify";           Kind = "Verify";   Url = $VerifyRelativeUrl;                      File = $VerifyFileName; Target = $VerifyScript }
)

$workerScript = {
    param($Name, $Kind, $Url, $PayloadPath, $Root, $ExtractRoot, $StatusPath, $LogPath, $OfficeProductId, $OfficeLanguage)

    $ErrorActionPreference = "Stop"
    $ProgressPreference = "SilentlyContinue"

    function Write-WorkerLog([string]$Message) {
        $stamp = Get-Date -Format "HH:mm:ss"
        # Keep every log entry on a single line so the monitor output stays readable.
        $clean = ($Message -replace "\s*\r?\n\s*", " ").Trim()
        Add-Content -LiteralPath $LogPath -Value "[$stamp] $clean"
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
        try {
            Move-Item -LiteralPath $temp -Destination $StatusPath -Force -ErrorAction Stop
        } catch {
            # Antivirus occasionally holds the status file for a moment; copy instead of failing the worker.
            Copy-Item -LiteralPath $temp -Destination $StatusPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }

    function Invoke-Download {
        param(
            [string]$Uri,
            [string]$Destination,
            [long]$MinBytes = 1024
        )

        $parent = Split-Path -Parent $Destination
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        # Reuse a payload that a previous run already downloaded instead of fetching it again.
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            $existing = Get-Item -LiteralPath $Destination
            if ($existing.Length -ge $MinBytes) {
                Write-WorkerLog ("REUSING cached {0} ({1} MB)" -f $existing.Name, [Math]::Round($existing.Length / 1MB, 1))
                return
            }
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }

        # Phase 1: download to a unique .part file (only this phase may retry the network).
        # A unique name avoids being blocked by a stale, still-locked part file from an earlier run.
        $part = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $candidate = "$Destination.$([Guid]::NewGuid().ToString('N')).part"
            try {
                Write-WorkerLog "DOWNLOADING $Uri (attempt $attempt/3)"
                # WebClient is considerably faster than Invoke-WebRequest under PowerShell 5.1.
                $client = New-Object System.Net.WebClient
                try {
                    $client.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
                    $client.DownloadFile($Uri, $candidate)
                } finally {
                    $client.Dispose()
                }

                $item = Get-Item -LiteralPath $candidate -ErrorAction Stop
                if ($item.Length -lt $MinBytes) { throw "Downloaded file is too small ($($item.Length) bytes)" }
                $part = $candidate
                break
            } catch {
                Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
                Write-WorkerLog "Download attempt $attempt failed: $($_.Exception.Message)"
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds (2 * $attempt)
            }
        }

        # Phase 2: place the finished download. A failed move must never trigger a re-download.
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                if (Test-Path -LiteralPath $Destination) {
                    Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop
                }
                [IO.File]::Move($part, $Destination)
                $size = (Get-Item -LiteralPath $Destination).Length
                Write-WorkerLog ("DOWNLOADED {0} ({1} MB)" -f [IO.Path]::GetFileName($Destination), [Math]::Round($size / 1MB, 1))
                return
            } catch {
                Write-WorkerLog "Could not move download into place (attempt $attempt/3): $($_.Exception.Message)"
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds 2
            }
        }
    }

    function Invoke-Installer {
        param(
            [string]$FilePath,
            [string]$Arguments = "",
            [string]$WorkingDirectory = "",
            [int[]]$AllowedExitCodes = @(0, 1641, 3010),
            [int]$TimeoutSeconds = 0
        )
        Write-WorkerLog "Launching: $([IO.Path]::GetFileName($FilePath)) $Arguments"
        $startParams = @{ FilePath = $FilePath; PassThru = $true }
        if ($Arguments) { $startParams.ArgumentList = $Arguments }
        if ($WorkingDirectory) { $startParams.WorkingDirectory = $WorkingDirectory }
        $p = Start-Process @startParams

        # Never let an installer that opens a hidden/interactive window freeze the whole run.
        if ($TimeoutSeconds -gt 0) {
            if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
                try { $p.Kill() } catch {}
                throw "$([IO.Path]::GetFileName($FilePath)) did not finish within $TimeoutSeconds seconds."
            }
        } else {
            $p.WaitForExit()
        }

        $p.Refresh()
        $code = $p.ExitCode
        Write-WorkerLog "Installer process exited with code $code"
        if ($code -notin $AllowedExitCodes) {
            throw "Installer returned exit code $code"
        }
        return $code
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

    function Test-AnyDeskInstalled {
        $paths = @()
        if (${env:ProgramFiles(x86)}) {
            $paths += Join-Path ${env:ProgramFiles(x86)} "AnyDesk\AnyDesk.exe"
        }
        if ($env:ProgramFiles) {
            $paths += Join-Path $env:ProgramFiles "AnyDesk\AnyDesk.exe"
        }
        foreach ($path in $paths) {
            if (Test-Path -LiteralPath $path -PathType Leaf) { return $true }
        }
        return $false
    }

    function Test-WinRARInstalled {
        $paths = @()
        if ($env:ProgramFiles) {
            $paths += Join-Path $env:ProgramFiles "WinRAR\WinRAR.exe"
        }
        if (${env:ProgramFiles(x86)}) {
            $paths += Join-Path ${env:ProgramFiles(x86)} "WinRAR\WinRAR.exe"
        }
        foreach ($path in $paths) {
            if (Test-Path -LiteralPath $path -PathType Leaf) { return $true }
        }
        return $false
    }

    function Expand-ArchiveFast([string]$ZipPath, [string]$Destination) {
        # ZipFile.ExtractToDirectory is far faster than Expand-Archive on Windows PowerShell 5.1.
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
    }

    $script:StartedAt = (Get-Date).ToString("s")
    try {
        # Check before downloading: skip the payload entirely when the app is already present.
        $alreadyInstalled = switch ($Kind) {
            "Office"  { Test-OfficeInstalled }
            "Chrome"  { Test-ChromeInstalled }
            "AnyDesk" { Test-AnyDeskInstalled }
            "WinRAR"  { Test-WinRARInstalled }
            default   { $false }
        }
        if ($alreadyInstalled) {
            Write-WorkerLog "$Kind is already installed; skipping download and installer."
            Set-WorkerStatus "Succeeded" "Already installed"
            return
        }

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
                $configPath = Join-Path $Root "office-config.xml"
                $configXml = @(
                    '<Configuration>'
                    '  <Add OfficeClientEdition="64" Channel="Current">'
                    ('    <Product ID="{0}">' -f $OfficeProductId)
                    ('      <Language ID="{0}" />' -f $OfficeLanguage)
                    '    </Product>'
                    '  </Add>'
                    '  <Display Level="None" AcceptEULA="TRUE" />'
                    '  <Property Name="AUTOACTIVATE" Value="0" />'
                    '  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />'
                    '</Configuration>'
                ) -join "`r`n"
                Set-Content -LiteralPath $configPath -Value $configXml -Encoding ASCII
                Write-WorkerLog "Using silent Office configuration: Product=$OfficeProductId; Language=$OfficeLanguage"
                try {
                    Invoke-Installer -FilePath $PayloadPath -Arguments "/configure `"$configPath`"" -TimeoutSeconds 3600
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
                        Invoke-Installer -FilePath $PayloadPath -Arguments "/silent /install" -TimeoutSeconds 900
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
                Invoke-Installer -FilePath $PayloadPath -Arguments "--install `"$anyDeskDir`" --silent" -TimeoutSeconds 300
            }
            "WinRAR" {
                Invoke-Installer -FilePath $PayloadPath -Arguments "/S" -TimeoutSeconds 300
            }
            "Fonts" {
                Set-WorkerStatus "Installing" "Extracting and registering fonts"
                $dest = Join-Path $ExtractRoot "fonts"
                if (Test-Path -LiteralPath $dest) {
                    Remove-Item -LiteralPath $dest -Recurse -Force
                }
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                Expand-ArchiveFast -ZipPath $PayloadPath -Destination $dest
                $fontFiles = @(Get-ChildItem -LiteralPath $dest -Recurse -File |
                    Where-Object { $_.Extension -match '^\.(ttf|otf|ttc)$' })
                if ($fontFiles.Count -eq 0) { throw "No TTF, OTF, or TTC files found in fonts.zip" }

                $userFontDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
                New-Item -ItemType Directory -Path $userFontDir -Force | Out-Null
                $fontReg = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
                New-Item -Path $fontReg -Force | Out-Null

                Add-Type -AssemblyName System.Drawing
                $installed = 0
                $skipped = 0
                $failed = 0
                foreach ($font in $fontFiles) {
                    $target = Join-Path $userFontDir $font.Name

                    # Never overwrite a font Windows may already have loaded: that is what
                    # produced "file is being used by another process" on re-runs.
                    if (Test-Path -LiteralPath $target -PathType Leaf) {
                        $existing = Get-Item -LiteralPath $target
                        if ($existing.Length -eq $font.Length) {
                            $skipped++
                        } else {
                            try {
                                Copy-Item -LiteralPath $font.FullName -Destination $target -Force -ErrorAction Stop
                                $installed++
                            } catch {
                                Write-WorkerLog "Font $($font.Name) is already loaded; keeping the existing copy."
                                $skipped++
                            }
                        }
                    } else {
                        try {
                            Copy-Item -LiteralPath $font.FullName -Destination $target -Force -ErrorAction Stop
                            $installed++
                        } catch {
                            Write-WorkerLog "FAILED to copy font $($font.Name): $($_.Exception.Message)"
                            $failed++
                            continue
                        }
                    }

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
                    try {
                        New-ItemProperty -Path $fontReg -Name "$familyName ($formatName)" `
                            -Value $font.Name -PropertyType String -Force -ErrorAction Stop | Out-Null
                    } catch {
                        Write-WorkerLog "FAILED to register font $($font.Name): $($_.Exception.Message)"
                        $failed++
                    }
                }

                # Notify Windows that the font table changed.
                if (-not ([System.Management.Automation.PSTypeName]'FontBroadcast').Type) {
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
"@
                }

                foreach ($font in $fontFiles) {
                    try {
                        [void][FontBroadcast]::AddFontResourceW((Join-Path $userFontDir $font.Name))
                    } catch {}
                }
                $result = [UIntPtr]::Zero
                [void][FontBroadcast]::SendMessageTimeout(
                    [IntPtr]0xffff, 0x001D, [UIntPtr]::Zero, $null, 2, 1000, [ref]$result
                )
                Write-WorkerLog "Fonts: $installed new, $skipped already present, $failed failed."
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
                Expand-ArchiveFast -ZipPath $PayloadPath -Destination $dest
                Write-WorkerLog "Extracted archive to $dest"

                # Prefer the bundled MSI: it installs silently and never blocks waiting for UI.
                $msiName = if ([Environment]::Is64BitOperatingSystem) { "Roman_amd64.msi" } else { "Roman_i386.msi" }
                $msi = Get-ChildItem -LiteralPath $dest -Recurse -File |
                    Where-Object { $_.Name -ieq $msiName } |
                    Select-Object -First 1

                if ($null -ne $msi) {
                    Write-WorkerLog "Installing $($msi.Name) silently."
                    Invoke-Installer -FilePath "msiexec.exe" `
                        -Arguments "/i `"$($msi.FullName)`" /qn /norestart" -TimeoutSeconds 900
                } else {
                    $setup = Get-ChildItem -LiteralPath $dest -Recurse -File |
                        Where-Object { $_.Name -ieq "setup.exe" } |
                        Sort-Object { $_.FullName.Length } |
                        Select-Object -First 1
                    if ($null -eq $setup) {
                        throw "No setup.exe or $msiName found after extracting nepali_romanised.zip."
                    }
                    Write-WorkerLog "Running setup.exe silently from $($setup.DirectoryName)"
                    Invoke-Installer -FilePath $setup.FullName `
                        -Arguments "/S" -WorkingDirectory $setup.DirectoryName -TimeoutSeconds 900
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
        OfficeProductId = $OfficeProductId
        OfficeLanguage = $OfficeLanguage
    }

    if ($WorkerEngine -eq "ThreadJob") {
        $job = Start-ThreadJob -Name $task.Name -ArgumentList @(
            $task.Name, $task.Kind, $uri, $payloadPath, $WorkRoot, $ExtractDir,
            $statusPath, $logPath, $OfficeProductId, $OfficeLanguage
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
            $allLines = @(Get-Content -LiteralPath $entry.LogPath -ErrorAction SilentlyContinue)
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
        $allLines = @(Get-Content -LiteralPath $entry.LogPath -ErrorAction SilentlyContinue)
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

Write-Host "`nOpening Control Panel..." -ForegroundColor DarkCyan
try { Start-Process "control.exe" } catch { Write-Warning "Could not open Control Panel: $($_.Exception.Message)" }

Write-Section "SETUP FINISHED"
Write-Host "Logs and downloaded files: $WorkRoot" -ForegroundColor DarkCyan
Write-Host "If an item failed verification, inspect its log in: $LogsDir"
