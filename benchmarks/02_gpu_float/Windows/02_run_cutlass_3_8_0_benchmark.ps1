<#
.SYNOPSIS
Run local CUTLASS 3.8.0 GEMM benchmarks on Windows.

.DESCRIPTION
Runs the CUTLASS profiler built by 01_build_cutlass_3_8_0.ps1 for the local
GEMM float benchmark subset. Results are written under runs/ with raw
stdout logs, CUTLASS CSV files, a merged summary CSV, command lines, basic
system metadata, unsupported-case notes, and a short Markdown report.
#>

[CmdletBinding()]
param(
    [string]$ProfilerExe = "",
    [string]$BuildDir = "",
    [string]$Config = "Release",
    [string]$OutputRoot = "",
    [int[]]$Sizes = @(1024, 2048, 4096),
    [int]$RepeatCount = 3,
    [int]$ProfilingIterations = 50,
    [int]$WarmupIterations = 10,
    [string[]]$Precisions = @("FP4", "FP8", "FP16", "TF32", "FP32", "FP64"),
    [switch]$DryRun,
    [switch]$AllowFailures,
    [switch]$Quiet,
    [string[]]$ExtraProfilerArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $scriptRoot "runs"
}

function ConvertTo-CmdArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -match '[\s"&|<>^]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }

    return $Value
}

function Join-CmdArguments {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    return ($Arguments | ForEach-Object { ConvertTo-CmdArgument $_ }) -join " "
}

function Get-InferredBuildDir {
    param([Parameter(Mandatory = $true)][string]$ExePath)

    $releaseDir = Split-Path -Parent $ExePath
    $profilerDir = Split-Path -Parent $releaseDir
    $toolsDir = Split-Path -Parent $profilerDir
    return Split-Path -Parent $toolsDir
}

function Resolve-CutlassProfiler {
    $candidates = @()

    if ($ProfilerExe) {
        $resolvedExe = (Resolve-Path -LiteralPath $ProfilerExe -ErrorAction Stop).Path
        $candidates += [pscustomobject]@{
            Exe = $resolvedExe
            BuildDir = Get-InferredBuildDir -ExePath $resolvedExe
        }
    } elseif ($BuildDir) {
        $buildFullPath = [System.IO.Path]::GetFullPath($BuildDir)
        $candidates += [pscustomobject]@{
            Exe = Join-Path $buildFullPath "tools\profiler\$Config\cutlass_profiler.exe"
            BuildDir = $buildFullPath
        }
    } else {
        $defaultBuildDir = Join-Path $env:SystemDrive "cutlass_build\cutlass_3_8_0"
        $verifiedBuildDir = Join-Path $env:SystemDrive "cutlass_build\cutlass_3_8_0_p23"
        $localBuildDir = Join-Path $scriptRoot "cutlass-3.8.0\build"

        foreach ($candidateBuildDir in @($defaultBuildDir, $verifiedBuildDir, $localBuildDir)) {
            $candidates += [pscustomobject]@{
                Exe = Join-Path $candidateBuildDir "tools\profiler\$Config\cutlass_profiler.exe"
                BuildDir = $candidateBuildDir
            }
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate.Exe) {
            return [pscustomobject]@{
                Exe = (Resolve-Path -LiteralPath $candidate.Exe).Path
                BuildDir = [System.IO.Path]::GetFullPath($candidate.BuildDir)
            }
        }
    }

    $candidateText = ($candidates | ForEach-Object { $_.Exe }) -join "`n  "
    throw "cutlass_profiler.exe not found. Build first with .\01_build_cutlass_3_8_0.ps1, or pass -BuildDir / -ProfilerExe. Checked:`n  $candidateText"
}

function Invoke-CapturedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Exe,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$LogFile,
        [switch]$AllowFailure
    )

    $commandLine = Join-CmdArguments (@($Exe) + $Arguments)
    Set-Content -Path $LogFile -Encoding UTF8 -Value @(
        "# $Title",
        "Generated: $(Get-Date -Format o)",
        "WorkingDirectory: $WorkingDirectory",
        "Command: $commandLine",
        ""
    )
    Add-Content -Path $script:CommandsFile -Encoding UTF8 -Value $commandLine

    Write-Host ""
    Write-Host "==> $Title"
    Write-Host $commandLine

    Push-Location $WorkingDirectory
    try {
        if ($Quiet) {
            & $Exe @Arguments 2>&1 | Tee-Object -FilePath $LogFile -Append | Out-Null
        } else {
            & $Exe @Arguments 2>&1 |
                Tee-Object -FilePath $LogFile -Append |
                ForEach-Object { Write-Host $_ }
        }
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    Add-Content -Path $LogFile -Encoding UTF8 -Value @("", "ExitCode: $exitCode")
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Command failed with exit code ${exitCode}: $commandLine"
    }

    return $exitCode
}

function Save-OptionalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FileName,
        [string[]]$Arguments = @()
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    $logFile = Join-Path $metadataDir $FileName

    if (-not $command) {
        Set-Content -Path $logFile -Encoding UTF8 -Value "Command not found: $Name"
        return
    }

    Invoke-CapturedCommand `
        -Title "$Name $($Arguments -join ' ')" `
        -Exe $command.Source `
        -Arguments $Arguments `
        -WorkingDirectory $runDir `
        -LogFile $logFile `
        -AllowFailure | Out-Null
}

function Save-NvidiaSmiTopology {
    $logFile = Join-Path $metadataDir "nvidia-smi_topology.txt"
    $command = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue

    if (-not $command) {
        Set-Content -Path $logFile -Encoding UTF8 -Value "Command not found: nvidia-smi"
        return
    }

    $probeOutput = & $command.Source "topo" "-h" 2>&1
    $probeExitCode = $LASTEXITCODE
    if ($probeExitCode -ne 0) {
        Set-Content -Path $logFile -Encoding UTF8 -Value @(
            "Skipped: this Windows nvidia-smi build does not expose the topo subcommand.",
            "Probe command: $($command.Source) topo -h",
            "Probe exit code: $probeExitCode",
            "",
            "Probe output:",
            ($probeOutput | Out-String).TrimEnd()
        )
        return
    }

    Invoke-CapturedCommand `
        -Title "nvidia-smi topo -m" `
        -Exe $command.Source `
        -Arguments @("topo", "-m") `
        -WorkingDirectory $runDir `
        -LogFile $logFile `
        -AllowFailure | Out-Null
}

function Add-CsvToSummary {
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [Parameter(Mandatory = $true)][string]$SummaryPath
    )

    if (-not (Test-Path -LiteralPath $CsvPath)) {
        return
    }

    $lines = Get-Content -LiteralPath $CsvPath
    if ($lines.Count -eq 0) {
        return
    }

    if (-not (Test-Path -LiteralPath $SummaryPath)) {
        Set-Content -Path $SummaryPath -Encoding UTF8 -Value $lines[0]
    }

    if ($lines.Count -gt 1) {
        Add-Content -Path $SummaryPath -Encoding UTF8 -Value $lines[1..($lines.Count - 1)]
    }
}

function ConvertTo-DoubleOrNull {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $number = 0.0
    if ([double]::TryParse(
            $Value,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$number)) {
        return $number
    }

    return $null
}

function Format-Double {
    param(
        [Parameter(Mandatory = $true)][double]$Value,
        [int]$Digits = 2
    )

    return $Value.ToString("F$Digits", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-CsvValue {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Default = ""
    )

    $property = $Row.PSObject.Properties[$Name]
    if ($property) {
        return [string]$property.Value
    }

    return $Default
}

function Get-MetadataValue {
    param(
        [hashtable]$Metadata,
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Default = "Unavailable"
    )

    if ($Metadata.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace($Metadata[$Key])) {
        return $Metadata[$Key]
    }

    return $Default
}

function ConvertTo-MarkdownCell {
    param([string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return (($Value -replace '\|', '/') -replace "`r?`n", " ")
}

function New-ProfilerArguments {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [Parameter(Mandatory = $true)][int]$Size,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$RepeatId,
        [Parameter(Mandatory = $true)][string]$OutputPrefix,
        [Parameter(Mandatory = $true)][int]$ProfileIterations,
        [Parameter(Mandatory = $true)][int]$Warmup
    )

    $profilerArgs = @(
        "--mode=$Mode",
        "--operation=Gemm",
        "--m=$Size",
        "--n=$Size",
        "--k=$Size",
        "--A=$($Case.A)",
        "--B=$($Case.B)",
        "--C=$($Case.C)",
        "--D=$($Case.D)",
        "--accumulator-type=$($Case.Accumulator)",
        "--providers=cutlass",
        "--verification-enabled=false",
        "--profiling-iterations=$ProfileIterations",
        "--warmup-iterations=$Warmup",
        "--kernels=$($Case.KernelFilter)",
        "--tags=precision:$($Case.Precision),path:$($Case.ComputePath),benchmark:cutlass_3_8_0,repeat:$RepeatId",
        "--output=$OutputPrefix"
    )

    $profilerArgs += $ExtraProfilerArgs
    return $profilerArgs
}

function Add-UnsupportedCase {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$ProbeLog = ""
    )

    $currentSm = if ($script:GpuComputeCapability -gt 0) {
        [string]$script:GpuComputeCapability
    } else {
        "unknown"
    }

    $row = [pscustomobject]@{
        precision = $Case.Precision
        path = $Case.ComputePath
        kernel_filter = $Case.KernelFilter
        a_type = $Case.A
        b_type = $Case.B
        c_type = $Case.C
        d_type = $Case.D
        accumulator = $Case.Accumulator
        min_sm = $Case.MinimumSM
        current_sm = $currentSm
        reason = $Reason
        probe_log = $ProbeLog
    }

    if (-not (Test-Path -LiteralPath $script:UnsupportedCsv)) {
        $row | Export-Csv -Path $script:UnsupportedCsv -NoTypeInformation -Encoding UTF8
    } else {
        $row | Export-Csv -Path $script:UnsupportedCsv -NoTypeInformation -Encoding UTF8 -Append
    }
}

function Get-CutlassComputeCapability {
    param([Parameter(Mandatory = $true)][string]$DeviceInfoPath)

    if (-not (Test-Path -LiteralPath $DeviceInfoPath)) {
        return 0
    }

    foreach ($line in Get-Content -LiteralPath $DeviceInfoPath) {
        if ($line -notmatch '^NVIDIA') {
            continue
        }

        $fields = $line -split ','
        if ($fields.Count -lt 2) {
            continue
        }

        $sm = 0
        if ([int]::TryParse($fields[1].Trim(), [ref]$sm)) {
            return $sm
        }
    }

    return 0
}

function Test-CutlassCaseSupport {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [Parameter(Mandatory = $true)][int]$ProbeSize,
        [Parameter(Mandatory = $true)][string]$ProfilerExe,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    if ($Case.MinimumSM -gt 0 -and $script:GpuComputeCapability -gt 0 -and $script:GpuComputeCapability -lt $Case.MinimumSM) {
        return [pscustomobject]@{
            Supported = $false
            Reason = "requires SM $($Case.MinimumSM)+, current device is SM $script:GpuComputeCapability"
            ProbeLog = ""
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Case.SkipReason)) {
        return [pscustomobject]@{
            Supported = $false
            Reason = $Case.SkipReason
            ProbeLog = ""
        }
    }

    $safeCaseName = $Case.Name -replace '[^A-Za-z0-9_.-]+', "_"
    $probeName = "probe_${safeCaseName}_m${ProbeSize}"
    $probePrefix = Join-Path $script:ProbeDir $probeName
    $probeLog = Join-Path $script:ProbeDir "$probeName.txt"
    $csvPath = "$probePrefix.gemm.csv"
    $probeArgs = New-ProfilerArguments `
        -Case $Case `
        -Size $ProbeSize `
        -Mode "dry_run" `
        -RepeatId "probe" `
        -OutputPrefix $probePrefix `
        -ProfileIterations 1 `
        -Warmup 0

    $exitCode = Invoke-CapturedCommand `
        -Title "Probe CUTLASS $($Case.Precision) $($Case.ComputePath) support" `
        -Exe $ProfilerExe `
        -Arguments $probeArgs `
        -WorkingDirectory $WorkingDirectory `
        -LogFile $probeLog `
        -AllowFailure

    if ($exitCode -ne 0) {
        return [pscustomobject]@{
            Supported = $false
            Reason = "support probe failed with exit code $exitCode"
            ProbeLog = $probeLog
        }
    }

    if (-not (Test-Path -LiteralPath $csvPath)) {
        return [pscustomobject]@{
            Supported = $false
            Reason = "support probe did not generate a matching GEMM CSV"
            ProbeLog = $probeLog
        }
    }

    $rows = @()
    try {
        $rows = @(Import-Csv -LiteralPath $csvPath)
    } catch {
        return [pscustomobject]@{
            Supported = $false
            Reason = "support probe CSV could not be read: $($_.Exception.Message)"
            ProbeLog = $probeLog
        }
    }

    $matchingRows = @($rows | Where-Object { (Get-CsvValue -Row $_ -Name "Status") -eq "success" })
    if ($matchingRows.Count -eq 0) {
        return [pscustomobject]@{
            Supported = $false
            Reason = "no CUTLASS kernel matched this precision/filter in the current profiler build"
            ProbeLog = $probeLog
        }
    }

    return [pscustomobject]@{
        Supported = $true
        Reason = ""
        ProbeLog = $probeLog
    }
}

function New-CutlassReport {
    param(
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][string]$SummaryPath
    )

    $metadataPath = Join-Path $RunDirectory "metadata.txt"
    $reportPath = Join-Path $RunDirectory "report.md"
    $metadata = @{}
    if (Test-Path -LiteralPath $metadataPath) {
        foreach ($line in Get-Content -LiteralPath $metadataPath) {
            if ($line -match '^([^:]+):\s*(.*)$') {
                $metadata[$matches[1]] = $matches[2]
            }
        }
    }

    $gpuName = "Unavailable"
    $deviceInfoPath = Join-Path $RunDirectory "metadata\cutlass_device_info.txt"
    if (Test-Path -LiteralPath $deviceInfoPath) {
        $gpuLine = Get-Content -LiteralPath $deviceInfoPath |
            Where-Object { $_ -match '^NVIDIA' } |
            Select-Object -First 1
        if ($gpuLine) {
            $gpuName = ($gpuLine -split ',')[0].Trim()
        }
    }

    $driverVersion = "Unavailable"
    $cudaDriverVersion = "Unavailable"
    $nvidiaSmiPath = Join-Path $RunDirectory "metadata\nvidia-smi.txt"
    if (Test-Path -LiteralPath $nvidiaSmiPath) {
        $driverLine = Get-Content -LiteralPath $nvidiaSmiPath |
            Where-Object { $_ -match 'Driver Version:\s*([^\s|]+)\s+CUDA Version:\s*([^\s|]+)' } |
            Select-Object -First 1
        if ($driverLine -match 'Driver Version:\s*([^\s|]+)\s+CUDA Version:\s*([^\s|]+)') {
            $driverVersion = $matches[1]
            $cudaDriverVersion = $matches[2]
        }
    }

    $cudaToolkitVersion = "Unavailable"
    $nvccPath = Join-Path $RunDirectory "metadata\nvcc_version.txt"
    if (Test-Path -LiteralPath $nvccPath) {
        $nvccLine = Get-Content -LiteralPath $nvccPath |
            Where-Object { $_ -match 'release\s+([^,\s]+)' } |
            Select-Object -First 1
        if ($nvccLine -match 'release\s+([^,\s]+)') {
            $cudaToolkitVersion = $matches[1]
        }
    }

    $reportLines = @(
        "# CUTLASS 3.8.0 GPU Float Benchmark Report",
        "",
        "Generated: $(Get-Date -Format o)",
        "",
        "## Metadata",
        "",
        "| field | value |",
        "|---|---|",
        "| Host name | $(Get-MetadataValue -Metadata $metadata -Key 'Host name') |",
        "| CPU model | $(Get-MetadataValue -Metadata $metadata -Key 'CPU model') |",
        "| GPU model | $gpuName |",
        "| GPU compute capability | $(Get-MetadataValue -Metadata $metadata -Key 'GPU compute capability') |",
        "| Driver version | $driverVersion |",
        "| CUDA driver version | $cudaDriverVersion |",
        "| CUDA toolkit version | $cudaToolkitVersion |",
        "| OS/kernel | $(Get-MetadataValue -Metadata $metadata -Key 'OS/kernel') |",
        "| Compiler | nvcc $cudaToolkitVersion |",
        "| Mode | $(Get-MetadataValue -Metadata $metadata -Key 'Mode') |",
        "| Matrix sizes | $(Get-MetadataValue -Metadata $metadata -Key 'Sizes') |",
        "| Repeat count | $(Get-MetadataValue -Metadata $metadata -Key 'Repeat count') |",
        "| Warmup iterations | $(Get-MetadataValue -Metadata $metadata -Key 'Warmup iterations') |",
        "| Profiling iterations | $(Get-MetadataValue -Metadata $metadata -Key 'Profiling iterations') |",
        "| Raw output path | $RunDirectory |",
        "| Summary CSV | $SummaryPath |",
        "| Command lines | $(Join-Path $RunDirectory 'commands.ps1') |",
        "",
        "## Results",
        ""
    )

    $csvRows = @()
    if (-not (Test-Path -LiteralPath $SummaryPath)) {
        $reportLines += "No summary CSV was generated."
    } else {
        $csvRows = @(Import-Csv -LiteralPath $SummaryPath)
    }

    $validRows = @()
    foreach ($row in $csvRows) {
        $status = Get-CsvValue -Row $row -Name "Status"
        $gflops = ConvertTo-DoubleOrNull -Value (Get-CsvValue -Row $row -Name "GFLOPs")
        $runtimeMs = ConvertTo-DoubleOrNull -Value (Get-CsvValue -Row $row -Name "Runtime")
        if ($status -eq "success" -and $null -ne $gflops -and $gflops -gt 0 -and $null -ne $runtimeMs) {
            $precision = Get-CsvValue -Row $row -Name "precision" -Default "unknown"
            $computePath = Get-CsvValue -Row $row -Name "path" -Default "unknown"
            $m = Get-CsvValue -Row $row -Name "m" -Default "0"
            $n = Get-CsvValue -Row $row -Name "n" -Default "0"
            $k = Get-CsvValue -Row $row -Name "k" -Default "0"
            $repeat = Get-CsvValue -Row $row -Name "repeat" -Default "1"
            $key = "$precision|$computePath|$m|$n|$k"
            $repeatKey = "$key|$repeat"

            $validRows += [pscustomobject]@{
                Precision = $precision
                ComputePath = $computePath
                M = $m
                N = $n
                K = $k
                Repeat = $repeat
                Operation = Get-CsvValue -Row $row -Name "Operation"
                RuntimeMs = $runtimeMs
                GFLOPs = $gflops
                Key = $key
                RepeatKey = $repeatKey
            }
        }
    }

    if ($validRows.Count -eq 0) {
        $modeText = Get-MetadataValue -Metadata $metadata -Key 'Mode'
        if ($modeText -eq "dry_run") {
            $reportLines += "No profiled rows with non-zero GFLOPs were found. This is expected in dry-run mode."
        } else {
            $reportLines += "No profiled rows with non-zero GFLOPs were found. Check unsupported_cases.csv, probes, and raw logs for the failed selection or execution path."
        }
    } else {
        $perRepeatBest = @()
        foreach ($repeatGroup in ($validRows | Group-Object -Property RepeatKey)) {
            $perRepeatBest += $repeatGroup.Group |
                Sort-Object -Property GFLOPs -Descending |
                Select-Object -First 1
        }

        $reportLines += "| precision | path | M | N | K | repeats | avg best GFLOPs | best GFLOPs | best runtime ms | best kernel |"
        $reportLines += "|---|---|---:|---:|---:|---:|---:|---:|---:|---|"

        foreach ($group in ($perRepeatBest | Group-Object -Property Key | Sort-Object Name)) {
            $rows = @($group.Group)
            $best = $rows | Sort-Object -Property GFLOPs -Descending | Select-Object -First 1
            $avgGflops = ($rows | Measure-Object -Property GFLOPs -Average).Average
            $repeatCountActual = @($rows | Select-Object -ExpandProperty Repeat -Unique).Count
            $operationText = ConvertTo-MarkdownCell -Value $best.Operation
            $reportLines += "| $($best.Precision) | $($best.ComputePath) | $($best.M) | $($best.N) | $($best.K) | $repeatCountActual | $(Format-Double -Value $avgGflops) | $(Format-Double -Value $best.GFLOPs) | $(Format-Double -Value $best.RuntimeMs -Digits 4) | ``$operationText`` |"
        }
    }

    $unsupportedPath = Join-Path $RunDirectory "unsupported_cases.csv"
    if (Test-Path -LiteralPath $unsupportedPath) {
        $unsupportedRows = @(Import-Csv -LiteralPath $unsupportedPath)
        if ($unsupportedRows.Count -gt 0) {
            $reportLines += @(
                "",
                "## Skipped / Unsupported",
                "",
                "| precision | path | filter | current SM | min SM | reason |",
                "|---|---|---|---:|---:|---|"
            )

            foreach ($row in $unsupportedRows) {
                $reportLines += "| $(ConvertTo-MarkdownCell -Value $row.precision) | $(ConvertTo-MarkdownCell -Value $row.path) | ``$(ConvertTo-MarkdownCell -Value $row.kernel_filter)`` | $(ConvertTo-MarkdownCell -Value $row.current_sm) | $(ConvertTo-MarkdownCell -Value $row.min_sm) | $(ConvertTo-MarkdownCell -Value $row.reason) |"
            }
        }
    }

    $reportLines += @(
        "",
        "Notes:",
        "",
        "- Each row first picks the fastest kernel within each repeat, then reports the average and maximum of those repeat-best values.",
        "- Runtime is the CUTLASS profiler `Runtime` column, reported here as milliseconds.",
        "- Verification is disabled for throughput measurement; raw logs and CSV files are kept next to this report."
    )

    Set-Content -Path $reportPath -Encoding UTF8 -Value $reportLines
    return $reportPath
}

$precisionSet = @{}
foreach ($precision in $Precisions) {
    $precisionSet[$precision.ToUpperInvariant()] = $true
}

function Test-PrecisionSelected {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    if ($precisionSet.ContainsKey("ALL")) {
        return $true
    }

    foreach ($name in $Names) {
        if ($precisionSet.ContainsKey($name.ToUpperInvariant())) {
            return $true
        }
    }

    return $false
}

$cases = @()
if (Test-PrecisionSelected -Names @("FP4")) {
    $cases += [pscustomobject]@{
        Name = "fp4_e2m1_tensorop"
        Precision = "FP4"
        ComputePath = "TensorCore"
        KernelFilter = "e2m1"
        A = "e2m1:row"
        B = "e2m1:column"
        C = "*:column"
        D = "*:column"
        Accumulator = "f32"
        MinimumSM = 100
        SkipReason = ""
    }
}
if (Test-PrecisionSelected -Names @("FP8", "FP8_E4M3")) {
    $cases += [pscustomobject]@{
        Name = "fp8_e4m3_tensorop"
        Precision = "FP8_E4M3"
        ComputePath = "TensorCore"
        KernelFilter = "e4m3"
        A = "fe4m3:row"
        B = "fe4m3:column"
        C = "f32:column"
        D = "f32:column"
        Accumulator = "f32"
        MinimumSM = 89
        SkipReason = ""
    }
}
if (Test-PrecisionSelected -Names @("FP8", "FP8_E5M2")) {
    $cases += [pscustomobject]@{
        Name = "fp8_e5m2_tensorop"
        Precision = "FP8_E5M2"
        ComputePath = "TensorCore"
        KernelFilter = "e5m2"
        A = "fe5m2:row"
        B = "fe5m2:column"
        C = "f32:column"
        D = "f32:column"
        Accumulator = "f32"
        MinimumSM = 89
        SkipReason = ""
    }
}
if (Test-PrecisionSelected -Names @("FP16", "F16")) {
    $cases += [pscustomobject]@{
        Name = "fp16_tensorop"
        Precision = "FP16"
        ComputePath = "TensorCore"
        KernelFilter = "16816"
        A = "f16:column"
        B = "f16:column"
        C = "*:column"
        D = "*:column"
        Accumulator = "f32"
        MinimumSM = 80
        SkipReason = ""
    }
}
if (Test-PrecisionSelected -Names @("TF32")) {
    $cases += [pscustomobject]@{
        Name = "tf32_tensorop"
        Precision = "TF32"
        ComputePath = "TensorCore"
        KernelFilter = "tf32gemm"
        A = "f32:column"
        B = "f32:column"
        C = "f32:column"
        D = "f32:column"
        Accumulator = "f32"
        MinimumSM = 80
        SkipReason = ""
    }
}
if (Test-PrecisionSelected -Names @("FP32", "F32")) {
    $cases += [pscustomobject]@{
        Name = "fp32_sgemm"
        Precision = "FP32"
        ComputePath = "CUDACore"
        KernelFilter = "sgemm"
        A = "f32:column"
        B = "f32:column"
        C = "f32:column"
        D = "f32:column"
        Accumulator = "f32"
        MinimumSM = 50
        SkipReason = ""
    }
}
if (Test-PrecisionSelected -Names @("FP64", "F64")) {
    $cases += [pscustomobject]@{
        Name = "fp64_dgemm"
        Precision = "FP64"
        ComputePath = "CUDACore"
        KernelFilter = "dgemm"
        A = "f64:column"
        B = "f64:column"
        C = "f64:column"
        D = "f64:column"
        Accumulator = "f64"
        MinimumSM = 80
        SkipReason = ""
    }
}

if ($cases.Count -eq 0) {
    throw "No benchmark cases selected. Use -Precisions FP4,FP8,FP16,TF32,FP32,FP64 or -Precisions All."
}
if ($RepeatCount -le 0) {
    throw "Repeat count must be positive. Invalid RepeatCount: $RepeatCount"
}
if ($ProfilingIterations -lt 0) {
    throw "ProfilingIterations must be zero or positive. Invalid ProfilingIterations: $ProfilingIterations"
}
if ($WarmupIterations -lt 0) {
    throw "WarmupIterations must be zero or positive. Invalid WarmupIterations: $WarmupIterations"
}
foreach ($size in $Sizes) {
    if ($size -le 0) {
        throw "Matrix sizes must be positive integers. Invalid size: $size"
    }
}

$profiler = Resolve-CutlassProfiler
$profilerDir = Split-Path -Parent $profiler.Exe
$libraryDllDir = Join-Path $profiler.BuildDir "tools\library\$Config"
if (Test-Path -LiteralPath $libraryDllDir) {
    $env:PATH = "$profilerDir;$libraryDllDir;$env:PATH"
} else {
    $env:PATH = "$profilerDir;$env:PATH"
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { "unknown_host" }
$safeHostName = $hostName -replace '[^A-Za-z0-9_.-]+', "_"
$runDir = Join-Path $OutputRoot "${timestamp}_${safeHostName}_windows"
$rawDir = Join-Path $runDir "raw"
$csvDir = Join-Path $runDir "csv"
$metadataDir = Join-Path $runDir "metadata"
$probeDir = Join-Path $runDir "probes"
New-Item -ItemType Directory -Path $rawDir, $csvDir, $metadataDir, $probeDir -Force | Out-Null

$script:CommandsFile = Join-Path $runDir "commands.ps1"
Set-Content -Path $script:CommandsFile -Encoding UTF8 -Value "# Commands for this CUTLASS benchmark run"
$script:ProbeDir = $probeDir
$script:UnsupportedCsv = Join-Path $runDir "unsupported_cases.csv"
$script:GpuComputeCapability = 0

$mode = if ($DryRun) { "dry_run" } else { "profile" }
$summaryCsv = Join-Path $runDir "summary_cutlass_gemm.csv"

$cpuName = ""
$osText = ""
try {
    $cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)
} catch {
    $cpuName = "Unavailable: $($_.Exception.Message)"
}
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $osText = "$($os.Caption) $($os.Version) build $($os.BuildNumber)"
} catch {
    $osText = "Unavailable: $($_.Exception.Message)"
}

Set-Content -Path (Join-Path $runDir "metadata.txt") -Encoding UTF8 -Value @(
    "CUTLASS 3.8.0 Windows GEMM benchmark run",
    "Generated: $(Get-Date -Format o)",
    "Host name: $hostName",
    "CPU model: $cpuName",
    "OS/kernel: $osText",
    "PowerShell: $($PSVersionTable.PSVersion)",
    "Profiler: $($profiler.Exe)",
    "Build dir: $($profiler.BuildDir)",
    "Config: $Config",
    "Mode: $mode",
    "Precisions: $($Precisions -join ',')",
    "Sizes: $($Sizes -join ',')",
    "Repeat count: $RepeatCount",
    "Profiling iterations: $ProfilingIterations",
    "Warmup iterations: $WarmupIterations",
    "Raw output path: $runDir"
)

Save-OptionalCommand -Name "nvidia-smi" -FileName "nvidia-smi.txt"
Save-NvidiaSmiTopology
Save-OptionalCommand -Name "nvcc" -FileName "nvcc_version.txt" -Arguments @("--version")
Invoke-CapturedCommand `
    -Title "cutlass_profiler device-info" `
    -Exe $profiler.Exe `
    -Arguments @("--device-info") `
    -WorkingDirectory $profilerDir `
    -LogFile (Join-Path $metadataDir "cutlass_device_info.txt") `
    -AllowFailure | Out-Null

$deviceInfoFile = Join-Path $metadataDir "cutlass_device_info.txt"
$script:GpuComputeCapability = Get-CutlassComputeCapability -DeviceInfoPath $deviceInfoFile
Add-Content -Path (Join-Path $runDir "metadata.txt") -Encoding UTF8 -Value "GPU compute capability: $script:GpuComputeCapability"

$probeSize = $Sizes[0]
$supportedCases = @()
foreach ($case in $cases) {
    $support = Test-CutlassCaseSupport `
        -Case $case `
        -ProbeSize $probeSize `
        -ProfilerExe $profiler.Exe `
        -WorkingDirectory $profilerDir

    if ($support.Supported) {
        $supportedCases += $case
    } else {
        Add-UnsupportedCase -Case $case -Reason $support.Reason -ProbeLog $support.ProbeLog
        Write-Warning "Skipping $($case.Precision) $($case.ComputePath): $($support.Reason)"
    }
}

if ($supportedCases.Count -eq 0) {
    Write-Warning "No supported CUTLASS GEMM cases were found in this profiler build. A report with unsupported-case details will still be generated."
}

foreach ($size in $Sizes) {
    foreach ($case in $supportedCases) {
        for ($repeat = 1; $repeat -le $RepeatCount; $repeat++) {
            $repeatId = "{0:D2}" -f $repeat
            $caseId = "{0}_m{1}_n{1}_k{1}_r{2}" -f $case.Name, $size, $repeatId
            $outputPrefix = Join-Path $csvDir $caseId
            $stdoutLog = Join-Path $rawDir "$caseId.txt"
            $csvPath = "$outputPrefix.gemm.csv"

            $profilerArgs = New-ProfilerArguments `
                -Case $case `
                -Size $size `
                -Mode $mode `
                -RepeatId $repeatId `
                -OutputPrefix $outputPrefix `
                -ProfileIterations $ProfilingIterations `
                -Warmup $WarmupIterations

            Invoke-CapturedCommand `
                -Title "CUTLASS $($case.Precision) GEMM $size x $size x $size repeat $repeatId" `
                -Exe $profiler.Exe `
                -Arguments $profilerArgs `
                -WorkingDirectory $profilerDir `
                -LogFile $stdoutLog `
                -AllowFailure:$AllowFailures | Out-Null

            Add-CsvToSummary -CsvPath $csvPath -SummaryPath $summaryCsv
        }
    }
}

$reportPath = New-CutlassReport -RunDirectory $runDir -SummaryPath $summaryCsv

Write-Host ""
Write-Host "Done."
Write-Host "Run directory : $runDir"
Write-Host "Summary CSV   : $summaryCsv"
Write-Host "Report        : $reportPath"
