# -*- coding: utf-8 -*-
"""sysmonitor.py — 本机系统状态监控（系统 / 内存 / 显卡 / 各项占用）"""

import argparse
import os
import platform
import subprocess
import sys
import time
from datetime import datetime

import psutil

GPU_FIELDS = [
    "name", "driver_version", "utilization.gpu", "memory.used", "memory.total",
    "temperature.gpu", "fan.speed", "power.draw", "power.limit",
]


def fmt_bytes(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def bar(pct, width=22):
    pct = max(0.0, min(100.0, pct))
    filled = round(pct / 100 * width)
    return "█" * filled + "░" * (width - filled)


def query_gpu():
    """通过 nvidia-smi 读取 GPU 状态，不可用时返回 None"""
    try:
        out = subprocess.run(
            ["nvidia-smi", f"--query-gpu={','.join(GPU_FIELDS)}", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode != 0:
            return None
        vals = [v.strip() for v in out.stdout.strip().splitlines()[0].split(",")]
        return dict(zip(GPU_FIELDS, vals))
    except (OSError, subprocess.TimeoutExpired, IndexError):
        return None


def cpu_name():
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                            r"HARDWARE\DESCRIPTION\System\CentralProcessor\0") as key:
            return winreg.QueryValueEx(key, "ProcessorNameString")[0].strip()
    except OSError:
        return platform.processor() or os.environ.get("PROCESSOR_IDENTIFIER", "未知")


def fmt_uptime(seconds):
    seconds = int(seconds)
    days, seconds = divmod(seconds, 86400)
    hours, seconds = divmod(seconds, 3600)
    minutes = seconds // 60
    if days:
        return f"{days} 天 {hours} 小时 {minutes} 分"
    return f"{hours} 小时 {minutes} 分"


def render(net_delta=None, interval=2):
    lines = []
    boot = psutil.boot_time()
    now = datetime.now()

    lines.append("═" * 21 + " 本机系统状态监控 " + "═" * 21)
    lines.append(f" 刷新时间 {now:%Y-%m-%d %H:%M:%S}    本次开机已运行 {fmt_uptime(now.timestamp() - boot)}")
    lines.append("")

    # ---- 系统 ----
    host = platform.node()
    win = platform.system() + " " + platform.release()
    lines.append("【系统】")
    lines.append(f"  主机名   {host}")
    lines.append(f"  系统     {win} ({platform.version()}) {platform.machine()}")
    lines.append(f"  CPU      {cpu_name()}")
    lines.append(f"  核心     物理 {psutil.cpu_count(logical=False)} 核 / 逻辑 {psutil.cpu_count()} 线程")
    lines.append("")

    # ---- CPU ----
    cpu_pct = psutil.cpu_percent(interval=None)
    lines.append(f"【CPU 占用】 {cpu_pct:5.1f} %  {bar(cpu_pct)}")
    per_core = psutil.cpu_percent(interval=None, percpu=True)
    row = []
    for i, p in enumerate(per_core):
        row.append(f"核{i:>2} {p:5.1f}% {bar(p, 10)}")
        if len(row) == 2:
            lines.append("  " + "   ".join(row))
            row = []
    if row:
        lines.append("  " + "   ".join(row))
    lines.append("")

    # ---- 内存 ----
    mem = psutil.virtual_memory()
    swap = psutil.swap_memory()
    lines.append("【内存】")
    lines.append(f"  物理  {fmt_bytes(mem.used)} / {fmt_bytes(mem.total)} ({mem.percent:4.1f}%)  {bar(mem.percent)}")
    lines.append(f"  交换  {fmt_bytes(swap.used)} / {fmt_bytes(swap.total)} ({swap.percent:4.1f}%)  {bar(swap.percent)}")
    lines.append("")

    # ---- 显卡 ----
    gpu = query_gpu()
    lines.append("【显卡】")
    if gpu:
        def g(key):
            v = gpu.get(key, "N/A")
            return "--" if v.upper() == "N/A" else v
        lines.append(f"  型号     {g('name')}（驱动 {g('driver_version')}）")
        gpu_util = float(g("utilization.gpu"))
        vram_used, vram_total = float(g("memory.used")), float(g("memory.total"))
        vram_pct = vram_used / vram_total * 100 if vram_total else 0
        lines.append(f"  使用率   {gpu_util:5.1f} %  {bar(gpu_util)}")
        lines.append(f"  显存     {vram_used / 1024:5.1f} / {vram_total / 1024:.1f} GB ({vram_pct:4.1f}%)  {bar(vram_pct)}")
        lines.append(f"  温度     {g('temperature.gpu')} °C    风扇 {g('fan.speed')} %    功耗 {g('power.draw')} / {g('power.limit')} W")
    else:
        lines.append("  未检测到 nvidia-smi（非 N 卡或驱动未安装），GPU 信息不可用")
    lines.append("")

    # ---- 磁盘 ----
    lines.append("【磁盘】")
    for part in psutil.disk_partitions(all=False):
        if "cdrom" in part.opts or not part.fstype:
            continue
        try:
            usage = psutil.disk_usage(part.mountpoint)
        except (PermissionError, OSError):
            continue
        lines.append(f"  {part.mountpoint:<4} {fmt_bytes(usage.used):>10} / {fmt_bytes(usage.total):<10} "
                     f"({usage.percent:4.1f}%)  {bar(usage.percent)}")
    lines.append("")

    # ---- 网络 ----
    net = psutil.net_io_counters()
    lines.append("【网络】")
    if net_delta is not None:
        sent_ps = (net.bytes_sent - net_delta[0]) / interval
        recv_ps = (net.bytes_recv - net_delta[1]) / interval
        lines.append(f"  速率  ↓ {fmt_bytes(recv_ps)}/s    ↑ {fmt_bytes(sent_ps)}/s")
    lines.append(f"  累计  ↓ {fmt_bytes(net.bytes_recv)}    ↑ {fmt_bytes(net.bytes_sent)}")
    lines.append("")

    # ---- 进程 ----
    procs = []
    for p in psutil.process_iter(["pid", "name", "cpu_percent", "memory_percent", "memory_info"]):
        info = p.info
        procs.append((info["pid"], info["name"] or "?",
                      info["cpu_percent"] or 0.0,
                      info["memory_percent"] or 0.0,
                      info["memory_info"].rss if info["memory_info"] else 0))
    procs = [p for p in procs if p[0] != 0]  # 去掉 System Idle Process 这类内核统计项
    lines.append("【占用最高的进程】")
    top_cpu = sorted(procs, key=lambda x: x[2], reverse=True)[:5]
    top_mem = sorted(procs, key=lambda x: x[4], reverse=True)[:5]
    lines.append("  CPU   " + " | ".join(f"{n}({pid}) {c:4.1f}%" for pid, n, c, _, _ in top_cpu))
    lines.append("  内存  " + " | ".join(f"{n}({pid}) {fmt_bytes(r)}" for pid, n, _, _, r in top_mem))

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="本机系统状态监控")
    parser.add_argument("--once", action="store_true", help="只输出一次后退出")
    parser.add_argument("--interval", type=float, default=2.0, help="实时模式刷新间隔秒数（默认 2）")
    args = parser.parse_args()

    if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
        sys.stdout.reconfigure(encoding="utf-8")

    # 预热采样：让 CPU / 进程占用率有可比较的两次采样
    psutil.cpu_percent(interval=None, percpu=True)
    primed = [p.cpu_percent(interval=None) for p in psutil.process_iter()]

    if args.once:
        time.sleep(1.0)
        print(render(None, args.interval))
        return

    net_prev = (psutil.net_io_counters().bytes_sent, psutil.net_io_counters().bytes_recv)
    while True:
        os.system("cls" if os.name == "nt" else "clear")
        print(render(net_prev, args.interval))
        print("\n 按 Ctrl+C 退出")
        time.sleep(args.interval)
        net_prev = (psutil.net_io_counters().bytes_sent, psutil.net_io_counters().bytes_recv)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n已退出。")
