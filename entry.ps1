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
    @{ Url = "assets/executables/OfficeSetup.exe";       File = "OfficeSetup.exe" },
    @{ Url = "assets/executables/ChromeSetup.exe";       File = "ChromeSetup.exe" },
    @{ Url = "assets/executables/AnyDesk.exe";            File = "AnyDesk.exe" },
    @{ Url = "assets/executables/winrar-x64-723.exe";     File = "winrar-x64-723.exe" },
    @{ Url = "assets/fonts.zip";                          File = "fonts.zip" },
    @{ Url = "assets/nepali_romanised.zip";               File = "nepali_romanised.zip" },
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