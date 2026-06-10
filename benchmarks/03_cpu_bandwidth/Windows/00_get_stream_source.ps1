<#
.SYNOPSIS
Download the STREAM C benchmark source used by the Windows CPU bandwidth test.
#>

[CmdletBinding()]
param(
    [string]$SourceDir = "",
    [string]$SourceUrl = "https://www.cs.virginia.edu/stream/FTP/Code/stream.c",
    [string]$FallbackUrl = "https://raw.githubusercontent.com/jeffhammond/STREAM/master/stream.c",
    [string]$LogDir = "",
    [switch]$Force,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $SourceDir) { $SourceDir = Join-Path $scriptRoot "stream-5.10" }
if (-not $LogDir) { $LogDir = Join-Path $scriptRoot "logs" }

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host $Message
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Encoding UTF8 -Value $Message
    }
}

function Resolve-InputPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-StreamSource {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -le 0) { return $false }
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    return ($text -match 'Program:\s*STREAM') -and
        ($text -match 'STREAM_ARRAY_SIZE') -and
        ($text -match 'Best Rate MB/s')
}

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    Write-Log "Downloading: $Uri"
    if ($DryRun) { return }

    $webArgs = @{
        Uri = $Uri
        OutFile = $OutFile
        ErrorAction = "Stop"
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $webArgs["UseBasicParsing"] = $true
    }
    Invoke-WebRequest @webArgs
}

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFile = Join-Path $LogDir "get_stream_source_${timestamp}.log"
Set-Content -LiteralPath $script:LogFile -Encoding UTF8 -Value "STREAM source download log"

$sourceFullPath = Resolve-InputPath -Path $SourceDir
$sourceFile = Join-Path $sourceFullPath "stream.c"
$metadataFile = Join-Path $sourceFullPath "source_metadata.txt"

Write-Log "STREAM source dir : $sourceFullPath"
Write-Log "Primary URL       : $SourceUrl"
Write-Log "Fallback URL      : $FallbackUrl"
Write-Log "Log file          : $script:LogFile"
if ($DryRun) { Write-Log "Dry run           : enabled" }

if ((Test-Path -LiteralPath $sourceFile -PathType Leaf) -and -not $Force) {
    if (-not (Test-StreamSource -Path $sourceFile)) {
        throw "Existing source is not a recognizable STREAM C source: $sourceFile"
    }
    Write-Log "Existing STREAM source is ready: $sourceFile"
    return
}

if ($DryRun) {
    Write-Log "Dry run complete. Would download stream.c to: $sourceFile"
    return
}

New-Item -ItemType Directory -Path $sourceFullPath -Force | Out-Null
$tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) "stream.c.$PID.$timestamp.tmp"
$downloadedUrl = ""

try {
    $primaryOk = $false
    try {
        Invoke-Download -Uri $SourceUrl -OutFile $tmpFile
        $primaryOk = Test-StreamSource -Path $tmpFile
    } catch {
        Write-Log "Primary download failed: $($_.Exception.Message)"
    }

    if ($primaryOk) {
        $downloadedUrl = $SourceUrl
    } else {
        Write-Log "Primary download failed or did not validate. Trying fallback."
        Invoke-Download -Uri $FallbackUrl -OutFile $tmpFile
        if (-not (Test-StreamSource -Path $tmpFile)) {
            throw "Downloaded fallback source did not look like STREAM C source."
        }
        $downloadedUrl = $FallbackUrl
    }

    Move-Item -LiteralPath $tmpFile -Destination $sourceFile -Force
    $hash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $metadataFile -Encoding UTF8 -Value @(
        "STREAM C source",
        "Downloaded: $(Get-Date -Format o)",
        "URL: $downloadedUrl",
        "Path: $sourceFile",
        "SHA256: $hash"
    )
} finally {
    if (Test-Path -LiteralPath $tmpFile) {
        Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Log "STREAM source is ready: $sourceFile"
Write-Log "Log saved to: $script:LogFile"
