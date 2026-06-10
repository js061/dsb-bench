#!/usr/bin/env python3
"""Plot a latency-percentile curve from a wrk2 `-L` benchmark .out file.

wrk2 (DeathStarBench fork) prints, when `-L`/`--latency` is given, a
"Detailed Percentile spectrum" (HdrHistogram CLASSIC) with four columns:

    Value   Percentile   TotalCount   1/(1-Percentile)

Value is in milliseconds. This script extracts the first such block and plots
latency (y) against percentile on a logarithmic 1/(1-p) x-axis — the canonical
HdrHistogram view that makes tail behaviour readable. The p50/p90/p99/p99.9
markers come from the "Latency Distribution (HdrHistogram ...)" summary lines.
"""
import re
import sys
from pathlib import Path

try:
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError as e:
    sys.exit(f"ERROR: missing dependency ({e.name}). Run: python3 -m pip install matplotlib numpy")

# A spectrum data row: Value Percentile TotalCount 1/(1-Percentile)
ROW_RE = re.compile(
    r"^\s*([0-9.]+)\s+([0-9.]+)\s+(\d+)\s+([0-9.]+|inf)\s*$"
)
# Summary line: e.g. " 50.000%    1.23ms"
SUMMARY_RE = re.compile(r"^\s*([0-9.]+)%\s+([0-9.]+)(us|ms|s|m)\b")

UNIT_TO_MS = {"us": 1e-3, "ms": 1.0, "s": 1e3, "m": 60e3}


def parse_spectrum(lines):
    """Return (percentiles, values_ms) from the first Detailed Percentile spectrum."""
    pcts, vals = [], []
    in_block = False
    for line in lines:
        if "Detailed Percentile spectrum" in line:
            in_block = True
            continue
        if not in_block:
            continue
        if line.lstrip().startswith("#"):
            break  # footer (#[Mean = ...]) ends the block
        m = ROW_RE.match(line)
        if m:
            value = float(m.group(1))
            pct = float(m.group(2))
            if pct >= 1.0:
                pct = 1.0 - 1e-9  # avoid div-by-zero at the 100th percentile
            vals.append(value)
            pcts.append(pct)
    return np.array(pcts), np.array(vals)


def parse_summary(lines):
    """Return {percentile_float: latency_ms} from the HdrHistogram summary lines."""
    out = {}
    in_block = False
    for line in lines:
        if "Latency Distribution (HdrHistogram" in line:
            in_block = True
            continue
        if in_block:
            m = SUMMARY_RE.match(line)
            if m:
                out[float(m.group(1))] = float(m.group(2)) * UNIT_TO_MS[m.group(3)]
            elif "Detailed Percentile spectrum" in line:
                break
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: plot-latency.py <wrk2-out-file> <output.png>")

    out_path = Path(sys.argv[1])
    png_path = Path(sys.argv[2])
    if not out_path.is_file():
        sys.exit(f"ERROR: file not found: {out_path}")

    lines = out_path.read_text(errors="replace").splitlines()
    pcts, vals = parse_spectrum(lines)
    if len(vals) == 0:
        sys.exit("ERROR: no 'Detailed Percentile spectrum' found "
                 "(run the benchmark with -L / --latency)")

    summary = parse_summary(lines)
    x = 1.0 / (1.0 - pcts)  # 1 at p0, 10 at p90, 100 at p99, 1000 at p99.9 ...

    fig, ax = plt.subplots(figsize=(12, 6))
    ax.plot(x, vals, linewidth=1.0, color="#1f77b4")
    ax.set_xscale("log")
    ax.set_xlabel("Percentile")
    ax.set_ylabel("Latency (ms)")

    # Label the x ticks as percentiles rather than 1/(1-p) values
    ticks = [1, 10, 100, 1000, 10000, 100000]
    labels = ["0%", "90%", "99%", "99.9%", "99.99%", "99.999%"]
    xmax = x.max()
    keep = [(t, l) for t, l in zip(ticks, labels) if t <= xmax * 1.05]
    if keep:
        ax.set_xticks([t for t, _ in keep])
        ax.set_xticklabels([l for _, l in keep])

    title = f"Latency by percentile — {out_path.name}"
    for p in (99.0, 99.9):
        if p in summary:
            title += f"   p{p:g}={summary[p]:.2f}ms"
    ax.set_title(title)
    ax.grid(True, which="both", alpha=0.3)

    # Annotate key percentile markers from the summary table
    for p in (50.0, 90.0, 99.0, 99.9):
        if p in summary:
            xp = 1.0 / (1.0 - p / 100.0)
            ax.scatter([xp], [summary[p]], color="red", s=20, zorder=5)
            ax.annotate(f"p{p:g}", (xp, summary[p]),
                        textcoords="offset points", xytext=(4, 4), fontsize=8)

    plt.tight_layout()
    plt.savefig(png_path, dpi=100)
    print(f"plot saved to {png_path}")


if __name__ == "__main__":
    main()
