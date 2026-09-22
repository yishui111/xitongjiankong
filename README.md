# 系统监控工具

`sysmonitor.py` —— 终端版，实时查看本机系统、内存、显卡及各项占用情况。
`server.py` + `index.html` —— 网页版监控面板，浏览器打开即看。
`inventory.py` —— 按项目列出内存/显卡占用清单（`python inventory.py`）。
`watchdog.ps1` —— 系统守护（垃圾回收），自动清理闲置的测试遗留进程。
`gpu_counters.ps1` —— 服务端调用的按进程显卡计数脚本，勿删。

## 双击使用（推荐）

| 文件 | 作用 |
|------|------|
| **启动监控.bat** | 启动网页监控并打开页面；同时拉起 watchdog 守护循环。若已在运行则只打开页面、不重复启动 |
| **停止监控.bat** | 停止监控服务和 watchdog，并写 `watchdog_disabled.flag` 防止定时巡查重启 |

注意：**不要直接双击 .py 文件启动**——报错时窗口一闪而过看不到原因，且 .py 的打开方式取决于系统文件关联。

bat 文件必须保持 **GBK 编码 + CRLF 换行**：本机 cmd 按 GBK 解析批处理，保存成 UTF-8 会导致
中文行被撕碎、命令报错"不是内部或外部命令"，表现为双击后一闪就退（ 启动监控.bat 曾因被改成
UTF-8 而双击失败，已转回 GBK 修复）。

## 系统守护 / 垃圾回收（watchdog.ps1）

测试完的项目进程经常驻留在内存/显存里不释放，watchdog 充当"系统与显卡管理员"自动回收：

- `启动监控.bat` 会同时拉起网页监控和 watchdog 守护循环（最小化窗口，每 60 秒巡检一次）。
- `停止监控.bat` 两者一起停，并写 `watchdog_disabled.flag` 防止定时巡查自动重启。

清理规则（只针对受监控盘符 **`D:\`、`E:\`、`G:\`**（列表在 watchdog.ps1 的 `$ProjectRoots`，加盘改一行即可）
下的测试遗留进程，即 python/java/node 等解释器进程；
监控工具自身、系统进程、微信/WPS/浏览器/ZCode/Docker/ToDesk 等常用软件绝不清理）：

1. 内存 ≥ 80% 或 显存 ≥ 85% 时，结束"空闲"的测试进程（单核 CPU < 2% 且 GPU < 5%），
   逐个回收到内存 < 82% 为止；**正在干活的进程（占 CPU 或占 GPU）永不动**。
2. 测试进程持续空闲 ≥ 120 分钟，即使不超标也回收（防驻留）。
3. 每次结束动作都写入 `watchdog.log`；最新状态写入 `watchdog_status.json`。

手动单次巡检（打印报告 + 执行同样的清理规则，适合脚本/定时任务调用）：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File watchdog.ps1
```

另有 ZCode 定时任务每 30 分钟自动巡检一次：读取 watchdog 报告排查异常、
必要时人工决策清理，并负责在守护循环意外退出时把它拉起来。

阈值调整：脚本的 param 区（`-MemActPercent` `-VramActPercent` `-IdleKillMinutes` 等）。

## 网页版（推荐）

```bash
python server.py
```

启动后自动打开浏览器访问 http://127.0.0.1:18123（页面每 2 秒自动刷新）。
可选参数：`--port <其他端口>` 换端口、`--no-browser` 不自动开浏览器。

网页版包含：CPU 总占用 + 历史曲线（CPU/内存/显卡三条线）+ 24 核逐核占用、
内存/交换、显卡（使用率/显存/温度/风扇/功耗）、磁盘、网络速率、占用最高的进程。

注意：默认端口 18123（2026-09-10 起，原 18080 与其他项目服务易混淆已弃用）。

## 终端版用法

```bash
# 实时刷新（默认每 2 秒刷新一次，Ctrl+C 退出）
python sysmonitor.py

# 自定义刷新间隔（秒）
python sysmonitor.py --interval 5

# 只输出一次（适合管道 / 定时抓取）
python sysmonitor.py --once
```

## 显示内容

| 板块 | 内容 |
|------|------|
| 系统 | 主机名、Windows 版本、CPU 型号、物理核/逻辑线程数、开机时长 |
| CPU | 总占用率 + 每个逻辑核心占用率（进度条） |
| 内存 | 物理内存、虚拟内存（页面文件）的用量与占比 |
| 显卡 | GPU 型号与驱动、GPU 使用率、显存占用、温度、风扇、功耗（经 nvidia-smi，仅支持 N 卡） |
| 磁盘 | 各本地分区已用/总容量与占比 |
| 网络 | 实时上下行速率、累计收发流量 |
| 进程 | 按 CPU / 按内存排名前 5 的进程 |

## 依赖

```bash
pip install psutil
```

NVIDIA 显卡信息需要已安装显卡驱动（自带 `nvidia-smi`）；非 N 卡时该板块会提示不可用，其余功能正常。
