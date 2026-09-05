# -*- coding: utf-8 -*-
"""inventory.py — 按项目/进程列出内存与显卡占用，便于决定关掉谁"""

from server import build_detail_rows


def main():
    rows = build_detail_rows()
    print(f"{'内存':>10} {'显存':>9} {'GPU3D%':>7}  进程 (PID) · 所属项目")
    print("-" * 110)
    for r in rows:
        mem = f"{r['rss'] / 1048576:.0f} MB"
        vram = f"{r['vram']:.0f} MB" if r["vram"] else "-"
        gpu = f"{r['gpu']:.1f}" if r["gpu"] else "-"
        mark = " ←" if (r["vram"] >= 100 or r["gpu"] >= 5 or r["rss"] > 500 * 1048576) else ""
        print(f"{mem:>10} {vram:>9} {gpu:>7}  {r['project']} ({r['pid']}){mark}")
        if r["path"] and r["path"] != r["project"]:
            print(f"{'':>30}└ {r['path']}")
    print("-" * 110)
    print("← = 内存 >500MB / 显存 ≥100MB / GPU ≥5%，重点对象")


if __name__ == "__main__":
    main()
