from live_voice_uart_host import VirtualFPGA, ROOT, tokenize_text
vfpga = VirtualFPGA(ROOT / "mem")
tests = [
    ("turn on the lights", 0),
    ("turn off the lights", 1),
    ("increase the volume", 2),
    ("decrease the volume", 3),
    ("turn on the heat", 4),
    ("turn off the heat", 5),
]
print("================================================================================")
print("     WAY 2 LIVE VOICE TOKENIZER & VIRTUAL FPGA END-TO-END ACCELERATOR TEST      ")
print("================================================================================")
for s, exp in tests:
    toks = tokenize_text(s)
    res = vfpga.run_inference(toks, mode=1)
    status = "PASS" if res["intent_id"] == exp else "FAIL"
    print(f"Input: \"{s:22s}\" -> Intent: {res['intent_id']} ({res['intent_name']:16s}) | Total: {res['total_cycles']} cyc ({res['latency_us']:.2f} us) | {status}")
print("================================================================================")
