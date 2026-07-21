<div align="center">

# sckoc

[![license](https://img.shields.io/badge/license-GPL--2.0-blue)](COPYING)
![language](https://img.shields.io/badge/language-Bash%20%2B%20C-orange)
[![stars](https://img.shields.io/github/stars/SkyWalkerAMD/sckoc?logo=github&label=Stars)](https://github.com/SkyWalkerAMD/sckoc/stargazers)
[![downloads](https://img.shields.io/github/downloads/SkyWalkerAMD/sckoc/total?label=downloads&color=brightgreen)](https://github.com/SkyWalkerAMD/sckoc/releases)
[![issues](https://img.shields.io/github/issues/SkyWalkerAMD/sckoc?label=issues&color=yellow)](https://github.com/SkyWalkerAMD/sckoc/issues)

[English](README.en.md) | 中文

</div>

面向 Intel 与 AMD 服务器和工作站的**只读**硬件监控软件。`sckoc` 一条命令给出每 Socket 与每核心两层实时视图，覆盖电压、温度、频率、功耗与 C-state 驻留；`sckoc info` 给出静态平台报告（安全状态、CPU 配置比率、功率墙、内存与缓存）。全程不写入任何 MSR，Secure Boot 与 kernel lockdown (integrity) 下可用。

**当前版本: 4.0.0**

## 设计原则

- **只读架构**：仅经 `/dev/cpu/*/msr` 与 `/dev/hsmp` 读取，不写寄存器、不改系统状态，可用于生产环境
- **诚实输出**：读取失败的字段显示 `N/A` 或隐藏，不输出推测值
- **零侵入安装**：包安装不加载模块、不改系统配置，留给管理员或可选脚本
- **跨平台对称**：Intel 与 AMD 共用一套展示结构，各走平台原生接口

## 支持平台

- **Intel** family 6：Xeon W890/W790 平台、HEDT（X299）及更早支持 MSR 的型号
- **AMD** family 19h/1Ah（Zen3/4/5）：EPYC、Threadripper（EPYC 的 HSMP 内核自带；TR PRO 9000WX 需 DKMS 驱动，安装器自动配置）

## 功能

**`sckoc info`（静态平台报告）**：安全状态（Secure Boot、lockdown、OC Lock）、HT/SMT 与 NUMA、SMU 固件（AMD）；CPU 配置比率上限（base / 最高能效 / 最低）与 0xCE 可编程位；Turbo 比率 bins；热配置（TjMax、TCC/PROCHOT 偏移）；RAPL 功率墙（PL1/PL2 含时间窗与锁）与封装功耗封套；逐 DIMM 内存表（见下节）；缓存拓扑。无 msr 模块时各块独立降级。

**每 Socket**：

- VID 请求电压（Intel `0x198`）；AMD 视主板显示真实双 rail 电压或 P-state 标称值（见 AMD 说明）
- 最热核心温度（对照 TjMax）、包级 PC2/PC6 驻留率、节流标志（THROTTLING / PROCHOT）
- Core 当前频率、Mesh 与 IOD-S/IOD-N 多域 uncore 当前频率（限值与 BIOS 开机值见 `sckoc uncore`）
- 逐核 IRQ 列：采样区间内该核服务的中断数（`/proc/interrupts` 全源求和，SMT 并计兄弟线程）；纯只读、无需驱动
- Mem Max：最热一根 DIMM 的温度（BMC 传感器，取占用槽最高值），与 CPU Temp Max 平行
- DRAM 实际运行速率（SMBIOS）、DRAM 功耗（Intel RAPL）、DDR 带宽利用率（AMD HSMP）
- Pkg 功耗（RAPL）、PPT 功率墙（AMD）、FCLK/MCLK、Fmax/Fmin、CCLK Limit、C0%（AMD）
- 板载电压 Rails（Super I/O 驱动如 nct6775）

**每核心**：有效频率（APERF/MPERF）、温度（Intel 每核 DTS；AMD 按 CCD）、VID 请求电压、C0/C6 驻留率（Intel）、核心功耗（AMD）。SMT/HT 开启时按物理核聚合。距 TjMax 不足 10°C 的行以 `!` 标出（Intel）。

## Intel 平台说明

**VID**：逐核读 `0x198`（IA32_PERF_STATUS）[47:32]，无需额外驱动。此为 VID *请求值*（PCU 向 FIVR 请求的目标），非实测轨电压，未含 load-line 掉压；真实轨遥测在 VR 控制器内，仅可经 BMC/PMBus 获取。固件按核编程时逐核值可不同，包级平台各核同值。

**每核温度**：逐核 DTS，读 per-core MSR `0x19C`（IA32_THERM_STATUS），以 TjMax 为基准，精确到单核。

**Uncore / Mesh 频率**：经 TPMI sysfs 读取，需 `intel-uncore-frequency(-tpmi)` 驱动（内核 5.6+/6.5+，RHEL 9 已回移）；传统 Xeon 无驱动时回退 uncore MSR（`0x620/0x621`）。TPMI 世代 Xeon（Granite Rapids+）配老内核时二者皆不可用，由自带 `tpmi-uncore` 辅助器**只读**解码 TPMI MMIO，数值标注 `(tpmi)`；该路径需 root 且 lockdown=none（Secure Boot 会启用 lockdown 并阻止用户态 mmap PCI BAR；新内核 sysfs 路径不受此限）。

**功率墙**：PL1/PL2 及使能/锁定态来自 RAPL MSR；OC Lock 取自 `0x194`（MSR_FLEX_RATIO）。均显示于 `sckoc info`。

Intel 全部功能仅依赖内核 `msr` 模块与可选的 uncore-frequency 驱动，无 out-of-tree 组件，Secure Boot + lockdown=integrity 下开箱即用。

## AMD 平台说明

**Vcore 与 VID**：AMD 无架构级电压 MSR。默认读数（标注 `VID`）为当前 P-state 的 VID 解码值，即向 VRM 请求的标称电压，非 SVI 遥测。换算：fam 1Ah `V = 0.250 + VID×5mV`，fam 17h SVI2 `V = 1.55 − VID×6.25mV`；fam 19h 混布 Zen3/Zen4 编码，显示 N/A 而不猜测。

fam 1Ah（Zen5）的 P-state VID 为全 socket 单值，不等于双 rail BIOS 设置。已收录主板（目前：**ASUS Pro WS WRX90E-SAGE SE**）改从板载 Super I/O 读取每 rail 实测电压，socket 行直接显示两路真实值；其余主板回退 P-state 标称（标注 `VID`）。SVI 遥测可装 zenpower/ryzen_smu。

**每核温度**：AMD 无每核 DTS，SMU 按 CCD 汇总；per-core 表按核所属 CCD 显示。内核 k10temp 不支持该型号 per-CCD 传感器时（如 fam26/Zen5 sTR5 于内核 6.8），回退 socket 级 Tctl 并以 `*` 标记。

**HSMP**：FCLK/MCLK、PPT、DDR 带宽、C0% 依赖 `/dev/hsmp`。install.sh 在 AMD 平台自动配置：k10temp、内核 `amd_hsmp`，不可用时（TR PRO 9000WX）DKMS 编译 [amd/amd_hsmp](https://github.com/amd/amd_hsmp)（`hsmp_acpi` 模块）并持久化自动加载。Secure Boot 下未签名 DKMS 模块无法加载，安装器会提示禁用 Secure Boot 或注册 MOK 密钥。另需 BIOS 开启 HSMP Support（AMD CBS / NBIO 菜单）。

**消费级 Ryzen / 老内核**：桌面 Ryzen 无 HSMP，老内核 k10temp 不识别新 family。可装第三方 [ryzen_smu](https://github.com/kylon/ryzen_smu)（DKMS）：sckoc 检测到 pm_table 且表版本匹配已验证布局时，**只读**补齐 socket/CCD 温度、FCLK/MCLK、PPT、SMU 固件与 SVI3 电压遥测（`sckoc vid` 显示 VDDCR_CPU/SOC/VDDIO_MEM 等 rail），标注 `(smu)`；版本不匹配维持 `N/A`。已验证：Granite Ridge（Ryzen 9000，表版本 0x620205）。5.18 前内核编译该模块需在其 dkms.conf 追加 `-std=gnu11`。

## 内存显示（Intel 与 AMD 通用）

`sckoc mon` 的 DRAM 行为实际运行速率（SMBIOS Configured Speed）。`sckoc info` 的逐 DIMM 表列：**Speed**（实际运行速率）、**JEDEC**（标称速率）、**VDDQ**（实测轨电压）、**Size**，BMC 有 DIMM 温度传感器时另有 **Temp** 列；无对应传感器的列自动省略。

VDDQ 经 BMC/IPMI（ipmitool）读 DRAM 供电轨传感器（命名 VDDQ 或 VCCD 均可识别）；双内存控制器各一轨时两路并列显示（如 `1.40/1.39 V`）。SMBIOS 的 Configured Voltage 是 JEDEC 标称值（DDR5 恒 1.1 V），不反映 EXPO/XMP 实际设定，故不予显示。装有 ryzen_smu 时 `sckoc vid` 的 `VDDIO_MEM` 亦为内存接口电压来源。

## 安装

**方式一：一键脚本**（任何发行版）

```bash
curl -fsSL https://raw.githubusercontent.com/SkyWalkerAMD/sckoc/main/install.sh | sudo bash
# raw.githubusercontent.com 受限或被限流(HTTP 429)时用 CDN 镜像：
curl -fsSL https://cdn.jsdelivr.net/gh/SkyWalkerAMD/sckoc@main/install.sh | sudo bash
```

自包含：装依赖（gcc、dmidecode、ipmitool）、编译部署、bash 补全、msr 自动加载；AMD 平台自动配置 k10temp/HSMP（含 DKMS）并探测 Super I/O 驱动。重复运行即升级。

**方式二：软件包**（[Releases](https://github.com/SkyWalkerAMD/sckoc/releases) 下载；RPM 与构建它的发行版绑定，按发行版取对应资产）

```bash
# Fedora（示例 fc44，以 Releases 实际文件名为准）
sudo dnf install -y https://github.com/SkyWalkerAMD/sckoc/releases/download/4.0.0/sckoc-4.0.0-1.fc44.x86_64.rpm
# Rocky / Alma / RHEL / CentOS Stream（示例 el8；更推荐方式三 COPR）
sudo dnf install -y https://github.com/SkyWalkerAMD/sckoc/releases/download/4.0.0/sckoc-4.0.0-1.el8.x86_64.rpm
# Ubuntu / Debian
sudo apt install -y https://github.com/SkyWalkerAMD/sckoc/releases/download/4.0.0/sckoc_4.0.0-1_amd64.deb
```

**方式三：软件仓库**（添加一次，之后 `dnf/apt install sckoc` 并自动更新）

```bash
curl -fsSL https://skywalkeramd.github.io/sckoc/apt/setup.sh | sudo bash   # 自动判断发行版
sudo dnf install sckoc    # 或 Debian/Ubuntu: sudo apt install sckoc
```

手动添加：RPM 系 `sudo dnf copr enable skywalkeramd/sckoc`；Debian 系写入 apt 源：

```bash
echo "deb [trusted=yes] https://skywalkeramd.github.io/sckoc/apt stable main" | sudo tee /etc/apt/sources.list.d/sckoc.list
sudo apt update && sudo apt install sckoc
```

自行构建：deb 用 `bash packaging/build-deb.sh`；rpm 用 `spectool -g -R packaging/sckoc.spec && rpmbuild -ba packaging/sckoc.spec`。软件包在 AMD 平台自动探测加载 k10temp/HSMP，但**不执行 DKMS 编译**；需 DKMS 的平台（TR PRO 9000WX）用 install.sh 或手动配置一次。

## 使用

```bash
sudo sckoc                    # 实时监控（默认 mon）
sudo sckoc info               # 静态平台报告
sudo sckoc vid                # 逐核 VID / 逐 rail 电压
sudo sckoc uncore             # uncore/mesh 频率限制 + BIOS 开机值（Intel）
sudo sckoc --json             # JSON 输出（mon 与 uncore 均支持）
sudo sckoc dump 0x198 47:32   # 逐 socket 读任意 MSR 位段
sudo INT=2 sckoc              # 采样窗口 2 秒（默认 1）
sudo watch -n 3 sckoc         # 持续刷新
```

- `mon`（默认）：实时面板；`--json` 输出 schema `sckoc-mon-v1`
- `info`：静态平台报告（安全状态、比率上限、Turbo bins、热配置、RAPL、内存表、缓存）
- `vid`：Intel 逐核 `0x198` VID 请求电压（非实测）；AMD 逐 rail 实测（已收录主板）或 P-state 标称。`vcore` 为弃用别名
- `uncore`：逐 domain 限值与 BIOS 开机值，运行时被改过的限值以 `*` 标出；`--json` 输出 `sckoc-uncore-v1`；sysfs 驱动可用时不依赖 msr 模块
- `dump <reg> [hi:lo]`：逐 socket 读 MSR，可选位段
- `uninstall [-y]`：识别安装方式并完整卸载
- `help` / `version`：用法与版本

Tab 补全覆盖全部子命令与选项（含 `dump` 的常用寄存器与位段）。环境变量：`INT=<秒>` 采样窗口（默认 1）；`DMI=`、`IPMITOOL=` 覆盖对应工具路径。

注：RHEL/Rocky 的 sudo `secure_path` 不含 `/usr/local/bin`，脚本安装后非 root 用户用 `sudo /usr/local/bin/sckoc`；rpm/deb 安装于 `/usr/bin`，无此问题。

## 卸载

```bash
sudo sckoc uninstall          # 交互确认，-y 跳过
```

识别安装方式（脚本 / rpm / deb）并完整清除：程序文件、bash 补全、模块自动加载与软件源配置；install.sh 配置的 DKMS amd_hsmp 一并移除，手动安装的保留并提示清除命令。共享系统包（gcc/dmidecode/dkms 等）保留；已加载内核模块保留至重启。程序损坏时的独立兜底：

```bash
curl -fsSL https://raw.githubusercontent.com/SkyWalkerAMD/sckoc/main/uninstall.sh | sudo bash
```

## 依赖与权限

需 root 与 `msr` 内核模块（安装器已处理）。Mesh/IOD 频率需 `intel-uncore-frequency(-tpmi)` 驱动。AMD FCLK/PPT 等需 `/dev/hsmp`（EPYC 内核自带 `amd_hsmp`，TR PRO 9000WX 用 DKMS `hsmp_acpi`），且 BIOS 需开启 HSMP。AMD 温度需 k10temp，覆盖不到时经 BMC/IPMI 边带读取。BMC 数据（DIMM/CPU 温度、VDDQ）需 ipmitool 且 BMC 应答。电压 Rails 与真实 Vcore 需板载 Super I/O 驱动（安装器自动探测）。除 DKMS 与 TPMI MMIO 降级路径外，全部功能在 Secure Boot + lockdown=integrity 下可用；Secure Boot 下 DKMS 模块需 MOK 签名。

## 项目状态

- **分发渠道**：GitHub Releases（rpm / deb / 源码）、COPR（Fedora / RHEL / EPEL 8-10 / Amazon Linux）、GitHub Pages apt 仓库
- **Fedora 官方仓库**：审核提交进行中
- **多路（2S+）平台**：按多 socket 设计实现，尚未经双路真机验证，欢迎实测反馈

欢迎经 [Issues](https://github.com/SkyWalkerAMD/sckoc/issues) 反馈问题或提交主板 Super I/O 通道映射。

## License

GPL-2.0。全部代码为原创，含监控主程序 `sckoc`、MSR 读取器 `readoc`、AMD HSMP 辅助 `hsmp-msg.c` 及打包与安装脚本。
