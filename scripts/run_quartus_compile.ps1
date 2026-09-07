$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$quartus_dir = Join-Path $root "quartus"
Set-Location $quartus_dir

Write-Host "================================================================="
Write-Host "   Quartus Prime Synthesis & Fitting for DE2-115 Accelerator   "
Write-Host "================================================================="

# Locate Quartus bin directory
$quartus_bin = $null
$search_candidates = @(
    "C:\altera_lite\24.1std\quartus\bin64",
    "C:\intelFPGA_lite\18.1\quartus\bin64",
    "C:\intelFPGA_lite\20.1\quartus\bin64",
    "C:\intelFPGA\18.1\quartus\bin64",
    "C:\intelFPGA\20.1\quartus\bin64",
    "C:\altera\13.1\quartus\bin64",
    "C:\altera\14.0\quartus\bin64",
    "C:\altera\15.0\quartus\bin64",
    "C:\altera\16.0\quartus\bin64",
    "D:\intelFPGA_lite\18.1\quartus\bin64",
    "D:\intelFPGA\18.1\quartus\bin64"
)

# Also check PATH
$cmd = Get-Command "quartus_sh" -ErrorAction SilentlyContinue
if ($cmd) {
    $quartus_bin = Split-Path -Parent $cmd.Source
} else {
    foreach ($cand in $search_candidates) {
        if (Test-Path (Join-Path $cand "quartus_sh.exe")) {
            $quartus_bin = $cand
            break
        }
    }
}

if (-not $quartus_bin) {
    Write-Warning "Quartus Prime command-line tools (quartus_sh.exe / quartus_map.exe) were not found in standard paths."
    Write-Host "`nThe complete Quartus project is fully prepared and ready for compilation:"
    Write-Host "  Project File:  $quartus_dir\int8_transformer_de2_115.qpf"
    Write-Host "  Settings File: $quartus_dir\int8_transformer_de2_115.qsf"
    Write-Host "  Timing SDC:    $quartus_dir\int8_transformer_de2_115.sdc"
    Write-Host "`nTo compile in the Quartus Prime GUI:"
    Write-Host "  1. Open Quartus Prime Lite Edition."
    Write-Host "  2. Go to File -> Open Project -> select '$quartus_dir\int8_transformer_de2_115.qpf'"
    Write-Host "  3. Click 'Processing -> Start Compilation' (Ctrl+L)."
    Write-Host "  4. Check the Compilation Report for Total Logic Elements, Multipliers, Memory Bits, and TimeQuest Fmax."
    exit 0
}

Write-Host "Found Quartus tools at: $quartus_bin"

$qmap = Join-Path $quartus_bin "quartus_map.exe"
$qfit = Join-Path $quartus_bin "quartus_fit.exe"
$qasm = Join-Path $quartus_bin "quartus_asm.exe"
$qsta = Join-Path $quartus_bin "quartus_sta.exe"

Write-Host "`n[1/4] Running Analysis & Synthesis (quartus_map)..."
& $qmap "int8_transformer_de2_115"

Write-Host "`n[2/4] Running Fitter / Place & Route (quartus_fit)..."
& $qfit "int8_transformer_de2_115"

Write-Host "`n[3/4] Running Assembler for SRAM Object File (.sof) (quartus_asm)..."
& $qasm "int8_transformer_de2_115"

Write-Host "`n[4/4] Running TimeQuest Timing Analysis (quartus_sta)..."
& $qsta "int8_transformer_de2_115"

Write-Host "`n================================================================="
Write-Host " COMPILATION COMPLETE! EXTRACTING POST-FIT HARDWARE METRICS...   "
Write-Host "================================================================="

$fit_rpt = Join-Path $quartus_dir "output_files\int8_transformer_de2_115.fit.rpt"
$sta_rpt = Join-Path $quartus_dir "output_files\int8_transformer_de2_115.sta.rpt"

if (Test-Path $fit_rpt) {
    Get-Content $fit_rpt | Select-String -Pattern "Total logic elements|Total combinational functions|Dedicated logic registers|Embedded Multiplier 9-bit elements|Total memory bits" | ForEach-Object { Write-Host $_.Line }
}

if (Test-Path $sta_rpt) {
    Get-Content $sta_rpt | Select-String -Pattern "Fmax|Restricted Fmax|Slack" | Select-Object -First 10 | ForEach-Object { Write-Host $_.Line }
}
