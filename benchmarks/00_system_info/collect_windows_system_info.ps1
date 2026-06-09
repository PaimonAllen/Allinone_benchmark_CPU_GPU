<#
.SYNOPSIS
Collect Windows system information before CPU/GPU benchmark runs.

.DESCRIPTION
Creates a timestamped output directory and saves raw command outputs in the
same order as the first execution stage in Docs/cpu_gpu_benchmark_tool_plan.md,
with Windows equivalents where Linux-only tools are not available.
#>

[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path $PSScriptRoot "runs")
)

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { "host" }
$runDir = Join-Path $OutputRoot "${timestamp}_${hostName}_windows"
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

function New-RunFile {
    param([string]$Name)
    return (Join-Path $runDir $Name)
}

function Write-RunHeader {
    param(
        [string]$Path,
        [string]$Title
    )

    Set-Content -Path $Path -Encoding UTF8 -Value @(
        "# $Title",
        "Generated: $(Get-Date -Format o)",
        "Host: $hostName",
        "Run directory: $runDir",
        ""
    )
}

function Add-RunText {
    param(
        [string]$Path,
        [AllowEmptyString()][string]$Text
    )

    Add-Content -Path $Path -Encoding UTF8 -Value $Text
}

function Invoke-RunSection {
    param(
        [string]$FileName,
        [string]$Title,
        [scriptblock]$Body
    )

    $path = New-RunFile $FileName
    Write-RunHeader -Path $path -Title $Title

    try {
        $text = (& $Body 2>&1 | Out-String)
        if ([string]::IsNullOrWhiteSpace($text)) {
            $text = "No output."
        }
        Add-RunText -Path $path -Text $text
    } catch {
        Add-RunText -Path $path -Text "ERROR: $($_.Exception.Message)"
    }
}

function Invoke-RunTool {
    param(
        [string]$FileName,
        [string]$Title,
        [string]$Command,
        [string[]]$Arguments = @()
    )

    $path = New-RunFile $FileName
    Write-RunHeader -Path $path -Title $Title

    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Add-RunText -Path $path -Text "SKIP: command not found: $Command"
        return
    }

    Add-RunText -Path $path -Text ("Command: {0} {1}" -f $cmd.Source, ($Arguments -join " "))
    Add-RunText -Path $path -Text ""

    try {
        $global:LASTEXITCODE = 0
        $text = (& $cmd.Source @Arguments 2>&1 | Out-String)
        Add-RunText -Path $path -Text $text
        Add-RunText -Path $path -Text ""
        Add-RunText -Path $path -Text "ExitCode: $LASTEXITCODE"
    } catch {
        Add-RunText -Path $path -Text "ERROR: $($_.Exception.Message)"
    }
}

function Invoke-RunExecutable {
    param(
        [string]$FileName,
        [string]$Title,
        [string]$ExecutablePath,
        [string[]]$Arguments = @()
    )

    $path = New-RunFile $FileName
    Write-RunHeader -Path $path -Title $Title

    if (-not (Test-Path -LiteralPath $ExecutablePath)) {
        Add-RunText -Path $path -Text "SKIP: executable not found: $ExecutablePath"
        return
    }

    Add-RunText -Path $path -Text ("Command: {0} {1}" -f $ExecutablePath, ($Arguments -join " "))
    Add-RunText -Path $path -Text ""

    try {
        $global:LASTEXITCODE = 0
        $text = (& $ExecutablePath @Arguments 2>&1 | Out-String)
        Add-RunText -Path $path -Text $text
        Add-RunText -Path $path -Text ""
        Add-RunText -Path $path -Text "ExitCode: $LASTEXITCODE"
    } catch {
        Add-RunText -Path $path -Text "ERROR: $($_.Exception.Message)"
    }
}

function Get-CudaDeviceQueryPath {
    $candidates = @()
    if ($env:CUDA_PATH) {
        $candidates += (Join-Path $env:CUDA_PATH "extras\demo_suite\deviceQuery.exe")
    }
    $tool = Get-Command "deviceQuery.exe" -ErrorAction SilentlyContinue
    if ($tool) {
        $candidates += $tool.Source
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    return $null
}

Invoke-RunSection "00_summary.txt" "System summary" {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $memoryBytes = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum
    $gpuNames = (Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name) -join "; "

    "Host name: $hostName"
    "OS/kernel: $($os.Caption) $($os.Version) build $($os.BuildNumber) $($os.OSArchitecture)"
    "CPU model: $($cpu.Name)"
    "CPU cores/logical processors: $($cpu.NumberOfCores)/$($cpu.NumberOfLogicalProcessors)"
    "Memory: {0:N2} GiB" -f ($memoryBytes / 1GB)
    "GPU adapters: $gpuNames"
    "CUDA_PATH: $env:CUDA_PATH"
    ""
    "NVIDIA GPUs:"
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        & nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap,pci.bus_id,pcie.link.gen.current,pcie.link.width.current,power.limit --format=csv 2>&1
    } else {
        "SKIP: command not found: nvidia-smi"
    }
}

Invoke-RunSection "01_windows_os.txt" "Windows OS and computer system" {
    Get-CimInstance Win32_OperatingSystem |
        Select-Object Caption, Version, BuildNumber, OSArchitecture, InstallDate, LastBootUpTime |
        Format-List
    Get-CimInstance Win32_ComputerSystem |
        Select-Object Manufacturer, Model, SystemType, TotalPhysicalMemory, NumberOfProcessors, NumberOfLogicalProcessors |
        Format-List
}

Invoke-RunSection "02_cpu.txt" "CPU information" {
    Get-CimInstance Win32_Processor |
        Select-Object Name, Manufacturer, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed, L2CacheSize, L3CacheSize |
        Format-List
}

Invoke-RunSection "03_memory.txt" "Memory information" {
    "Total physical memory: {0:N2} GiB" -f (((Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum) / 1GB)
    ""
    Get-CimInstance Win32_PhysicalMemory |
        Select-Object BankLabel, DeviceLocator, Manufacturer, PartNumber, Speed, ConfiguredClockSpeed, @{Name="CapacityGiB"; Expression={[math]::Round($_.Capacity / 1GB, 2)}} |
        Format-Table -AutoSize
}

Invoke-RunSection "04_windows_numa.txt" "Windows NUMA-related information" {
    Get-CimInstance Win32_ComputerSystem |
        Select-Object NumberOfProcessors, NumberOfLogicalProcessors |
        Format-List
    Get-CimInstance Win32_Processor |
        Select-Object DeviceID, NumberOfCores, NumberOfLogicalProcessors |
        Format-Table -AutoSize
    "Note: Windows does not provide numactl --hardware. Use Sysinternals Coreinfo or vendor tools for deeper NUMA data when needed."
}

Invoke-RunTool "05_nvidia_smi.txt" "nvidia-smi" "nvidia-smi"
Invoke-RunSection "06_nvidia_smi_topo.txt" "nvidia-smi topology or PCIe equivalent" {
    $nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        "SKIP: command not found: nvidia-smi"
        return
    }

    $helpText = (& $nvidiaSmi.Source -h 2>&1 | Out-String)
    if ($helpText -match "(?m)^\s*topo\s+") {
        "Command: $($nvidiaSmi.Source) topo -m"
        ""
        & $nvidiaSmi.Source topo -m 2>&1
        return
    }

    "SKIP: this Windows nvidia-smi build does not expose the Linux 'topo' subcommand."
    "Reason: on this build, '-m' is parsed as '--mode=' for GPU clock locking, so 'nvidia-smi topo -m' reports a missing mode value."
    ""
    "PCIe equivalent query:"
    "Command: $($nvidiaSmi.Source) --query-gpu=name,pci.bus_id,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv"
    & $nvidiaSmi.Source --query-gpu=name,pci.bus_id,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv 2>&1
    ""
    "PCI counters:"
    "Command: $($nvidiaSmi.Source) pci -i 0 -gCnt"
    & $nvidiaSmi.Source pci -i 0 -gCnt 2>&1
    ""
    "PCI error counters:"
    "Command: $($nvidiaSmi.Source) pci -i 0 -gErrCnt"
    & $nvidiaSmi.Source pci -i 0 -gErrCnt 2>&1
}
Invoke-RunTool "07_nvcc_version.txt" "nvcc version" "nvcc" @("--version")

Invoke-RunSection "08_windows_pci_display.txt" "Windows PCI/display devices" {
    Get-CimInstance Win32_VideoController |
        Select-Object Name, DriverVersion, AdapterCompatibility, PNPDeviceID |
        Format-List
    Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Select-Object Status, Class, FriendlyName, InstanceId |
        Format-Table -AutoSize
}

$deviceQueryPath = Get-CudaDeviceQueryPath
if ($deviceQueryPath) {
    Invoke-RunExecutable "09_cuda_device_query.txt" "CUDA deviceQuery" $deviceQueryPath
} else {
    Invoke-RunSection "09_cuda_device_query.txt" "CUDA deviceQuery" {
        "SKIP: deviceQuery.exe not found. It is usually under `$env:CUDA_PATH\extras\demo_suite."
    }
}

Invoke-RunSection "10_compilers_and_tools.txt" "Compilers and tools" {
    $tools = @(
        "nvidia-smi", "nvcc", "cmake", "ninja", "make", "cl", "gcc", "g++",
        "clang", "clang++", "python", "py", "pip", "conda", "ncu",
        "nv-nsight-cu-cli", "cutlass_profiler", "bandwidthTest", "nvbandwidth"
    )

    foreach ($toolName in $tools) {
        $tool = Get-Command $toolName -ErrorAction SilentlyContinue
        if ($tool) {
            "FOUND`t$toolName`t$($tool.Source)"
        } else {
            "MISSING`t$toolName"
        }
    }

    ""
    "Version checks:"
    foreach ($versionCommand in @(
        @{Name="nvcc"; Args=@("--version")},
        @{Name="cmake"; Args=@("--version")},
        @{Name="ninja"; Args=@("--version")},
        @{Name="gcc"; Args=@("--version")},
        @{Name="g++"; Args=@("--version")},
        @{Name="python"; Args=@("--version")},
        @{Name="ncu"; Args=@("--version")}
    )) {
        $tool = Get-Command $versionCommand.Name -ErrorAction SilentlyContinue
        if ($tool) {
            ""
            "## $($versionCommand.Name)"
            & $tool.Source @($versionCommand.Args) 2>&1 | Select-Object -First 6
        }
    }

    ""
    "Visual Studio cl.exe candidates:"
    Get-ChildItem "C:\Program Files\Microsoft Visual Studio" -Recurse -Filter cl.exe -ErrorAction SilentlyContinue |
        Select-Object -First 10 FullName |
        Format-Table -AutoSize

    ""
    "Visual Studio developer prompt cl.exe:"
    $vsDevCmdCandidates = @(
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\Common7\Tools\VsDevCmd.bat"
    )
    $vsDevCmd = $vsDevCmdCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($vsDevCmd) {
        "Using: $vsDevCmd"
        $cmdLine = "call `"$vsDevCmd`" -arch=x64 >nul && cl"
        & cmd.exe /d /c $cmdLine 2>&1 | Select-Object -First 8
    } else {
        "SKIP: VsDevCmd.bat not found in standard locations."
    }

    ""
    "CUDA demo_suite executables:"
    if ($env:CUDA_PATH) {
        $demoSuite = Join-Path $env:CUDA_PATH "extras\demo_suite"
        if (Test-Path -LiteralPath $demoSuite) {
            Get-ChildItem $demoSuite -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @("deviceQuery.exe", "bandwidthTest.exe", "busGrind.exe", "nbody.exe") } |
                Select-Object Name, Length, FullName |
                Format-Table -AutoSize
        } else {
            "SKIP: CUDA demo_suite directory not found: $demoSuite"
        }
    } else {
        "SKIP: CUDA_PATH is not set."
    }
}

Invoke-RunSection "11_python_conda.txt" "Python and Conda environments" {
    if (Get-Command python -ErrorAction SilentlyContinue) {
        "## python"
        python --version 2>&1
        python -c "import sys; print(sys.executable)" 2>&1
        python -m pip list --format=freeze 2>&1 |
            Select-String -Pattern "^(numpy|scipy|torch|torchvision|torchaudio|cupy|tensorflow|jax|jaxlib|numba|pycuda|triton|mkl|mkl-service|intel-openmp|openblas|nvidia-|cuda-python|cutlass)=="
    } else {
        "SKIP: command not found: python"
    }

    ""
    if (Get-Command conda -ErrorAction SilentlyContinue) {
        "## conda env list"
        conda env list 2>&1
    } else {
        "SKIP: command not found: conda"
    }
}

Invoke-RunSection "12_cuda_environment.txt" "CUDA-related environment" {
    Get-ChildItem Env:CUDA* -ErrorAction SilentlyContinue | Format-Table -AutoSize
    ""
    if ($env:CUDA_PATH) {
        "CUDA toolkit root:"
        $env:CUDA_PATH
        ""
        "CUDA selected include files:"
        foreach ($header in @("cuda_runtime.h", "cublas_v2.h", "cuda_fp8.h", "cuda_fp4.h")) {
            $path = Join-Path $env:CUDA_PATH "include\$header"
            "{0}`t{1}" -f (Test-Path -LiteralPath $path), $path
        }
        ""
        "CUDA selected libraries:"
        Get-ChildItem (Join-Path $env:CUDA_PATH "lib\x64") -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "cublas|cudart|cufft|curand|cusolver|cusparse|nvrtc" } |
            Select-Object Name, Length |
            Sort-Object Name |
            Format-Table -AutoSize
    } else {
        "SKIP: CUDA_PATH is not set."
    }
}

Write-Host "System information written to: $runDir"
