# msr-sck

Intel/AMD 服务器与工作站的只读硬件监控工具，基于 [intel/msr-tools](https://github.com/intel/msr-tools) 的 `rdmsr` 派生。纯读取设计，兼容 Secure Boot / kernel lockdown (integrity) 环境。

**当前版本: 1.1.3**

## 支持平台

- **Intel** family 6：Xeon W890/W790 平台、HEDT（X299）及更早支持 MSR 的型号
- **AMD** family 19h/1Ah（Zen3/4/5）：EPYC、Threadripper（HSMP 功能 EPYC 内核自带，Threadripper PRO 9000WX 系需 DKMS 驱动，安装器可自动配置，见下）

## 功能

**Platform 概览**：Secure Boot 状态、kernel lockdown 档位、OC Lock（Intel `0x194`）、SMT 开关、NUMA 节点数、SMU 固件版本（AMD）

**每 Socket**：

- Vcore（Intel `0x198` 实测，AMD 视主板可显示真实双 rail 电压或 P-state 标称值，详见下方说明）
- 最热核心温度（TjMax 对照）、包级 PC2/PC6 驻留率、节流标志（THROTTLING / PROCHOT）
- Core 当前/基准频率，Mesh 与 IOD-S/IOD-N 多域 uncore 频率（TPMI sysfs，含 Min/Max）
- DRAM 频率与电压（SMBIOS）、DRAM 功耗（Intel RAPL）、DDR 带宽利用率（AMD HSMP）
- Pkg 功耗（RAPL）、PL1/PL2 功率墙及使能/锁定（Intel）、PPT 功率墙（AMD）、FCLK/MCLK、Fmax/Fmin、CCLK Limit、C0%（AMD）
- 板载电压 Rails（Super I/O 驱动如 nct6775）

**每核心**：有效频率（APERF/MPERF）、温度（Intel 每核 DTS，AMD 按 CCD 显示，见下）、Vcore、C0/C6 驻留率（Intel）、核心功耗（AMD）。SMT 开启时自动按物理核聚合去重

字段读取失败时显示 N/A 或自动隐藏，不输出伪造数值。

## AMD 平台说明

**Vcore**：AMD 无架构级电压 MSR。默认读数为当前 P-state 的 VID 解码值，即 CPU 向 VRM 请求的**标称电压**，非 SVI 遥测实测值。换算 fam 1Ah 用 `V = 0.250 + VID×5mV`，fam 17h SVI2 用 `V = 1.55 − VID×6.25mV`，fam 19h 因 Zen3/Zen4 混布不做猜测显示 N/A。

需要注意 fam 1Ah（Zen5）的 P-state VID 是全 socket 单一值，**不等于**双 rail BIOS 设置。对已收录的主板，msr-sck 改从板载 Super I/O 读取真实的每 rail 电压。目前已收录 **ASUS Pro WS WRX90E-SAGE SE**（nct6798，`VDDCR_CPU0`=in0、`VDDCR_CPU1`=in6，经 BIOS 电压覆盖增量测试确认），此时 socket 行直接显示两路真实电压。其他主板回退到 P-state 标称值并标注。若需要 SVI 遥测实测，可安装 zenpower/ryzen_smu。

**每核温度**：AMD 无每核 DTS，温度由 SMU 按 CCD 汇总。per-core 表按核所属 CCD 显示温度，CCD 编号经 L3 拓扑步进归一化（fam26 每 CCD 含两 CCX，L3-id 隔号，已修正为连续 0~N）。若内核 k10temp 尚未提供该型号的 per-CCD 传感器（如 fam26/Zen5 sTR5 在内核 6.8），则回退显示 socket 级 Tctl 并以 `*` 标记。

**HSMP 自动配置**：FCLK/MCLK、PPT、DDR 带宽、C0% 等依赖 `/dev/hsmp`。install.sh 在 AMD 平台自动完成：加载 k10temp，尝试内核自带 `amd_hsmp`，不可用时（如 TR PRO 9000WX）自动 DKMS 编译 [amd/amd_hsmp](https://github.com/amd/amd_hsmp)（产出 `hsmp_acpi` 模块），并持久化开机自动加载。**Secure Boot 开启时未签名 DKMS 模块无法加载**，安装器会检测并提示：禁用 Secure Boot，或注册 MOK 密钥后由 DKMS 自动签名（`mokutil --import` 后重启 enroll）。另需 BIOS 开启 HSMP Support（AMD CBS / NBIO 菜单，名称因板而异）。

## 安装

**方式一：一键脚本**（任何发行版，克隆仓库或单独下载 install.sh 均可）

```bash
curl -fsSL https://raw.githubusercontent.com/SkyWalkerAMD/msr-sck/main/install.sh | sudo bash
```

自包含：自动装依赖（gcc、dmidecode）、编译组件、部署命令与 bash 补全、设置 msr 模块开机加载。AMD 平台额外自动配置 k10temp 与 HSMP（含 DKMS，见上节），并探测板载传感器驱动（nct6775 等）以启用电压 Rails 与真实 Vcore 显示。重复运行即升级，自动清理旧版本。

**方式二：软件包**（从 [Releases](https://github.com/SkyWalkerAMD/msr-sck/releases) 下载）

```bash
# Rocky/RHEL/Fedora
sudo dnf install -y https://github.com/SkyWalkerAMD/msr-sck/releases/download/1.1.3/msr-sck-1.1.3-1.fc44.x86_64.rpm
# Ubuntu/Debian
sudo apt install -y https://github.com/SkyWalkerAMD/msr-sck/releases/download/1.1.3/msr-sck_1.1.3-1_amd64.deb
```

**方式三：软件仓库**（添加一次，之后 `dnf/apt install msr-sck` 并自动获得更新）

最简便的方式是用一键 setup 脚本自动配置好软件源，之后即可用标准的 `dnf install` 或 `apt install`：

```bash
curl -fsSL https://skywalkeramd.github.io/msr-sck/apt/setup.sh | sudo bash
sudo dnf install msr-sck    # 或 Debian/Ubuntu: sudo apt install msr-sck
```

setup 脚本会自动判断发行版，RPM 系启用 COPR，Debian 系写好 apt 源。也可以手动添加：


Rocky / CentOS Stream / RHEL（COPR）：

```bash
sudo dnf copr enable skywalkeramd/msr-sck && sudo dnf install msr-sck
```

Ubuntu / Debian（GitHub Pages apt 仓库）：

```bash
echo "deb [trusted=yes] https://skywalkeramd.github.io/msr-sck/apt stable main" | sudo tee /etc/apt/sources.list.d/msr-sck.list
sudo apt update && sudo apt install msr-sck
```

注：COPR 与 apt 均为第三方仓库，需先添加源再安装，这是发行版的第三方源信任机制，添加一次之后 `dnf/apt install msr-sck` 与后续升级即和普通软件一致。自行构建软件包用 `rpmbuild -ba packaging/msr-sck.spec` 或 `bash packaging/build-deb.sh`。软件包安装时在 AMD 平台自动探测加载 k10temp/HSMP 模块，但**不执行 DKMS 编译**，TR PRO 9000WX 等需 DKMS 的平台请用 install.sh 或参照上节手动配置一次。

## 使用

```bash
sudo msr-sck                    # 完整监控概览（默认 mon）
sudo msr-sck vcore              # 逐核 / 逐 rail 核心电压
sudo msr-sck dump 0x198 47:32   # 逐 socket 读任意 MSR 位段
sudo msr-sck help               # 详细用法与示例
sudo msr-sck -V                 # 版本
sudo INT=2 msr-sck              # 采样窗口 2 秒（默认 1 秒）
sudo watch -n 3 msr-sck         # 持续刷新
```

支持 Tab 补全：子命令（mon/vcore/dump/uninstall/help/version）、`dump` 后常用 MSR 寄存器、`uninstall` 后的 `-y` 选项。

各子命令说明：

- `mon`（默认）：输出 Platform、每 Socket、每核心三段完整面板
- `vcore`：Intel 显示逐核 `0x198` 实测电压，AMD 显示逐 rail 真实电压（已收录主板）或 P-state 标称值
- `dump <reg> [hi:lo]`：在每个 socket 上读取指定 MSR，可选 `hi:lo` 只取位段，例如 `dump 0x198 47:32`
- `uninstall [-y]`：自动识别安装方式并完整卸载，`-y` 跳过确认
- `help` / `-h`：详细用法、环境变量、示例
- `version` / `-V`：打印版本

环境变量：`INT=<秒>` 设采样窗口（默认 1），`DMI=<路径>` 覆盖 dmidecode 路径。

## 卸载

```bash
sudo msr-sck uninstall          # 交互确认，加 -y 跳过
```

自动识别安装方式（脚本 / rpm / deb）并完整清除，包括历史版本文件、bash 补全、模块自动加载配置和软件源配置。默认保留 gcc/dmidecode/dkms/git 等系统共享包。由 install.sh 自动配置的 DKMS amd_hsmp 驱动会一并移除（通过标记文件识别），若 amd_hsmp 是你手动安装的则予以保留并提示手动清除命令。已加载的内核模块保留至下次重启（热卸载与并发读取者存在竞态）。工具损坏无法执行时的兜底：

```bash
curl -fsSL https://raw.githubusercontent.com/SkyWalkerAMD/msr-sck/main/uninstall.sh | sudo bash
```

## 依赖与权限

需要 root 与 `msr` 内核模块（安装器已处理）。Mesh/IOD 频率需要 `intel-uncore-frequency(-tpmi)` 驱动（内核 5.6+/6.5+，RHEL 9 系已回移）。AMD FCLK/PPT 等需要 `/dev/hsmp`，EPYC 用内核自带 `amd_hsmp`（5.18+），Threadripper PRO 9000WX 用 DKMS `hsmp_acpi`（安装器自动处理），均需 BIOS 开启 HSMP。AMD 温度需 k10temp，电压 Rails 与真实 Vcore 需板载 Super I/O 驱动（nct6775 等，安装器自动探测）。除 DKMS 场景外全部功能在 Secure Boot + lockdown=integrity 下可用，DKMS 模块在 Secure Boot 下需 MOK 签名。

## License

GPL-2.0。`rdmsr.c` 源自 intel/msr-tools（Copyright Transmeta Corp. / H. Peter Anvin），其余组件为本仓库新增。
