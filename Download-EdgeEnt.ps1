param (
  [Parameter(Mandatory = $False)]
  [ValidateSet("x86", "x64", "arm64")]
  [string] $Architecture = "x64",

  [Parameter(Mandatory = $False)]
  [ValidateSet("Stable", "Beta", "Dev", "Canary", "EdgeUpdate")]
  [string] $Channel = "Stable",

  [Parameter(Mandatory = $False)]
  [switch] $CheckOnly,

  [Parameter(Mandatory = $False)]
  [switch] $DownloadOnly
)
$ErrorActionPreference = 'Stop'

# Fetch the latest stable Edge release info from the Microsoft Edge Updates API
$EdgeUpdates = Invoke-RestMethod -Uri "https://edgeupdates.microsoft.com/api/products"

$EdgeUpdateProduct = $EdgeUpdates | Where-Object { $_.Product -eq "EdgeUpdate" } | Select-Object -First 1
$EdgeUpdateVersion = $EdgeUpdateProduct.Releases.ProductVersion
$EdgeUpdateUrl = $EdgeUpdateProduct.Releases.Artifacts.Location
Write-Host "Latest EdgeUpdate Edge Version: $EdgeUpdateVersion"


$EdgeProduct = $EdgeUpdates | Where-Object { $_.Product -eq "$($Channel)" } | Select-Object -First 1
$EdgeRelease = $EdgeProduct.Releases | Where-Object { $_.Platform -eq 'Windows' -and $_.Architecture -eq $Architecture } | Select-Object -First 1
$EdgeArtifact = $EdgeRelease.Artifacts | Where-Object { $_.ArtifactName -eq 'msi' } | Select-Object -first 1 
$EdgeVersion = $EdgeRelease.ProductVersion
Write-Host "Latest $Channel Edge Version: $EdgeVersion"

if ($CheckOnly) {
  Write-Host "Check only mode enabled. Exiting."
  return
}

$env:PATH += ";$((Resolve-Path .\bin).Path);"

if ($DownloadOnly) {
  aria2c -x16 -s16 -j5 -c -R --console-log-level=warn "$($EdgeUpdateUrl)" -d .
  aria2c -x16 -s16 -j5 -c -R --console-log-level=warn "$($EdgeArtifact.Location)" -d .

  Write-Host "Download Done. Exiting."
  return
}

# Download the Edge installer MSI
# Invoke-WebRequest -Uri $EdgeArtifact.Location -OutFile ".\EdgeEnt.msi"
aria2c -x16 -s16 -j5 -c -R --console-log-level=warn "$($EdgeArtifact.Location)" -d . -o "EdgeEnt.msi"

# Extract the Edge installer EXE
7z e -y ".\EdgeEnt.msi" "Binary.MicrosoftEdgeInstaller" | Out-Null
Rename-Item ".\Binary.MicrosoftEdgeInstaller" ".\EdgeInstaller.exe"
Remove-Item ".\EdgeEnt.msi"

# EdgeInstaller.exe is a self-extracting Google Omaha installer.
# Extract the LZMA resource from PE.
7z e -y -t* ".\EdgeInstaller.exe" ".rsrc\0\B\102" | Out-Null
Remove-Item ".\EdgeInstaller.exe"

# This is a LZMA-compressed BCJ2 stream of tarball.
# We temporarily extract it using a Python script written by Claude Opus 4.6.
omaha_extract_tar ".\102" ".\" | Out-Null
Remove-Item ".\102"
7z x -y ".\102.tar" -o".\EdgeUpdateOffline" | Out-Null
Remove-Item ".\102.tar"

# The EdgeUpdateOffline contains:
# - EdgeUpdate all scattered files
# - `MicrosoftEdge_X64_*.*.*.*.exe.{GUID}`: Edge installer without EdgeUpdate
# - `OfflineManifest.gup`: The xml manifest of the Edge installer: install commands, etc. Useless.

# Move the Edge installer without EdgeUpdate to the current directory for packaging
Move-Item ".\EdgeUpdateOffline\MicrosoftEdge_$($Architecture)_$($EdgeVersion).exe.*" ".\MicrosoftEdge.exe"
Remove-Item ".\EdgeUpdateOffline\OfflineManifest.gup"

# Get the EdgeUpdate version from .\EdgeUpdateOffline\MicrosoftEdgeUpdate.exe
$EdgeUpdateVersion = (Get-Item ".\EdgeUpdateOffline\MicrosoftEdgeUpdate.exe").VersionInfo.FileVersion
Write-Host "EdgeUpdate version: $EdgeUpdateVersion"

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
