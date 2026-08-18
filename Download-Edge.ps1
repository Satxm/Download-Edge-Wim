param (
  [Parameter(Mandatory = $False)]
  [ValidateSet("x86", "x64", "arm64")]
  [string] $Architecture = "x64",

  [Parameter(Mandatory = $False)]
  [ValidateSet("Stable", "Win7and8", "Beta", "Dev", "Canary")]
  [string] $Channel = "Stable",

  [Parameter(Mandatory = $False)]
  [switch] $CheckOnly,

  [Parameter(Mandatory = $False)]
  [switch] $DownloadOnly
)
$ErrorActionPreference = 'Stop'

function Get-Channel {
  param (
    $Channel
  )
  switch ($Channel) {
    "Stable" { "msedge-stable-win" }
    "Win7and8" { "msedge-stable-win7and8" }
    "Beta" { "msedge-beta-win" }
    "Dev" { "msedge-dev-win" }
    "Canary" { "msedge-canary-win" }
  }
}

# Fetch the latest stable Edge release info from the Microsoft Edge Updates API
$EdgeUpdates = Invoke-RestMethod -Method Get -Uri "https://edgeupdates.microsoft.com/api/products"
$EdgeUpdateUrl = ($EdgeUpdates | Where-Object { $_.Product -eq "EdgeUpdate" }).Releases.Artifacts.Location

$EdgeUpdateVersion = ($EdgeUpdates | Where-Object { $_.Product -eq "EdgeUpdate" }).Releases.ProductVersion

Write-Host "Latest Edge Update Version: $EdgeUpdateVersion"

# $EdgeRelease = ($EdgeUpdates | Where-Object { $_.Product -eq "$Channel" } | Select-Object -First 1).Releases | Where-Object { $_.Platform -eq 'Windows' -and $_.Architecture -eq $Architecture } | Select-Object -First 1
# $EdgeVersion = $EdgeRelease.ProductVersion
# Write-Host "Latest $Channel Edge Version: $EdgeVersion"

$headers = @{"User-Agent" = "Microsoft Edge Update/$EdgeUpdateVersion;winhttp" }
$data = @{
  "targetingAttributes" = @{
    "IsInternalUser" = "True"
    "Updater"        = "MicrosoftEdgeUpdate"
    "UpdaterVersion" = "$EdgeUpdateVersion"
  }
}

$Channelurl = Get-Channel $Channel

$CheckVersionUrl = "https://msedge.api.cdp.microsoft.com/api/v2/contents/Browser/namespaces/Default/names/$Channelurl-$Architecture/versions/latest?action=select"

$EdgeVersion = (Invoke-RestMethod -Method Post -Uri $CheckVersionUrl -Headers $headers -Body($data | ConvertTo-Json -Depth 10) -ContentType "application/json").ContentId.Version

Write-Host "Latest $Channel Edge Version: $EdgeVersion"

if ($CheckOnly) {
  Write-Host "Check only mode enabled. Exiting."
  return
}

$DownloadLinkUrl = "https://msedge.api.cdp.microsoft.com/api/v1.1/internal/contents/Browser/namespaces/Default/names/$Channelurl-$Architecture/versions/$EdgeVersion/files?action=GenerateDownloadInfo"

$DownloadUrl = Invoke-RestMethod -Method Post -Uri $DownloadLinkUrl -Headers $headers

$Download = $DownloadUrl | Where-Object { $_.FileId -eq "MicrosoftEdge_$($Architecture)_$($EdgeVersion).exe" }

$env:PATH += ";$((Resolve-Path .\bin).Path);"

if ($DownloadOnly) {
  aria2c -x16 -s16 -j5 -c -R --console-log-level=warn "$($EdgeUpdateUrl)" -d .
  aria2c -x16 -s16 -j5 -c -R --console-log-level=warn "$($Download.Url)" -d . -o "$($Download.FileId)"

  Write-Host "Download Done. Exiting."
  return
}

aria2c -x16 -s16 -j5 -c -R --console-log-level=warn "$($EdgeUpdateUrl)" -d . -o "MicrosoftEdgeUpdateSetup.exe"
aria2c -x16 -s16 -j5 -c -R --console-log-level=warn "$($Download.Url)" -d . -o "MicrosoftEdge.exe"
# $EdgeUpdateVersion = (Get-Item ".\MicrosoftEdgeUpdateSetup.exe").VersionInfo.FileVersion
# $EdgeVersion = (Get-Item ".\MicrosoftEdge.exe").VersionInfo.FileVersion

# Extract the LZMA resource from PE.
7z e -y -t* ".\MicrosoftEdgeUpdateSetup.exe" ".rsrc\0\B\102" | Out-Null

# This is a LZMA-compressed BCJ2 stream of tarball.
# We temporarily extract it using a Python script written by Claude Opus 4.6.
omaha_extract_tar ".\102" ".\" | Out-Null
Remove-Item ".\102"
7z x -y ".\102.tar" -o".\EdgeUpdateOffline" | Out-Null
Remove-Item ".\102.tar"

# Extract MSEDGE.7Z from Edge installer without EdgeUpdate
7z e -y -t* ".\MicrosoftEdge.exe" ".rsrc\B7\MSEDGE.PACKED.7Z" | Out-Null
7z e -y -t* ".\MicrosoftEdge.exe" ".rsrc\BL\SETUP.EX_" | Out-Null
7z e -y ".\MSEDGE.PACKED.7Z" "MSEDGE.7z" | Out-Null
Remove-Item ".\MSEDGE.PACKED.7Z"
7z e -y ".\SETUP.EX_" "setup.exe" | Out-Null
Remove-Item ".\SETUP.EX_"
Remove-Item ".\MicrosoftEdge.exe"

# Prepare "C:\Program Files (x86)\Microsoft" for packaging Edge.wim
# .\EdgeContent -> C:\Program Files (x86)\Microsoft
if (Test-Path ".\EdgeContent") {Remove-Item ".\EdgeContent" -Force -Recurse}
New-Item ".\EdgeContent" -ItemType Directory -Force | Out-Null

New-Item ".\EdgeContent\EdgeUpdate\$EdgeUpdateVersion" -ItemType Directory -Force | Out-Null
Move-Item ".\EdgeUpdateOffline\*" ".\EdgeContent\EdgeUpdate\$EdgeUpdateVersion" -Force
Copy-Item ".\EdgeContent\EdgeUpdate\$EdgeUpdateVersion\EdgeUpdate.dat" ".\EdgeContent\EdgeUpdate\EdgeUpdate.dat" -Force
Copy-Item ".\EdgeContent\EdgeUpdate\$EdgeUpdateVersion\MicrosoftEdgeUpdate.exe" ".\EdgeContent\EdgeUpdate\MicrosoftEdgeUpdate.exe" -Force
Copy-Item ".\EdgeContent\EdgeUpdate\$EdgeUpdateVersion\CopilotUpdate.exe" ".\EdgeContent\EdgeUpdate\CopilotUpdate.exe" -Force
Move-Item ".\MicrosoftEdgeUpdateSetup.exe" ".\EdgeContent\EdgeUpdate\$EdgeUpdateVersion\MicrosoftEdgeUpdateSetup.exe" -Force
(Get-Item ".\EdgeContent\EdgeUpdate\$EdgeUpdateVersion\MicrosoftEdgeUpdateSetup.exe").LastWriteTime = (Get-Item ".\EdgeContent\EdgeUpdate\$EdgeUpdateVersion\MicrosoftEdgeUpdate.exe").LastWriteTime
Remove-Item ".\EdgeUpdateOffline"

7z x -y ".\MSEDGE.7z" -o".\EdgeContent" | Out-Null
Rename-Item ".\EdgeContent\Chrome-bin" "EdgeCore"
Move-Item ".\setup.exe" ".\EdgeContent\EdgeCore\$EdgeVersion\Installer" -Force
Remove-Item ".\MSEDGE.7z"

New-Item ".\EdgeContent\Edge\Application\$EdgeVersion" -ItemType Directory -Force | Out-Null
Copy-Item ".\EdgeContent\EdgeCore\$EdgeVersion\Edge.dat" ".\EdgeContent\Edge" -Force
Copy-Item ".\EdgeContent\EdgeCore\$EdgeVersion\*" ".\EdgeContent\Edge\Application\$EdgeVersion" -Recurse -Force
Copy-Item ".\EdgeContent\EdgeCore\$EdgeVersion\msedge.exe" ".\EdgeContent\Edge\Application" -Force
Copy-Item ".\EdgeContent\EdgeCore\$EdgeVersion\msedge_proxy.exe" ".\EdgeContent\Edge\Application" -Force
Copy-Item ".\EdgeContent\EdgeCore\$EdgeVersion\pwahelper.exe" ".\EdgeContent\Edge\Application" -Force
@"
<Application xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'>
<VisualElements
ShowNameOnSquare150x150Logo='on'
Square150x150Logo='$EdgeVersion\VisualElements\Logo.png'
Square70x70Logo='$EdgeVersion\VisualElements\SmallLogo.png'
Square44x44Logo='$EdgeVersion\VisualElements\SmallLogo.png'
ForegroundText='light'
BackgroundColor='#173A73'
ShortDisplayName='Edge'/>
</Application>
"@ -replace "`n", "`r`n" | Out-File -FilePath ".\EdgeContent\Edge\Application\msedge.VisualElementsManifest.xml" -Force -Encoding UTF8
(Get-Item ".\EdgeContent\Edge\Application\msedge.VisualElementsManifest.xml").LastWriteTime = (Get-Item ".\EdgeContent\Edge\Application\msedge.exe").LastWriteTime

New-Item ".\EdgeContent\EdgeWebView\Application\$EdgeVersion" -ItemType Directory -Force | Out-Null
Copy-Item ".\EdgeContent\EdgeCore\$EdgeVersion\EdgeWebView.dat" ".\EdgeContent\EdgeWebView" -Force
Copy-Item ".\EdgeContent\EdgeCore\$EdgeVersion\*" ".\EdgeContent\EdgeWebView\Application\$EdgeVersion" -Recurse -Force

(Get-ChildItem ".\EdgeContent" -File -Recurse).FullName | ForEach-Object {
  (Get-Item $_).CreationTime = (Get-Item $_).LastWriteTime
  (Get-Item $_).LastAccessTime = (Get-Item $_).LastWriteTime
}

(Get-ChildItem ".\EdgeContent" -Directory -Recurse).FullName | Sort-Object -Descending | ForEach-Object {
  (Get-Item $_).LastWriteTime = (Get-ChildItem $_ | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
  (Get-Item $_).CreationTime = (Get-Item $_).LastWriteTime
  (Get-Item $_).LastAccessTime = (Get-Item $_).LastWriteTime
}

# Package Edge.wim
wimlib-imagex.exe capture ".\EdgeContent" ".\Edge_$($EdgeVersion)_$($Architecture).wim" "EdgeContent" --compress=LZMS --solid

[datetime]$date = (Get-ChildItem ".\EdgeContent" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
$n = '{0:X16}' -f $date.ToFileTime()
$h = '0x{0:X8}' -f $n.Substring(0, 8)
$l = '0x{0:X8}' -f $n.Substring(8, 8)
wimlib-imagex.exe info ".\Edge_$($EdgeVersion)_$($Architecture).wim" 1 --image-property CREATIONTIME/HIGHPART=$h --image-property CREATIONTIME/LOWPART=$l --image-property LASTMODIFICATIONTIME/HIGHPART=$h --image-property LASTMODIFICATIONTIME/LOWPART=$l | Out-Null
(Get-Item ".\Edge_$($EdgeVersion)_$($Architecture).wim").LastWriteTime = (Get-ChildItem ".\EdgeContent" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
Remove-Item ".\EdgeContent" -Recurse
