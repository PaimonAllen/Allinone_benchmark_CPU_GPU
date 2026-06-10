<#
.SYNOPSIS
Run STREAM and generate Windows CPU bandwidth benchmark reports.
#>

[CmdletBinding()]
param(
    [string]$Binary = "",
    [string]$BuildDir = "",
    [string]$OutputRoot = "",
    [string[]]$Threads = @(),
    [int]$RepeatCount = 1,
    [string]$OmpProcBind = "close",
    [string]$OmpPlaces = "cores",
    [switch]$NoOmpAffinity,
    [switch]$Quiet,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $BuildDir) { $BuildDir = Join-Path $scriptRoot "build" }
if (-not $OutputRoot) { $OutputRoot = Join-Path $scriptRoot "runs" }

function ConvertTo-SafeName {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace '[^A-Za-z0-9_.-]', '_')
}

function Resolve-InputPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function ConvertTo-MarkdownTable {
    param(
        [Parameter(Mandatory = $true)][string[]]$Headers,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[][]]$Rows
    )

    $lines = @()
    $lines += "| " + ($Headers -join " | ") + " |"
    $lines += "| " + (($Headers | ForEach-Object { "---" }) -join " | ") + " |"
    foreach ($row in $Rows) {
        $cells = foreach ($cell in $row) {
            $text = [string]$cell
            $text.Replace("|", "/").Replace("`r`n", "<br>").Replace("`n", "<br>")
        }
        $lines += "| " + ($cells -join " | ") + " |"
    }
    return $lines
}

function Get-DefaultThreadCounts {
    param([Parameter(Mandatory = $true)][int]$LogicalCpus)

    $seen = @{}
    $result = @()
    foreach ($candidate in @(1, 8, $LogicalCpus)) {
        if ($candidate -gt 0 -and $candidate -le $LogicalCpus -and -not $seen.ContainsKey($candidate)) {
            $seen[$candidate] = $true
            $result += [int]$candidate
        }
    }
    return $result
}

function ConvertFrom-ThreadCsv {
    param([Parameter(Mandatory = $true)][string]$Text)

    $values = @()
    foreach ($item in ($Text -split ",")) {
        $trimmed = $item.Trim()
        if ($trimmed -notmatch '^[0-9]+$') {
            throw "Invalid positive integer in -Threads: $trimmed"
        }
        $value = [int]$trimmed
        if ($value -le 0) { throw "Invalid positive integer in -Threads: $trimmed" }
        $values += $value
    }
    if ($values.Count -eq 0) { throw "-Threads must not be empty." }
    return $values
}

function Find-LatestStreamBinary {
    param([Parameter(Mandatory = $true)][string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $null }
    return Get-ChildItem -LiteralPath $Directory -Filter "stream_*.exe" -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function Write-CsvRows {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Headers,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows
    )

    if ($Rows.Count -eq 0) {
        Set-Content -LiteralPath $Path -Encoding UTF8 -Value ($Headers -join ",")
        return
    }
    $Rows | Select-Object $Headers | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Capture-Command {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [Parameter(Mandatory = $true)][string]$CommandText
    )

    $lines = @(
        "# $CommandText",
        "Generated: $(Get-Date -Format o)",
        ""
    )
    try {
        $output = & $Script 2>&1
        $lines += $output | ForEach-Object { [string]$_ }
        $lines += ""
        $lines += "ExitCode: 0"
    } catch {
        $lines += $_.Exception.Message
        $lines += ""
        $lines += "ExitCode: 1"
    }
    Set-Content -LiteralPath $OutputPath -Encoding UTF8 -Value $lines
}

function Get-MetadataValue {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Metadata,
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Default = "Unavailable"
    )

    if ($Metadata.ContainsKey($Key) -and $Metadata[$Key]) { return $Metadata[$Key] }
    return $Default
}

function Parse-IntegerFromText {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $match = [regex]::Match($Text, $Pattern)
    if ($match.Success) { return [int64]$match.Groups[1].Value }
    return ""
}

if ($RepeatCount -le 0) { throw "-RepeatCount must be positive." }

$buildFullPath = Resolve-InputPath -Path $BuildDir
if (-not $Binary) {
    $latest = Find-LatestStreamBinary -Directory $buildFullPath
    if ($latest) { $Binary = $latest.FullName }
}
if (-not $Binary) { throw "No STREAM binary found. Run .\01_build_stream.ps1 first, or pass -Binary." }
$binaryFullPath = Resolve-InputPath -Path $Binary
if (-not (Test-Path -LiteralPath $binaryFullPath -PathType Leaf)) {
    throw "STREAM binary not found: $binaryFullPath"
}

$logicalCpus = [Environment]::ProcessorCount
$threadValues = if ($Threads.Count -gt 0) { ConvertFrom-ThreadCsv -Text ($Threads -join ",") } else { Get-DefaultThreadCounts -LogicalCpus $logicalCpus }

$outputRootFullPath = Resolve-InputPath -Path $OutputRoot
New-Item -ItemType Directory -Path $outputRootFullPath, (Join-Path $scriptRoot "logs") -Force | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$hostName = ConvertTo-SafeName -Value ([System.Net.Dns]::GetHostName())
$runName = "${timestamp}_${hostName}_windows"
$runDir = Join-Path $outputRootFullPath $runName
$rawDir = Join-Path $runDir "raw"
$metadataDir = Join-Path $runDir "metadata"
New-Item -ItemType Directory -Path $rawDir, $metadataDir -Force | Out-Null

$logPath = Join-Path $scriptRoot "logs\${runName}.log"
$commandsPath = Join-Path $runDir "commands.ps1"
$summaryCsv = Join-Path $runDir "summary_stream.csv"
$groupedCsv = Join-Path $runDir "summary_stream_grouped.csv"
$metadataTxt = Join-Path $runDir "metadata.txt"
$metadataJson = Join-Path $runDir "metadata.json"
$reportPath = Join-Path $runDir "report.md"

Set-Content -LiteralPath $logPath -Encoding UTF8 -Value "STREAM Windows CPU bandwidth run log"
Set-Content -LiteralPath $commandsPath -Encoding UTF8 -Value @(
    "# Commands for this STREAM benchmark run",
    "# Generated: $(Get-Date -Format o)"
)

$cpuInfo = @(Get-CimInstance Win32_Processor)
$osInfo = Get-CimInstance Win32_OperatingSystem
$computerInfo = Get-CimInstance Win32_ComputerSystem
$memoryInfo = @(Get-CimInstance Win32_PhysicalMemory)

$cpuInfo | ConvertTo-Json -Depth 12 -WarningAction SilentlyContinue | Set-Content -LiteralPath (Join-Path $metadataDir "windows_cpu_info.json") -Encoding UTF8
$osInfo | ConvertTo-Json -Depth 12 -WarningAction SilentlyContinue | Set-Content -LiteralPath (Join-Path $metadataDir "windows_os_info.json") -Encoding UTF8
$computerInfo | ConvertTo-Json -Depth 12 -WarningAction SilentlyContinue | Set-Content -LiteralPath (Join-Path $metadataDir "windows_computer_system.json") -Encoding UTF8
$memoryInfo | ConvertTo-Json -Depth 12 -WarningAction SilentlyContinue | Set-Content -LiteralPath (Join-Path $metadataDir "windows_physical_memory.json") -Encoding UTF8
Capture-Command -OutputPath (Join-Path $metadataDir "systeminfo.txt") -CommandText "systeminfo" -Script { systeminfo }
Capture-Command -OutputPath (Join-Path $metadataDir "where_cl.txt") -CommandText "where cl" -Script { where.exe cl }

$binaryBaseName = [System.IO.Path]::GetFileNameWithoutExtension($binaryFullPath)
$candidateBuildInfo = Join-Path (Split-Path -Parent $binaryFullPath) "build_info_${binaryBaseName}.json"
$buildInfoPath = ""
$buildInfo = $null
if (Test-Path -LiteralPath $candidateBuildInfo -PathType Leaf) {
    $buildInfoPath = $candidateBuildInfo
    Copy-Item -LiteralPath $candidateBuildInfo -Destination (Join-Path $runDir "build_info.json") -Force
    $buildInfo = Get-Content -LiteralPath $candidateBuildInfo -Raw | ConvertFrom-Json
}

$cpuModel = if ($cpuInfo.Count -gt 0) { $cpuInfo[0].Name } else { "Unavailable" }
$osKernel = "$($osInfo.Caption) $($osInfo.Version) build $($osInfo.BuildNumber)"
$compilerText = if ($buildInfo -and $buildInfo.compiler) { [string]$buildInfo.compiler } else { "Unavailable" }
$threadCsv = ($threadValues -join ",")
$useOmpAffinity = -not $NoOmpAffinity

Set-Content -LiteralPath $metadataTxt -Encoding UTF8 -Value @(
    "STREAM Windows CPU bandwidth benchmark run",
    "Generated: $(Get-Date -Format o)",
    "Host name: $hostName",
    "CPU model: $cpuModel",
    "Logical CPUs: $logicalCpus",
    "OS/kernel: $osKernel",
    "Binary: $binaryFullPath",
    "Build info: $(if ($buildInfoPath) { $buildInfoPath } else { 'Unavailable' })",
    "Compiler: $compilerText",
    "Thread counts: $threadCsv",
    "Repeat count: $RepeatCount",
    "OMP affinity: $useOmpAffinity",
    "OMP_PROC_BIND: $OmpProcBind",
    "OMP_PLACES: $OmpPlaces",
    "Raw output path: $rawDir",
    "Summary CSV: $summaryCsv"
)

$metadataPayload = [ordered]@{
    schema_version = 1
    generated_at = (Get-Date -Format o)
    metadata_txt = $metadataTxt
    binary = $binaryFullPath
    logical_cpus = $logicalCpus
    dry_run = [bool]$DryRun
    thread_counts = $threadValues
    repeat_count = $RepeatCount
}
if ($buildInfo) { $metadataPayload["build_info"] = $buildInfo }
$metadataPayload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metadataJson -Encoding UTF8

Write-Host "STREAM binary : $binaryFullPath"
Write-Host "Thread sweep  : $threadCsv"
Write-Host "Repeat count  : $RepeatCount"
Write-Host "Run directory : $runDir"
Write-Host "Log           : $logPath"

$envNames = @("OMP_NUM_THREADS", "OMP_PROC_BIND", "OMP_PLACES")
$oldEnv = @{}
foreach ($name in $envNames) {
    $oldEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

try {
    foreach ($threadsValue in $threadValues) {
        for ($repeat = 1; $repeat -le $RepeatCount; $repeat++) {
            $repeatId = "{0:D2}" -f $repeat
            $rawLog = Join-Path $rawDir "stream_threads${threadsValue}_r${repeatId}.txt"
            $commandLine = "`$env:OMP_NUM_THREADS='$threadsValue'; "
            if ($useOmpAffinity) {
                $commandLine += "`$env:OMP_PROC_BIND='$OmpProcBind'; `$env:OMP_PLACES='$OmpPlaces'; "
            }
            $commandLine += "& `"$binaryFullPath`""

            Add-Content -LiteralPath $commandsPath -Encoding UTF8 -Value @(
                "",
                "# STREAM threads=$threadsValue repeat=$repeat",
                $commandLine
            )
            Add-Content -LiteralPath $logPath -Encoding UTF8 -Value @("", "==> STREAM threads=$threadsValue repeat=$repeat/$RepeatCount", $commandLine)

            Set-Content -LiteralPath $rawLog -Encoding UTF8 -Value @(
                "# STREAM threads=$threadsValue repeat=$repeat",
                "Generated: $(Get-Date -Format o)",
                "Command: $commandLine",
                ""
            )

            if ($DryRun) {
                Add-Content -LiteralPath $rawLog -Encoding UTF8 -Value "Dry run: command not executed."
                continue
            }

            [Environment]::SetEnvironmentVariable("OMP_NUM_THREADS", [string]$threadsValue, "Process")
            if ($useOmpAffinity) {
                [Environment]::SetEnvironmentVariable("OMP_PROC_BIND", $OmpProcBind, "Process")
                [Environment]::SetEnvironmentVariable("OMP_PLACES", $OmpPlaces, "Process")
            }

            Write-Host ""
            Write-Host "==> STREAM threads=$threadsValue repeat=$repeat/$RepeatCount"
            Write-Host $commandLine
            $output = & $binaryFullPath 2>&1
            $exitCode = $LASTEXITCODE
            if (-not $Quiet) {
                $output | ForEach-Object { Write-Host $_ }
            }
            $output | ForEach-Object { [string]$_ } | Add-Content -LiteralPath $rawLog -Encoding UTF8
            Add-Content -LiteralPath $rawLog -Encoding UTF8 -Value @("", "ExitCode: $exitCode")
            if ($exitCode -ne 0) {
                throw "STREAM failed with exit code $exitCode for threads=$threadsValue repeat=$repeat"
            }
        }
    }
} finally {
    foreach ($name in $envNames) {
        if ($null -eq $oldEnv[$name]) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        } else {
            [Environment]::SetEnvironmentVariable($name, [string]$oldEnv[$name], "Process")
        }
    }
}

$metadata = @{}
foreach ($line in Get-Content -LiteralPath $metadataTxt -ErrorAction SilentlyContinue) {
    if ($line -match '^([^:]+):\s*(.*)$') {
        $metadata[$matches[1].Trim()] = $matches[2].Trim()
    }
}

$functionOrder = @{ Copy = 0; Scale = 1; Add = 2; Triad = 3 }
$rows = @()
foreach ($rawPath in Get-ChildItem -LiteralPath $rawDir -Filter "stream_threads*_r*.txt" -File | Sort-Object Name) {
    $text = Get-Content -LiteralPath $rawPath.FullName -Raw -Encoding UTF8
    $nameMatch = [regex]::Match($rawPath.Name, 'stream_threads([0-9]+)_r([0-9]+)\.txt$')
    $threadsValue = if ($nameMatch.Success) { [int]$nameMatch.Groups[1].Value } else { "" }
    $repeatValue = if ($nameMatch.Success) { [int]$nameMatch.Groups[2].Value } else { "" }
    $exitMatch = [regex]::Match($text, 'ExitCode:\s*([0-9]+)')
    $exitCode = if ($exitMatch.Success) { [int]$exitMatch.Groups[1].Value } else { "" }
    $validation = if ($text -match 'Solution Validates') { "valid" } else { "unknown" }
    $arraySize = Parse-IntegerFromText -Pattern 'Array size\s*=\s*([0-9]+)' -Text $text
    $bytesPerWord = Parse-IntegerFromText -Pattern 'This system uses\s*([0-9]+)\s*bytes per array element' -Text $text
    $totalMemoryMiB = ""
    $memoryMatch = [regex]::Match($text, 'Total memory required\s*=\s*([0-9.]+)\s*MiB')
    if ($memoryMatch.Success) { $totalMemoryMiB = [double]$memoryMatch.Groups[1].Value }

    foreach ($line in ($text -split "`r?`n")) {
        $match = [regex]::Match($line.Trim(), '^(Copy|Scale|Add|Triad):\s+([0-9.]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)')
        if (-not $match.Success) { continue }
        $mbs = [double]$match.Groups[2].Value
        $rows += [pscustomobject]@{
            threads = $threadsValue
            repeat = $repeatValue
            function = $match.Groups[1].Value
            best_rate_MB_s = "{0:F4}" -f $mbs
            best_rate_GB_s = "{0:F4}" -f ($mbs / 1000.0)
            avg_time_s = $match.Groups[3].Value
            min_time_s = $match.Groups[4].Value
            max_time_s = $match.Groups[5].Value
            validation = $validation
            exit_code = $exitCode
            array_size = $arraySize
            bytes_per_word = $bytesPerWord
            total_memory_MiB = $totalMemoryMiB
            raw_log = $rawPath.FullName
        }
    }
}

$summaryHeaders = @("threads", "repeat", "function", "best_rate_MB_s", "best_rate_GB_s", "avg_time_s", "min_time_s", "max_time_s", "validation", "exit_code", "array_size", "bytes_per_word", "total_memory_MiB", "raw_log")
Write-CsvRows -Path $summaryCsv -Headers $summaryHeaders -Rows $rows

$groupedRows = @()
foreach ($group in ($rows | Group-Object threads, function)) {
    $groupRows = @($group.Group)
    if ($groupRows.Count -eq 0) { continue }
    $rates = @($groupRows | ForEach-Object { [double]$_.best_rate_MB_s })
    $minTimes = @($groupRows | ForEach-Object { [double]$_.min_time_s })
    $best = $groupRows | Sort-Object @{ Expression = { [double]$_.best_rate_MB_s }; Descending = $true } | Select-Object -First 1
    $groupedRows += [pscustomobject]@{
        threads = $best.threads
        function = $best.function
        launches = $groupRows.Count
        avg_best_rate_MB_s = "{0:F4}" -f (($rates | Measure-Object -Average).Average)
        best_rate_MB_s = "{0:F4}" -f (($rates | Measure-Object -Maximum).Maximum)
        avg_best_rate_GB_s = "{0:F4}" -f ((($rates | Measure-Object -Average).Average) / 1000.0)
        best_rate_GB_s = "{0:F4}" -f ((($rates | Measure-Object -Maximum).Maximum) / 1000.0)
        best_min_time_s = "{0:F6}" -f (($minTimes | Measure-Object -Minimum).Minimum)
        validation = $best.validation
        array_size = $best.array_size
        bytes_per_word = $best.bytes_per_word
        total_memory_MiB = $best.total_memory_MiB
        best_raw_log = $best.raw_log
    }
}
$groupedRows = @($groupedRows | Sort-Object @{ Expression = { [int]$_.threads } }, @{ Expression = { $functionOrder[$_.function] } })
$groupedHeaders = @("threads", "function", "launches", "avg_best_rate_MB_s", "best_rate_MB_s", "avg_best_rate_GB_s", "best_rate_GB_s", "best_min_time_s", "validation", "array_size", "bytes_per_word", "total_memory_MiB", "best_raw_log")
Write-CsvRows -Path $groupedCsv -Headers $groupedHeaders -Rows $groupedRows

$bestByFunction = @{}
foreach ($row in $groupedRows) {
    if (-not $bestByFunction.ContainsKey($row.function) -or ([double]$row.best_rate_MB_s -gt [double]$bestByFunction[$row.function].best_rate_MB_s)) {
        $bestByFunction[$row.function] = $row
    }
}

$reportLines = @(
    "# STREAM CPU Bandwidth Benchmark Report",
    "",
    "Generated: $(Get-MetadataValue -Metadata $metadata -Key 'Generated')",
    "Host: $(Get-MetadataValue -Metadata $metadata -Key 'Host name')",
    "Run directory: $runDir",
    "",
    "## Metadata",
    ""
)
$reportLines += ConvertTo-MarkdownTable -Headers @("field", "value") -Rows @(
    @("CPU model", (Get-MetadataValue -Metadata $metadata -Key "CPU model")),
    @("Logical CPUs", (Get-MetadataValue -Metadata $metadata -Key "Logical CPUs")),
    @("OS/kernel", (Get-MetadataValue -Metadata $metadata -Key "OS/kernel")),
    @("Binary", (Get-MetadataValue -Metadata $metadata -Key "Binary")),
    @("Compiler", $compilerText),
    @("STREAM_ARRAY_SIZE", $(if ($buildInfo -and $buildInfo.stream_array_size) { $buildInfo.stream_array_size } else { "Unavailable" })),
    @("NTIMES", $(if ($buildInfo -and $buildInfo.ntimes) { $buildInfo.ntimes } else { "Unavailable" })),
    @("STREAM_TYPE", $(if ($buildInfo -and $buildInfo.stream_type) { $buildInfo.stream_type } else { "Unavailable" })),
    @("Allocation mode", $(if ($buildInfo -and $buildInfo.allocation_mode) { $buildInfo.allocation_mode } else { "Unavailable" })),
    @("Build info", (Get-MetadataValue -Metadata $metadata -Key "Build info")),
    @("Thread counts", (Get-MetadataValue -Metadata $metadata -Key "Thread counts")),
    @("Repeat count", (Get-MetadataValue -Metadata $metadata -Key "Repeat count")),
    @("OMP affinity", (Get-MetadataValue -Metadata $metadata -Key "OMP affinity")),
    @("OMP_PROC_BIND", (Get-MetadataValue -Metadata $metadata -Key "OMP_PROC_BIND")),
    @("OMP_PLACES", (Get-MetadataValue -Metadata $metadata -Key "OMP_PLACES")),
    @("Raw output path", (Get-MetadataValue -Metadata $metadata -Key "Raw output path")),
    @("Summary CSV", $summaryCsv)
)
$reportLines += ""

if ($groupedRows.Count -gt 0) {
    $reportLines += "## Result Summary"
    $reportLines += ""
    $summaryTableRows = @()
    foreach ($row in $groupedRows) {
        $summaryTableRows += ,@($row.threads, $row.function, $row.launches, $row.avg_best_rate_GB_s, $row.best_rate_GB_s, $row.best_rate_MB_s, $row.best_min_time_s, $row.validation)
    }
    $reportLines += ConvertTo-MarkdownTable -Headers @("threads", "function", "launches", "avg GB/s", "best GB/s", "best MB/s", "best min time s", "validation") -Rows $summaryTableRows
    $reportLines += ""
    $reportLines += "## Best By Function"
    $reportLines += ""
    $bestRows = @()
    foreach ($function in @("Copy", "Scale", "Add", "Triad")) {
        if ($bestByFunction.ContainsKey($function)) {
            $row = $bestByFunction[$function]
            $bestRows += ,@($row.function, $row.threads, $row.best_rate_GB_s, $row.best_rate_MB_s, $row.array_size, $row.total_memory_MiB)
        }
    }
    $reportLines += ConvertTo-MarkdownTable -Headers @("function", "threads", "best GB/s", "best MB/s", "array size", "memory MiB") -Rows $bestRows
} else {
    $reportLines += "## Result Summary"
    $reportLines += ""
    $reportLines += "No STREAM result rows were generated. This is expected in dry-run mode."
}
$reportLines += ""
$reportLines += "## Output Files"
$reportLines += ""
$outputRows = @(
    @("summary_stream.csv", "raw parsed rows for each STREAM launch and kernel"),
    @("summary_stream_grouped.csv", "grouped average/best rows by thread count and STREAM function"),
    @("metadata.txt", "human-readable run metadata"),
    @("metadata.json", "machine-readable run metadata"),
    @("commands.ps1", "exact commands used for this run"),
    @("raw/", "raw STREAM stdout logs"),
    @("metadata/", "Windows system metadata from CIM and systeminfo")
)
if (Test-Path -LiteralPath (Join-Path $runDir "build_info.json")) {
    $outputRows += ,@("build_info.json", "copied build configuration for the STREAM binary")
}
$reportLines += ConvertTo-MarkdownTable -Headers @("file", "description") -Rows $outputRows
$reportLines += ""
$reportLines += "Notes:"
$reportLines += ""
$reportLines += "- STREAM reports bandwidth in MB/s using the STREAM byte-counting convention."
$reportLines += "- GB/s in this report is decimal MB/s divided by 1000."
$reportLines += "- Copy and Scale count two arrays of traffic; Add and Triad count three arrays of traffic."
$reportLines += "- Windows MSVC OpenMP may ignore OMP_PROC_BIND and OMP_PLACES on some runtimes; the variables are still recorded for reproducibility."

Set-Content -LiteralPath $reportPath -Encoding UTF8 -Value $reportLines

Write-Host ""
Write-Host "Done."
Write-Host "Run directory : $runDir"
Write-Host "Summary CSV   : $summaryCsv"
Write-Host "Grouped CSV   : $groupedCsv"
Write-Host "Report        : $reportPath"
