import json
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
MEM_DIR = ROOT / "mem"

with open(MEM_DIR / "model_meta.json", "r", encoding="utf-8") as f:
    meta = json.load(f)

vocab = meta["vocab"]
intents = meta["intents"]

emb = np.loadtxt(MEM_DIR / "embedding.txt", dtype=np.int64).reshape(-1, 32)
wq = np.loadtxt(MEM_DIR / "W_Q.txt", dtype=np.int64).reshape(32, 32)
wk = np.loadtxt(MEM_DIR / "W_K.txt", dtype=np.int64).reshape(32, 32)
wv = np.loadtxt(MEM_DIR / "W_V.txt", dtype=np.int64).reshape(32, 32)

sentences = [
    ("turn on the lights", 0),
    ("turn off the lights", 1),
    ("increase the volume", 2),
    ("decrease the volume", 3),
    ("turn on the heat", 4),
    ("turn off the heat", 5),
]

def tokenize(text):
    words = [w for w in text.lower().split()]
    toks = [vocab.get(w, 1) for w in words[:8]]
    toks += [0] * (8 - len(toks))
    return toks

print("================================================================================")
print("             Q / K / V / H QUANTIZATION SATURATION & FIDELITY AUDIT             ")
print("================================================================================")

all_q_sat = []
all_k_sat = []
all_v_sat = []

for text, exp_intent in sentences:
    toks = tokenize(text)
    e = emb[toks]
    
    q_raw = e @ wq.T
    q_shift = q_raw >> 7
    q_sat = (np.abs(q_shift) > 127).mean() * 100
    all_q_sat.append(q_sat)

    k_raw = e @ wk.T
    k_shift = k_raw >> 7
    k_sat = (np.abs(k_shift) > 127).mean() * 100
    all_k_sat.append(k_sat)

    v_raw = e @ wv.T
    v_shift = v_raw >> 7
    v_sat = (np.abs(v_shift) > 127).mean() * 100
    all_v_sat.append(v_sat)

    print(f"Sentence: \"{text:22s}\" | Q Sat: {q_sat:5.1f}% | K Sat: {k_sat:5.1f}% | V Sat: {v_sat:5.1f}%")

print("-" * 80)
print(f"Average Saturation Across FSC Sentences: Q={np.mean(all_q_sat):.1f}% | K={np.mean(all_k_sat):.1f}% | V={np.mean(all_v_sat):.1f}%")
print("================================================================================\n")
