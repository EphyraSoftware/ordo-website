# Ordo installer for Windows.
#
#   irm https://getordo.dev/install.ps1 | iex                  # ordo (operator/client tools)
#
# For another component, pass -Bin (piping to iex cannot forward arguments, so
# build a scriptblock):
#   & ([scriptblock]::Create((irm https://getordo.dev/install.ps1))) -Bin ordo-agent
#
# Downloads a prebuilt binary from https://dl.getordo.dev, verifies its SHA-256
# checksum, and installs it under %LOCALAPPDATA%\Ordo\bin (added to the user PATH).
#
# Environment overrides:
#   ORDO_BIN      component to install (alternative to -Bin)
#   ORDO_VERSION  latest (default) or a tag like v0.0.5
#Requires -Version 5
param([string]$Bin)
$ErrorActionPreference = 'Stop'

$BaseUrl = 'https://dl.getordo.dev'
if (-not $Bin) { $Bin = if ($env:ORDO_BIN) { $env:ORDO_BIN } else { 'ordo' } }
if ($Bin -notin @('ordo', 'ordo-agent', 'ordo-orchestrator')) {
	throw "unknown component: $Bin (expected ordo, ordo-agent, or ordo-orchestrator)"
}
$Version = if ($env:ORDO_VERSION) { $env:ORDO_VERSION } else { 'latest' }
$Target = 'x86_64-pc-windows-msvc'
$Prefix = if ($Version -eq 'latest') { "$BaseUrl/latest" } else { "$BaseUrl/$Version" }

$Tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString()))
try {
	# The checksum file lists every asset; use it to find this binary's exact
	# version-stamped filename and its expected hash.
	$sums = (Invoke-WebRequest -UseBasicParsing "$Prefix/SHA256SUMS").Content
	$pattern = "^([0-9a-f]{64})\s+($([regex]::Escape($Bin))-v[0-9].*-$([regex]::Escape($Target))\.zip)$"
	$match = $sums -split "`n" | ForEach-Object { [regex]::Match($_, $pattern) } | Where-Object { $_.Success } | Select-Object -First 1
	if (-not $match) { throw "no $Bin build for $Target in $Prefix" }
	$sha = $match.Groups[1].Value
	$asset = $match.Groups[2].Value

	$zip = Join-Path $Tmp $asset
	Invoke-WebRequest -UseBasicParsing "$Prefix/$asset" -OutFile $zip
	$actual = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
	if ($actual -ne $sha) { throw "checksum mismatch for $asset" }
	Write-Host 'checksum verified'

	Expand-Archive -Path $zip -DestinationPath $Tmp -Force
	$dest = Join-Path $env:LOCALAPPDATA 'Ordo\bin'
	New-Item -ItemType Directory -Force -Path $dest | Out-Null
	Copy-Item (Join-Path $Tmp "$Bin.exe") (Join-Path $dest "$Bin.exe") -Force

	# Add the install directory to the user PATH if it is not already present.
	$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
	if (($userPath -split ';') -notcontains $dest) {
		[Environment]::SetEnvironmentVariable('Path', "$userPath;$dest", 'User')
		Write-Host "added $dest to your PATH (restart the shell to pick it up)"
	}
	Write-Host "installed $Bin to $dest\$Bin.exe"
}
finally {
	Remove-Item -Recurse -Force $Tmp
}
