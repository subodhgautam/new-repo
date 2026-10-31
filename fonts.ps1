
 

 
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




