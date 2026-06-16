# Ordo installer for Windows.
#
#   irm https://getordo.dev/install.ps1 | iex    # operator/client tools (ordo + ordo-state)
#
# For a single component, pass -Bin (piping to iex cannot forward arguments, so
# build a scriptblock):
#   & ([scriptblock]::Create((irm https://getordo.dev/install.ps1))) -Bin ordo-agent
#
# Downloads prebuilt binaries from https://dl.getordo.dev, verifies their SHA-256
# checksums, and installs them under %LOCALAPPDATA%\Ordo\bin (added to the user PATH).
#
# Environment overrides:
#   ORDO_BIN      single component to install (alternative to -Bin)
#   ORDO_VERSION  latest (default) or a tag like v0.0.6
#Requires -Version 5
param([string]$Bin)
$ErrorActionPreference = 'Stop'

$BaseUrl = 'https://dl.getordo.dev'
# Components: -Bin or ORDO_BIN selects one; the default installs the client tools.
$Bins = if ($Bin) { @($Bin) } elseif ($env:ORDO_BIN) { @($env:ORDO_BIN) } else { @('ordo', 'ordo-state') }
foreach ($b in $Bins) {
	if ($b -notin @('ordo', 'ordo-state', 'ordo-agent', 'ordo-orchestrator')) {
		throw "unknown component: $b (expected ordo, ordo-state, ordo-agent, or ordo-orchestrator)"
	}
}
$Version = if ($env:ORDO_VERSION) { $env:ORDO_VERSION } else { 'latest' }
$Target = 'x86_64-pc-windows-msvc'
$Prefix = if ($Version -eq 'latest') { "$BaseUrl/latest" } else { "$BaseUrl/$Version" }

$Tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString()))
try {
	# The checksum file lists every asset; use it to find each binary's exact
	# version-stamped filename and its expected hash.
	$sums = (Invoke-WebRequest -UseBasicParsing "$Prefix/SHA256SUMS").Content
	$dest = Join-Path $env:LOCALAPPDATA 'Ordo\bin'
	New-Item -ItemType Directory -Force -Path $dest | Out-Null

	foreach ($b in $Bins) {
		$pattern = "^([0-9a-f]{64})\s+($([regex]::Escape($b))-v[0-9].*-$([regex]::Escape($Target))\.zip)$"
		$match = $sums -split "`n" | ForEach-Object { [regex]::Match($_, $pattern) } | Where-Object { $_.Success } | Select-Object -First 1
		if (-not $match) { throw "no $b build for $Target in $Prefix" }
		$sha = $match.Groups[1].Value
		$asset = $match.Groups[2].Value

		$zip = Join-Path $Tmp $asset
		Invoke-WebRequest -UseBasicParsing "$Prefix/$asset" -OutFile $zip
		$actual = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
		if ($actual -ne $sha) { throw "checksum mismatch for $asset" }

		Expand-Archive -Path $zip -DestinationPath $Tmp -Force
		Copy-Item (Join-Path $Tmp "$b.exe") (Join-Path $dest "$b.exe") -Force
		Write-Host "installed $b to $dest\$b.exe"
	}

	# Add the install directory to the user PATH if it is not already present.
	$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
	if (($userPath -split ';') -notcontains $dest) {
		[Environment]::SetEnvironmentVariable('Path', "$userPath;$dest", 'User')
		Write-Host "added $dest to your PATH (restart the shell to pick it up)"
	}
}
finally {
	Remove-Item -Recurse -Force $Tmp
}
