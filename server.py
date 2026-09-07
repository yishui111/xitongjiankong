# -*- coding: utf-8 -*-
"""server.py — 系统监控网页版

运行: python server.py [--port 18080] [--no-browser]
然后浏览器访问 http://127.0.0.1:18080
"""

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

import psutil

from sysmonitor import cpu_name, fmt_uptime, query_gpu

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

_net_lock = threading.Lock()
_net_prev = None  # (bytes_sent, bytes_recv, ts)

# psutil 的 cpu_percent(interval=None) 按线程 ID 缓存上次采样，
# ThreadingHTTPServer 每请求一个新线程会永远命中不了缓存，因此由
# 这个常驻采样线程统一采样，请求线程只读缓存。
_cpu_cache = {"total": 0.0, "cores": []}
_detail_cache = {"rows": []}


def _cpu_sampler():
    psutil.cpu_percent(interval=None)
    psutil.cpu_percent(interval=None, percpu=True)
    while True:
        time.sleep(1)
        _cpu_cache["total"] = psutil.cpu_percent(interval=None)
        _cpu_cache["cores"] = psutil.cpu_percent(interval=None, percpu=True)


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def gpu_info():
    gpu = query_gpu()
    if not gpu:
        return None

    def g(key):
        v = gpu.get(key, "N/A")
        return None if str(v).upper() == "N/A" else v

    return {
        "name": g("name"),
        "driver": g("driver_version"),
        "util": _num(g("utilization.gpu")),
        "vram_used": _num(g("memory.used")),      # MB
        "vram_total": _num(g("memory.total")),    # MB
        "temp": _num(g("temperature.gpu")),
        "fan": _num(g("fan.speed")),
        "power_draw": _num(g("power.draw")),
        "power_limit": _num(g("power.limit")),
    }


def project_of(name, exe, cmdline):
    """从路径/命令行推断进程所属项目，返回 (简述, 完整路径)"""
    args = cmdline or []
    script_exts = (".py", ".pyw", ".js", ".mjs", ".cjs", ".jar", ".bat", ".cmd")
    path = next((a for a in args if ":\\" in a and a.lower().endswith(script_exts)), "")
    if not path:
        path = next((a for a in args
                     if ":\\" in a and not a.lower().endswith(".exe") and not a.startswith("-")), "")
    if not path:
        path = exe or ""
    m = re.search(r"(?i)\\xm\\([^\\]+)", path)
    label = f"{name} · 项目 {m.group(1)}" if m else name
    return label, path


def build_detail_rows():
    """按进程列出内存、显存、3D 利用率与所属路径，供人工判断关掉谁"""
    vram, eng = {}, {}
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
             "-File", os.path.join(BASE_DIR, "gpu_counters.ps1")],
            capture_output=True, timeout=20, encoding="utf-8", errors="replace",
        )
        for line in out.stdout.splitlines():
            parts = line.strip().split("|")
            if len(parts) != 3:
                continue
            try:
                pid, val = int(parts[1]), float(parts[2])
            except ValueError:
                continue
            if parts[0] == "MEM":
                vram[pid] = val
            elif parts[0] == "ENG":
                eng[pid] = eng.get(pid, 0.0) + val
    except (OSError, subprocess.TimeoutExpired):
        pass

    procs = []
    for p in psutil.process_iter(["pid", "name", "memory_info", "exe", "cmdline"]):
        info = p.info
        if info["pid"] == 0:
            continue
        label, path = project_of(info["name"] or "?", info["exe"], info["cmdline"])
        procs.append({
            "pid": info["pid"],
            "name": info["name"] or "?",
            "rss": info["memory_info"].rss if info["memory_info"] else 0,
            "vram": vram.get(info["pid"], 0.0),
            "gpu": round(min(eng.get(info["pid"], 0.0), 100.0), 1),
            "project": label,
            "path": path,
        })
    procs.sort(key=lambda x: x["rss"], reverse=True)
    rows = procs[:12]
    # 内存不大但正在吃 GPU 的进程也要列出来
    rows += [r for r in procs[12:] if r["vram"] >= 50 or r["gpu"] >= 1.0]
    return rows[:18]


def _detail_sampler():
    while True:
        try:
            _detail_cache["rows"] = build_detail_rows()
        except Exception:
            pass
        time.sleep(4)


def collect():
    now = time.time()
    mem = psutil.virtual_memory()
    swap = psutil.swap_memory()

    disks = []
    for part in psutil.disk_partitions(all=False):
        if "cdrom" in part.opts or not part.fstype:
            continue
        try:
            u = psutil.disk_usage(part.mountpoint)
        except (PermissionError, OSError):
            continue
        disks.append({"mount": part.mountpoint, "used": u.used,
                      "total": u.total, "percent": u.percent})

    procs = []
    for p in psutil.process_iter(["pid", "name", "cpu_percent", "memory_percent", "memory_info"]):
        info = p.info
        procs.append({
            "pid": info["pid"],
            "name": info["name"] or "?",
            "cpu": info["cpu_percent"] or 0.0,
            "rss": info["memory_info"].rss if info["memory_info"] else 0,
            "memp": info["memory_percent"] or 0.0,
        })
    procs = [p for p in procs if p["pid"] != 0]  # 去掉 System Idle Process 这类统计项
    top_cpu = sorted(procs, key=lambda x: x["cpu"], reverse=True)[:8]
    top_mem = sorted(procs, key=lambda x: x["rss"], reverse=True)[:8]

    global _net_prev
    net = psutil.net_io_counters()
    with _net_lock:
        if _net_prev is None:
            sent_ps = recv_ps = 0.0
        else:
            dt = max(now - _net_prev[2], 1e-6)
            sent_ps = max(0.0, (net.bytes_sent - _net_prev[0]) / dt)
            recv_ps = max(0.0, (net.bytes_recv - _net_prev[1]) / dt)
        _net_prev = (net.bytes_sent, net.bytes_recv, now)

    return {
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "host": platform_node(),
        "os": os_name(),
        "cpu_name": cpu_name(),
        "cpu_cores_physical": psutil.cpu_count(logical=False),
        "cpu_cores_logical": psutil.cpu_count(),
        "uptime": fmt_uptime(now - psutil.boot_time()),
        "cpu_percent": _cpu_cache["total"],
        "cpu_per_core": list(_cpu_cache["cores"]),
        "mem": {"used": mem.used, "total": mem.total, "percent": mem.percent},
        "swap": {"used": swap.used, "total": swap.total, "percent": swap.percent},
        "gpu": gpu_info(),
        "disks": disks,
        "net": {"sent_ps": sent_ps, "recv_ps": recv_ps,
                "sent_total": net.bytes_sent, "recv_total": net.bytes_recv},
        "top_cpu": top_cpu,
        "top_mem": top_mem,
        "detail": list(_detail_cache["rows"]),
    }


def platform_node():
    import platform
    return platform.node()


def os_name():
    import platform
    return f"{platform.system()} {platform.release()} ({platform.version()}) {platform.machine()}"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            self._route()
        except (ConnectionAbortedError, ConnectionResetError, BrokenPipeError):
            pass  # 浏览器刷新/关闭导致连接中断，属正常现象，忽略
        except Exception:
            import traceback
            traceback.print_exc(file=sys.stderr)  # 单个请求异常不要无声无息

    def _route(self):
        path = urlparse(self.path).path
        if path == "/api/stats":
            body = json.dumps(collect(), ensure_ascii=False).encode("utf-8")
            self._send(200, body, "application/json; charset=utf-8")
        elif path in ("/", "/index.html"):
            try:
                with open(os.path.join(BASE_DIR, "index.html"), "rb") as f:
                    self._send(200, f.read(), "text/html; charset=utf-8")
            except OSError:
                self._send(500, "index.html 缺失".encode("utf-8"), "text/plain; charset=utf-8")
        else:
            self._send(404, b"not found", "text/plain; charset=utf-8")

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # 静默访问日志
        pass


def main():
    ap = argparse.ArgumentParser(description="系统监控网页版")
    ap.add_argument("--port", type=int, default=18080)
    ap.add_argument("--no-browser", action="store_true", help="启动后不自动打开浏览器")
    args = ap.parse_args()

    threading.Thread(target=_cpu_sampler, daemon=True).start()
    threading.Thread(target=_detail_sampler, daemon=True).start()

    # 预热进程占用率采样，避免首屏全是 0
    for p in psutil.process_iter():
        p.cpu_percent(interval=None)

    url = f"http://127.0.0.1:{args.port}"
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print(f"系统监控已启动: {url}  (Ctrl+C 停止)", flush=True)
    if not args.no_browser:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")


if __name__ == "__main__":
    main()
