#!/usr/bin/env python3
"""
Small Transformer reference model for a six-intent FSC subset.

This script is intentionally conservative about dataset availability:
it can train on a user-supplied CSV/TSV containing `text,intent`, or generate
a deterministic synthetic smoke-test set so the quantization/export pipeline
can be exercised without pretending synthetic data is FSC.
"""

from __future__ import annotations
import argparse
from pathlib import Path
import re
import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader, TensorDataset

INTENTS = [
    "turn_on_lights",
    "turn_off_lights",
    "increase_volume",
    "decrease_volume",
    "heat_on",
    "heat_off",
]

SYNTHETIC = {
    "turn_on_lights": ["turn on the lights", "switch on lights"],
    "turn_off_lights": ["turn off the lights", "switch off lights"],
    "increase_volume": ["increase the volume", "turn up the volume"],
    "decrease_volume": ["decrease the volume", "turn down the volume"],
    "heat_on": ["turn on the heat", "switch the heating on"],
    "heat_off": ["turn off the heat", "switch the heating off"],
}


def tokenize(s):
    return re.findall(r"[a-z]+", s.lower())


def build_dataset(path=None, repeats=100):
    rows = []
    if path:
        import csv
        with open(path, newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                if r["intent"] in INTENTS:
                    rows.append((r["text"], r["intent"]))
    else:
        for intent, texts in SYNTHETIC.items():
            for _ in range(repeats):
                for t in texts:
                    rows.append((t, intent))
    vocab = {"<pad>": 0, "<unk>": 1}
    for text, _ in rows:
        for tok in tokenize(text):
            vocab.setdefault(tok, len(vocab))
    L = 8
    X = []
    y = []
    for text, intent in rows:
        ids = [vocab.get(t, 1) for t in tokenize(text)[:L]]
        ids += [0] * (L - len(ids))
        X.append(ids)
        y.append(INTENTS.index(intent))
    return np.asarray(X, np.int64), np.asarray(y, np.int64), vocab


class TinyAttention(nn.Module):
    def __init__(self, vocab_size, d=32, ncls=6):
        super().__init__()
        self.emb = nn.Embedding(vocab_size, d)
        self.wq = nn.Linear(d, d, bias=False)
        self.wk = nn.Linear(d, d, bias=False)
        self.wv = nn.Linear(d, d, bias=False)
        self.cls = nn.Linear(d, ncls, bias=False)

    def forward(self, x):
        e = self.emb(x)
        q, k, v = self.wq(e), self.wk(e), self.wv(e)
        s = torch.matmul(q, k.transpose(-2, -1)) / np.sqrt(q.shape[-1])
        a = torch.softmax(s, dim=-1)
        h = torch.matmul(a, v).mean(dim=1)
        return self.cls(h)


def quantize_symmetric(t):
    maxabs = float(t.detach().abs().max())
    scale = max(maxabs / 127.0, 1e-12)
    q = torch.clamp(torch.round(t.detach() / scale), -127, 127).to(torch.int8)
    return q, scale


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=None)
    ap.add_argument("--epochs", type=int, default=20)
    ap.add_argument("--out", default="mem")
    args = ap.parse_args()

    torch.manual_seed(7)
    X, y, vocab = build_dataset(args.data)
    model = TinyAttention(len(vocab))
    opt = torch.optim.Adam(model.parameters(), lr=2e-3)
    loss_fn = nn.CrossEntropyLoss()
    ds = TensorDataset(torch.from_numpy(X), torch.from_numpy(y))
    dl = DataLoader(ds, batch_size=32, shuffle=True)

    model.train()
    for _ in range(args.epochs):
        for xb, yb in dl:
            opt.zero_grad()
            loss = loss_fn(model(xb), yb)
            loss.backward()
            opt.step()

    model.eval()
    with torch.no_grad():
        acc = (model(torch.from_numpy(X)).argmax(1).numpy() == y).mean()
    print(f"Reference accuracy on supplied set: {acc*100:.2f}%")
    if args.data is None:
        print("NOTE: this run used a synthetic smoke-test set, not FSC.")

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    artifacts = {
        "embedding": model.emb.weight,
        "W_Q": model.wq.weight,
        "W_K": model.wk.weight,
        "W_V": model.wv.weight,
        "W_cls": model.cls.weight,
    }
    meta = {"vocab": vocab, "intents": INTENTS, "sequence_length": 8, "d_model": 32}
    (out / "model_meta.json").write_text(json_dumps(meta), encoding="utf-8")
    for name, tensor in artifacts.items():
        q, scale = quantize_symmetric(tensor)
        np.savetxt(out / f"{name}.txt", q.numpy().reshape(-1), fmt="%d")
        (out / f"{name}_scale.txt").write_text(f"{scale:.12g}\n", encoding="utf-8")
    print(f"Exported quantized weights to {out}")


def json_dumps(obj):
    import json
    return json.dumps(obj, indent=2, sort_keys=True)


if __name__ == "__main__":
    main()
