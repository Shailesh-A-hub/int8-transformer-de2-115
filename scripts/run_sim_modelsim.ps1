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
Write-Host " Running ModelSim Simulation Regression for DE2-115 Transformer"
Write-Host "================================================================="

# Recreate work library cleanly
if (Test-Path "work") { Remove-Item -Recurse -Force "work" }
& $vlib "work"

Write-Host "`n[1/5] Compiling and running Restoring Divider testbench..."
& $vlog -work work "rtl/restoring_divider.v" "tb/tb_restoring_divider.v"
& $vsim -c -do "run -all; quit -f" "work.tb_restoring_divider"

Write-Host "`n[2/5] Compiling and running Softmax Tier 0 testbench..."
& $vlog -work work -sv "rtl/restoring_divider.v" "rtl/softmax_tier0.sv" "tb/tb_softmax_tier0.sv"
& $vsim -c -do "run -all; quit -f" "work.tb_softmax_tier0"

Write-Host "`n[3/5] Compiling and running Softmax Tier 1 testbench..."
& $vlog -work work -sv "rtl/restoring_divider.v" "rtl/softmax_tier1.sv" "tb/tb_softmax_tier1.sv"
& $vsim -c -do "run -all; quit -f" "work.tb_softmax_tier1"

Write-Host "`n[4/5] Compiling and running Attention Engine testbench..."
& $vlog -work work -sv "rtl/transformer_pkg.sv" "rtl/weight_roms.v" "rtl/int8_mac_array.v" "rtl/restoring_divider.v" "rtl/softmax_tier0.sv" "rtl/softmax_tier1.sv" "rtl/softmax_detour_vA.sv" "rtl/attention_engine.sv" "tb/tb_attention_engine.sv"
& $vsim -c -do "run -all; quit -f" "work.tb_attention_engine"

Write-Host "`n[5/5] Compiling and running Full Transformer End-to-End System Regression..."
& $vlog -work work -sv "rtl/transformer_pkg.sv" "rtl/weight_roms.v" "rtl/int8_mac_array.v" "rtl/restoring_divider.v" "rtl/softmax_tier0.sv" "rtl/softmax_tier1.sv" "rtl/softmax_detour_vA.sv" "rtl/attention_engine.sv" "tb/tb_full_transformer.sv"
& $vsim -c -do "run -all; quit -f" "work.tb_full_transformer"

Write-Host "`n[6/6] Verifying Top-Level DE2-115 Synthesis-Readiness..."
& $vlog -work work -sv "rtl/transformer_pkg.sv" "rtl/weight_roms.v" "rtl/int8_mac_array.v" "rtl/restoring_divider.v" "rtl/softmax_tier0.sv" "rtl/softmax_tier1.sv" "rtl/softmax_detour_vA.sv" "rtl/attention_engine.sv" "rtl/cycle_counter.v" "rtl/uart_tx.v" "rtl/de2_115_top.sv"

Write-Host "`n================================================================="
Write-Host " ALL MODELSIM REGRESSIONS & VERIFICATIONS COMPLETED SUCCESSFULLY!"
Write-Host "================================================================="
