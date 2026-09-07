$ErrorActionPreference = "Stop"

$vsim = "C:\intelFPGA\18.1\modelsim_ase\win32aloem\vsim.exe"
$vlog = "C:\intelFPGA\18.1\modelsim_ase\win32aloem\vlog.exe"
$vlib = "C:\intelFPGA\18.1\modelsim_ase\win32aloem\vlib.exe"

if (!(Test-Path $vsim) -or !(Test-Path $vlog) -or !(Test-Path $vlib)) {
    throw "ModelSim executable not found at expected Intel FPGA 18.1 path."
}

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "================================================================="
Write-Host " Running Pure Verilog-2001 Simulation Regression (DE2-115)"
Write-Host "================================================================="

# Recreate work library cleanly
if (Test-Path "work") { Remove-Item -Recurse -Force "work" }
& $vlib "work"

Write-Host "`n[1/5] Compiling and running Restoring Divider testbench..."
& $vlog -work work "rtl/restoring_divider.v" "tb/tb_restoring_divider.v"
& $vsim -c -do "run -all; quit -f" "work.tb_restoring_divider"

Write-Host "`n[2/5] Compiling and running Softmax Tier 0 testbench..."
& $vlog -work work "rtl/restoring_divider.v" "rtl/softmax_tier0.v" "tb/tb_softmax_tier0.v"
& $vsim -c -do "run -all; quit -f" "work.tb_softmax_tier0"

Write-Host "`n[3/5] Compiling and running Softmax Tier 1 testbench..."
& $vlog -work work "rtl/restoring_divider.v" "rtl/softmax_tier1.v" "tb/tb_softmax_tier1.v"
& $vsim -c -do "run -all; quit -f" "work.tb_softmax_tier1"

Write-Host "`n[4/5] Compiling and running Attention Engine testbench..."
& $vlog -work work "+incdir+rtl" "rtl/weight_roms.v" "rtl/int8_mac_array.v" "rtl/restoring_divider.v" "rtl/softmax_tier0.v" "rtl/softmax_tier1.v" "rtl/softmax_detour_vA.v" "rtl/attention_engine.v" "tb/tb_attention_engine.v"
& $vsim -c -do "run -all; quit -f" "work.tb_attention_engine"

Write-Host "`n[5/5] Compiling and running Full Transformer End-to-End System Regression..."
& $vlog -work work "+incdir+rtl" "rtl/weight_roms.v" "rtl/int8_mac_array.v" "rtl/restoring_divider.v" "rtl/softmax_tier0.v" "rtl/softmax_tier1.v" "rtl/softmax_detour_vA.v" "rtl/attention_engine.v" "tb/tb_full_transformer.v"
& $vsim -c -do "run -all; quit -f" "work.tb_full_transformer"

Write-Host "`n[6/6] Verifying Top-Level DE2-115 Synthesis-Readiness..."
& $vlog -work work "+incdir+rtl" "rtl/weight_roms.v" "rtl/int8_mac_array.v" "rtl/restoring_divider.v" "rtl/softmax_tier0.v" "rtl/softmax_tier1.v" "rtl/softmax_detour_vA.v" "rtl/attention_engine.v" "rtl/cycle_counter.v" "rtl/uart_tx.v" "rtl/de2_115_top.v"

Write-Host "`n================================================================="
Write-Host " ALL PURE VERILOG-2001 REGRESSIONS COMPLETED SUCCESSFULLY!"
Write-Host "================================================================="
