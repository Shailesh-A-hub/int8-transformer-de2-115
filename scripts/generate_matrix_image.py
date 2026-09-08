import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# 16:9 Aspect Ratio
fig = plt.figure(figsize=(16, 9), facecolor='#080D1A')
ax = fig.add_axes([0, 0, 1, 1], facecolor='#080D1A')
ax.set_xlim(0, 1)
ax.set_ylim(0, 1)
ax.axis('off')

# Colors
BG_DARK = '#080D1A'
CARD_BG = '#0F172A'
BORDER_COLOR = '#1E293B'
CYAN = '#06B6D4'
GREEN = '#10B981'
RED = '#F43F5E'
PURPLE = '#A855F7'
WHITE = '#F8FAFC'
GRAY = '#94A3B8'
LIGHT_GRAY = '#CBD5E1'

# 1. Main Header
ax.text(0.5, 0.950, "INT8 TRANSFORMER ACCELERATOR — KEY METRICS MATRIX",
        ha='center', va='center', fontsize=21, fontweight='bold', color=WHITE, transform=ax.transAxes)
ax.text(0.5, 0.915, "Architectural, Timing, Resource & Numerical Comparison: Conventional Detour vs. Integer-Native Softmax",
        ha='center', va='center', fontsize=11.5, color=CYAN, transform=ax.transAxes)

ax.plot([0.05, 0.95], [0.890, 0.890], color=CYAN, alpha=0.3, lw=1.2, transform=ax.transAxes)

# 2. Top 4 KPI Highlight Cards
kpis = [
    {
        "title": "SOFTMAX CYCLES",
        "value": "1,880 c",
        "sub": "vs 2,008 c in Version A",
        "badge": "-128 c (-6.4%)",
        "badge_color": GREEN,
        "stripe_color": GREEN
    },
    {
        "title": "INFERENCE @ 50MHz",
        "value": "111.20 µs",
        "sub": "5,560 c vs 5,688 c",
        "badge": "2.56 µs Faster",
        "badge_color": GREEN,
        "stripe_color": GREEN
    },
    {
        "title": "EXPONENTIAL ROM",
        "value": "0 Entries",
        "sub": "vs 256 Entries in Vers A",
        "badge": "100% Eliminated",
        "badge_color": CYAN,
        "stripe_color": CYAN
    },
    {
        "title": "NUMERICAL MAE",
        "value": "0.00231",
        "sub": "Tier 1: 0.00025 (410x)",
        "badge": "~44x Lower Error",
        "badge_color": PURPLE,
        "stripe_color": PURPLE
    }
]

card_w = 0.21
gap = 0.02
start_x = 0.05
card_y = 0.775
card_h = 0.095

for i, kpi in enumerate(kpis):
    cx = start_x + i * (card_w + gap)
    
    # Card Box
    rect = plt.Rectangle((cx, card_y), card_w, card_h, facecolor=CARD_BG, edgecolor=BORDER_COLOR, lw=1.2, transform=ax.transAxes, zorder=2)
    ax.add_patch(rect)
    
    # Top indicator stripe
    stripe = plt.Rectangle((cx, card_y + card_h - 0.004), card_w, 0.004, facecolor=kpi["stripe_color"], edgecolor='none', transform=ax.transAxes, zorder=3)
    ax.add_patch(stripe)

    # Title
    ax.text(cx + 0.010, card_y + card_h - 0.020, kpi["title"], fontsize=8.2, fontweight='bold', color=GRAY, transform=ax.transAxes, zorder=3)
    # Badge (right aligned)
    ax.text(cx + card_w - 0.010, card_y + card_h - 0.020, kpi["badge"], fontsize=8.0, fontweight='bold', color=kpi["badge_color"],
            ha='right', transform=ax.transAxes, zorder=3)
            
    # Big Number Value
    ax.text(cx + 0.010, card_y + card_h - 0.053, kpi["value"], fontsize=17, fontweight='bold', color=WHITE, transform=ax.transAxes, zorder=3)
    
    # Subtitle
    ax.text(cx + 0.010, card_y + 0.015, kpi["sub"], fontsize=8.2, color=LIGHT_GRAY, transform=ax.transAxes, zorder=3)

# 3. Key Comparison Matrix Table
headers = [
    "Metric / Parameter", 
    "Version A\n(Conventional Detour)", 
    "Tier 0\n(Shift-Only Base-2)", 
    "Tier 1\n(16-LUT Refinement)", 
    "Architectural Advantage / Improvement"
]

table_data = [
    ["Softmax Latency (Cycles)", "2,008 cycles", "1,880 cycles", "1,880 cycles", "128 cycles saved (6.4% faster)"],
    ["Softmax Latency @ 50 MHz", "40.16 µs", "37.60 µs", "37.60 µs", "2.56 µs faster per inference"],
    ["Total Accelerator Cycles", "5,688 cycles", "5,560 cycles", "5,560 cycles", "128 cycles saved (2.25% faster)"],
    ["Total Latency @ 50 MHz", "113.76 µs", "111.20 µs", "111.20 µs", "Deterministic sub-millisecond edge latency"],
    ["Exponential ROM Footprint", "256 entries (16-bit)", "0 entries (NO ROM!)", "16 entries (16-bit)", "Eliminates ROM memory block entirely in Tier 0"],
    ["Exponentiation Datapath", "256-word ROM lookup", "Pure Barrel Shifter", "16-LUT + Barrel Shift", "Zero ROM, zero DSP in Tier 0 datapath"],
    ["Extra Pipeline Stages", "2 (Descale + Requant)", "0 (Eliminated)", "0 (Eliminated)", "Saves 16 cycles/row across all 8 rows (128c total)"],
    ["Mean Absolute Error (MAE)", "0.100967", "0.002312", "0.000246", "≈ 44x lower (Tier 0) | ≈ 410x lower (Tier 1)"],
    ["Max Absolute Error", "0.401563", "0.009236", "0.000979", "Over 400x peak error reduction (Tier 1)"],
    ["Kullback-Leibler Divergence", "0.532291", "0.016769", "0.014876", "High probability distribution preservation"],
    ["Rank Inversion Rate (1,000 vec)", "0.000%", "0.000%", "0.000%", "Identical winning intent classification to FP32"],
    ["Hardware Verification", "6 / 6 PASS", "6 / 6 PASS", "6 / 6 PASS", "18 / 18 Tests Passed (ModelSim 10.5b)"]
]

col_widths = [0.22, 0.16, 0.17, 0.17, 0.23]
col_x = [start_x]
for w in col_widths[:-1]:
    col_x.append(col_x[-1] + w)

table_start_y = 0.745
hdr_h = 0.040
row_h = 0.036

# Table Header
hdr_rect = plt.Rectangle((start_x, table_start_y - hdr_h), 0.90, hdr_h, facecolor='#1E293B', edgecolor='#334155', lw=1, transform=ax.transAxes, zorder=2)
ax.add_patch(hdr_rect)

for c_idx, h_text in enumerate(headers):
    cx = col_x[c_idx] + 0.01
    color = CYAN if c_idx == 0 else (RED if c_idx == 1 else (GREEN if c_idx in [2, 3] else WHITE))
    ax.text(cx, table_start_y - hdr_h/2, h_text, fontsize=8.8, fontweight='bold', color=color, va='center', transform=ax.transAxes, zorder=3)

# Table Rows
current_y = table_start_y - hdr_h
for r_idx, row in enumerate(table_data):
    current_y -= row_h
    bg_color = '#0F172A' if r_idx % 2 == 0 else '#090E1A'
    r_rect = plt.Rectangle((start_x, current_y), 0.90, row_h, facecolor=bg_color, edgecolor='#1E293B', lw=0.6, transform=ax.transAxes, zorder=2)
    ax.add_patch(r_rect)
    
    for c_idx, val in enumerate(row):
        cx = col_x[c_idx] + 0.01
        
        # Color & Weight
        if c_idx == 0:
            val_color, fw = LIGHT_GRAY, 'bold'
        elif c_idx == 1:
            val_color, fw = '#FDA4AF', 'normal'  # soft red
        elif c_idx == 2:
            val_color, fw = '#6EE7B7', 'bold'    # soft green
        elif c_idx == 3:
            val_color, fw = '#A7F3D0', 'bold'    # mint green
        elif c_idx == 4:
            is_highlight = any(k in val for k in ["faster", "saved", "Eliminates", "lower", "18 / 18"])
            val_color = CYAN if is_highlight else LIGHT_GRAY
            fw = 'bold' if is_highlight else 'normal'
            
        ax.text(cx, current_y + row_h/2, val, fontsize=8.5, fontweight=fw, color=val_color, va='center', transform=ax.transAxes, zorder=3)

# 4. Bottom Conclusion Banner
bot_y = 0.145
bot_h = 0.075
bot_rect = plt.Rectangle((start_x, bot_y), 0.90, bot_h, facecolor='#0B132B', edgecolor=CYAN, lw=1.2, transform=ax.transAxes, zorder=2)
ax.add_patch(bot_rect)

ax.text(start_x + 0.02, bot_y + bot_h/2 + 0.013, "FINAL RESEARCH CONCLUSION:",
        fontsize=10, fontweight='bold', color=CYAN, va='center', transform=ax.transAxes, zorder=3)
ax.text(start_x + 0.02, bot_y + bot_h/2 - 0.015, 
        "• Tier 0 saves 128 clock cycles (2.56 µs) and completely eliminates exponential ROM tables using pure integer shift logic.\n"
        "• Tier 1 further refines accuracy with a tiny 16-entry LUT, achieving over 400x lower MAE (0.000246) and 100% intent agreement.",
        fontsize=9.2, color=WHITE, va='center', transform=ax.transAxes, zorder=3)

# 5. Footer Metadata
ax.text(start_x, 0.065, "Target Platform: Terasic DE2-115 (Intel Cyclone IV EP4CE115F29C7) | Clock: 50.0 MHz | Simulation: ModelSim 10.5b",
        fontsize=8.8, color=GRAY, transform=ax.transAxes)
ax.text(0.95, 0.065, "github.com/Shailesh-A-hub/int8-transformer-de2-115",
        fontsize=8.8, color=CYAN, ha='right', transform=ax.transAxes)

# Save images
out_paths = [
    r"c:\Users\shail\OneDrive\Desktop\Docs\projects final copies\next gen\INT8_Transformer_DE2_115_Implementation\int8_transformer_de2_115\docs\key_metrics_matrix.png",
    r"c:\Users\shail\OneDrive\Desktop\Docs\projects final copies\next gen\key_metrics_matrix.png"
]

for p in out_paths:
    fig.savefig(p, dpi=220, bbox_inches='tight', facecolor=BG_DARK)
    print(f"Saved: {p}")

plt.close(fig)
