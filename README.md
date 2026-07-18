# sckoc

> English documentation: [README.en.md](README.en.md)

面向 Intel 与 AMD 服务器和工作站的**只读**硬件监控软件。`sckoc` 一条命令给出每 Socket 与每核心两层实时视图，覆盖电压、温度、频率、功耗与 C-state 驻留；`sckoc info` 给出完整的静态平台报告（安全状态、CPU 配置比率、功率墙、内存与缓存等）。软件采用纯读取设计，全程不写入任何 MSR，因此在 Secure Boot 与 kernel lockdown (integrity) 环境下均可正常工作。

**当前版本: 3.0.0**

## 设计原则

- **只读架构**：仅通过 `/dev/cpu/*/msr` 与 `/dev/hsmp` 读取，从不写入寄存器，不改变系统状态，可安全用于生产环境
- **诚实输出**：任何字段读取失败时显示 `N/A` 或自动隐藏，绝不输出推测或伪造的数值
- **零侵入安装**：包管理器安装时不加载内核模块、不修改系统配置，这些留给管理员或可选的一键脚本
- **跨平台对称**：Intel 与 AMD 采用统一的展示结构，各自读取对应平台的原生接口

## 支持平台

- **Intel** family 6：Xeon W890/W790 平台、HEDT（X299）及更早支持 MSR 的型号
- **AMD** family 19h/1Ah（Zen3/4/5）：EPYC、Threadripper（HSMP 功能 EPYC 内核自带，Threadripper PRO 9000WX 系需 DKMS 驱动，安装器可自动配置，见下）

## 功能

**平台配置（`sckoc info`）**：一份完整的静态平台报告——安全状态（Secure Boot、kernel lockdown、OC Lock）、HT/SMT 与 NUMA 拓扑、SMU 固件（AMD）；CPU 型号与配置比率上限（base / 最高能效 / 最低比率）及 0xCE 可编程位；Turbo 比率限制 bins；热配置（TjMax、TCC/PROCHOT 偏移）；RAPL 功率墙（PL1/PL2 含时间窗与锁）与封装功耗封套（TDP/最小/最大）；逐 DIMM 内存配置；缓存拓扑。监控面板只保留关键实时数据，以上静态项自 2.5.0 起移入 `sckoc info`；无 msr 模块时 MSR 相关块各自降级

**每 Socket**：

- VID 请求电压（Intel `0x198`）；AMD 视主板可显示真实双 rail 电压或 P-state 标称值，详见下方说明
- 最热核心温度（TjMax 对照）、包级 PC2/PC6 驻留率、节流标志（THROTTLING / PROCHOT）
- Core 当前频率（基准频率显示在 CPU 区块），Mesh 与 IOD-S/IOD-N 多域 uncore 当前频率（Min/Max 限值与 BIOS 开机值见 `sckoc uncore`）
- DRAM 频率与电压（SMBIOS）、DRAM 功耗（Intel RAPL）、DDR 带宽利用率（AMD HSMP）
- Pkg 功耗（RAPL）、PPT 功率墙（AMD）、FCLK/MCLK、Fmax/Fmin、CCLK Limit、C0%（AMD）
- 板载电压 Rails（Super I/O 驱动如 nct6775）

**每核心**：有效频率（APERF/MPERF）、温度（Intel 每核 DTS，AMD 按 CCD 显示，见下）、VID 请求电压、C0/C6 驻留率（Intel）、核心功耗（AMD）。SMT/HT 开启时自动按物理核聚合去重。距 TjMax 不足 10°C 的行以 `!` 标出（Intel）

## Intel 平台说明

**VID**：Intel 提供架构级电压 MSR，sckoc 直接从 `0x198`（IA32_PERF_STATUS）的 [47:32] 位段逐核读取，无需任何额外驱动。注意这是 VID *请求值*（PCU 向 FIVR 请求的电压），不是实测轨电压，未含 load-line 掉压；真实轨遥测在 VR 控制器内，只能经 BMC/PMBus 获取。固件按核编程时逐核值可不同，包级平台则各核报同一值。

**每核温度**：Intel 每个核心有独立数字温度传感器（DTS），逐核温度通过 per-core MSR `0x19C`（IA32_THERM_STATUS）读取，以 TjMax 为基准换算，精确到单核。

**Uncore / Mesh 频率**：Mesh 与 IOD-S/IOD-N 多域 uncore 频率通过 TPMI sysfs 接口读取（面板显示当前值，Min/Max 与 BIOS 开机值见 `sckoc uncore`），需要 `intel-uncore-frequency` 或 `intel-uncore-frequency-tpmi` 驱动（内核 5.6+ / 6.5+，RHEL 9 系已回移）。传统 Xeon 在无驱动时回退读取 uncore MSR（`0x620/0x621`）。**TPMI 世代 Xeon（Granite Rapids 及以后）配老内核**（如 CentOS 7.9 的 3.10、el8）：uncore MSR 已废弃（读为 0），内核又没有 TPMI 驱动，此时 sckoc 使用自带的 `tpmi-uncore` 辅助器**只读** mmap OOBMSM 设备的 TPMI MMIO 区域直接解码（字段布局按内核 `intel-uncore-frequency-tpmi` 驱动实现，实测于 Xeon 658X：compute mesh 与 IOD-S/N 三域及 Min/Max 与驱动读数逐一一致），数值以 `(tpmi)` 标注。注意：该路径需要 root 且 lockdown 为 none（Secure Boot 开启会启用 lockdown 并阻止用户态 mmap PCI BAR；有驱动的新内核走 sysfs 不受此限制）。

**功率墙**：PL1/PL2 功率限制及其使能/锁定状态来自 RAPL MSR（显示于 `sckoc info`），包级与 DRAM 功耗同样经 RAPL 读取。OC Lock 状态取自 `0x194`（MSR_FLEX_RATIO，同样显示于 `sckoc info`）。

Intel 平台的全部功能仅依赖内核自带的 `msr` 模块与可选的 uncore-frequency 驱动，无需任何 out-of-tree 组件，在 Secure Boot + lockdown=integrity 下开箱即用。

## AMD 平台说明

**Vcore**：AMD 无架构级电压 MSR。默认读数为当前 P-state 的 VID 解码值，即 CPU 向 VRM 请求的**标称电压**，非 SVI 遥测实测值。换算 fam 1Ah 用 `V = 0.250 + VID×5mV`，fam 17h SVI2 用 `V = 1.55 − VID×6.25mV`，fam 19h 因 Zen3/Zen4 混布不做猜测显示 N/A。

需要注意 fam 1Ah（Zen5）的 P-state VID 是全 socket 单一值，**不等于**双 rail BIOS 设置。对已收录的主板，sckoc 改从板载 Super I/O 读取真实的每 rail 电压。目前已收录 **ASUS Pro WS WRX90E-SAGE SE**（nct6798，`VDDCR_CPU0`=in0、`VDDCR_CPU1`=in6，经 BIOS 电压覆盖增量测试确认），此时 socket 行直接显示两路真实电压。其他主板回退到 P-state 标称值并标注。若需要 SVI 遥测实测，可安装 zenpower/ryzen_smu。

**每核温度**：AMD 无每核 DTS，温度由 SMU 按 CCD 汇总。per-core 表按核所属 CCD 显示温度，CCD 编号经 L3 拓扑步进归一化（fam26 每 CCD 含两 CCX，L3-id 隔号，已修正为连续 0~N）。若内核 k10temp 尚未提供该型号的 per-CCD 传感器（如 fam26/Zen5 sTR5 在内核 6.8），则回退显示 socket 级 Tctl 并以 `*` 标记。

**HSMP 自动配置**：FCLK/MCLK、PPT、DDR 带宽、C0% 等依赖 `/dev/hsmp`。install.sh 在 AMD 平台自动完成：加载 k10temp，尝试内核自带 `amd_hsmp`，不可用时（如 TR PRO 9000WX）自动 DKMS 编译 [amd/amd_hsmp](https://github.com/amd/amd_hsmp)（产出 `hsmp_acpi` 模块），并持久化开机自动加载。**Secure Boot 开启时未签名 DKMS 模块无法加载**，安装器会检测并提示：禁用 Secure Boot，或注册 MOK 密钥后由 DKMS 自动签名（`mokutil --import` 后重启 enroll）。另需 BIOS 开启 HSMP Support（AMD CBS / NBIO 菜单，名称因板而异）。

**消费级 Ryzen / 老内核（ryzen_smu 后备数据源）**：桌面 Ryzen（如 Ryzen 9000）没有 HSMP，FCLK/PPT 无法经 `/dev/hsmp` 获取；较老的内核（如 Ubuntu 22.04 的 5.15）的 k10temp 也不认识新 CPU family，温度同样读不到。此时可安装 out-of-tree 的 [ryzen_smu](https://github.com/kylon/ryzen_smu) 驱动（DKMS），sckoc 检测到 `/sys/kernel/ryzen_smu_drv/pm_table` 且表版本与已验证布局匹配时，自动以**只读**方式从 SMU PM table 补齐 socket/CCD 温度、FCLK/MCLK、PPT、SMU 固件版本与 SVI3 电压遥测（`sckoc vid` 显示 VDDCR_CPU/SOC/VDDIO_MEM 等 rail），相应数值以 `(smu)` 标注；表版本不匹配则维持 `N/A`，绝不猜测。已验证平台：Granite Ridge（Ryzen 9000，表版本 0x620205）。注意：ryzen_smu 为第三方模块，非 sckoc 依赖，需自行安装；**5.18 之前的内核**编译该模块需追加 `-std=gnu11`（内核构建默认 gnu89 会报 `'for' loop initial declarations` 错误），可在其 dkms.conf 的 `CFLAGS_MODULE+=` 处补上。

**DRAM 行的电压说明**：`DRAM ... @ x.x V` 中的电压来自 SMBIOS（dmidecode），为固件填写的 JEDEC 标称值（DDR5 恒为 1.1 V），**不反映 EXPO/XMP 实际设定**；实际内存接口电压见 `sckoc vid` 的 `VDDIO_MEM`（需 ryzen_smu）。

## 安装

**方式一：一键脚本**（任何发行版，克隆仓库或单独下载 install.sh 均可）

```bash
curl -fsSL https://raw.githubusercontent.com/SkyWalkerAMD/sckoc/main/install.sh | sudo bash
# raw.githubusercontent.com 访问受限或被限流(HTTP 429)时，用 CDN 镜像：
curl -fsSL https://cdn.jsdelivr.net/gh/SkyWalkerAMD/sckoc@main/install.sh | sudo bash
```

自包含：自动装依赖（gcc、dmidecode）、编译组件、部署命令与 bash 补全、设置 msr 模块开机加载。AMD 平台额外自动配置 k10temp 与 HSMP（含 DKMS，见上节），并探测板载传感器驱动（nct6775 等）以启用电压 Rails 与真实 Vcore 显示。重复运行即升级，自动清理旧版本。

**方式二：软件包**（从 [Releases](https://github.com/SkyWalkerAMD/sckoc/releases) 下载）

```bash
# Fedora：下载与你的版本匹配的 fcNN 包（示例为 Fedora 44，文件名以 Releases 页实际为准）
sudo dnf install -y https://github.com/SkyWalkerAMD/sckoc/releases/download/3.0.0/sckoc-3.0.0-1.fc44.x86_64.rpm
# Rocky / Alma / RHEL / CentOS Stream：下载对应 elN 包（示例为 EL8）；更推荐方式三的 COPR，自动匹配发行版
sudo dnf install -y https://github.com/SkyWalkerAMD/sckoc/releases/download/3.0.0/sckoc-3.0.0-1.el8.x86_64.rpm
# Ubuntu / Debian
sudo apt install -y https://github.com/SkyWalkerAMD/sckoc/releases/download/3.0.0/sckoc_3.0.0-1_amd64.deb
```

注：RPM 二进制包与构建它的发行版绑定（glibc/依赖不同），fcNN 包装不进 RHEL 系，elN 包也装不进 Fedora，请按发行版取对应资产。

**方式三：软件仓库**（添加一次，之后 `dnf/apt install sckoc` 并自动获得更新）

最简便的方式是用一键 setup 脚本自动配置好软件源，之后即可用标准的 `dnf install` 或 `apt install`：

```bash
curl -fsSL https://skywalkeramd.github.io/sckoc/apt/setup.sh | sudo bash
sudo dnf install sckoc    # 或 Debian/Ubuntu: sudo apt install sckoc
```

setup 脚本会自动判断发行版，RPM 系启用 COPR，Debian 系写好 apt 源。也可以手动添加：

Rocky / CentOS Stream / RHEL（COPR）：

```bash
sudo dnf copr enable skywalkeramd/sckoc && sudo dnf install sckoc
```

Ubuntu / Debian（GitHub Pages apt 仓库）：

```bash
echo "deb [trusted=yes] https://skywalkeramd.github.io/sckoc/apt stable main" | sudo tee /etc/apt/sources.list.d/sckoc.list
sudo apt update && sudo apt install sckoc
```

注：COPR 与 apt 均为第三方仓库，需先添加源再安装，这是发行版的第三方源信任机制，添加一次之后 `dnf/apt install sckoc` 与后续升级即和普通软件一致。自行构建：deb 用 `bash packaging/build-deb.sh`（仓库根目录执行）；rpm 先取源码包再构建：`spectool -g -R packaging/sckoc.spec && rpmbuild -ba packaging/sckoc.spec`（或从 Releases 下载 Source code (tar.gz) 放入 `~/rpmbuild/SOURCES/sckoc-3.0.0.tar.gz`）。软件包安装时在 AMD 平台自动探测加载 k10temp/HSMP 模块，但**不执行 DKMS 编译**，TR PRO 9000WX 等需 DKMS 的平台请用 install.sh 或参照上节手动配置一次。

## 使用

```bash
sudo sckoc                    # 关键实时监控（默认 mon）
sudo sckoc info               # 静态平台报告：CPU/Turbo/热/功率/内存/缓存
sudo sckoc vid                # 逐核 VID / 逐 rail 电压
sudo sckoc uncore             # uncore/mesh 频率限制 + BIOS 开机值（Intel）
sudo sckoc --json             # 机器可读 JSON 输出（mon 与 uncore 均支持 --json）
sudo sckoc dump 0x198 47:32   # 逐 socket 读任意 MSR 位段
sudo sckoc help               # 详细用法与示例
sudo sckoc -V                 # 版本
sudo INT=2 sckoc              # 采样窗口 2 秒（默认 1 秒）
sudo watch -n 3 sckoc         # 持续刷新
```

支持 Tab 补全：子命令（mon/info/vid/uncore/dump/uninstall/help/version）与 `--json`、`dump` 后常用 MSR 寄存器、`uninstall` 后的 `-y` 选项。

各子命令说明：

- `mon`（默认）：关键实时面板（每 Socket 概览 + CPU 区块 + 每核心表）；逐核温度距 TjMax 不足 10°C 的行以 `!` 标出；加 `--json` 输出机器可读 v1（schema `sckoc-mon-v1`，含 socket 与逐核核心字段，不随文本面板瘦身变化）
- `info`：完整静态平台报告（不随负载变、从 mon 面板移出按需查看）——安全状态（Secure Boot / lockdown / OC Lock / HT(SMT) / NUMA / SMU 固件）、CPU 型号与配置比率上限（base / 最高能效 / 最低比率）及 0xCE 可编程位、Turbo 比率限制 bins、热配置（TjMax 与 TCC/PROCHOT 偏移）、RAPL 功率墙（含时间窗与锁）与封装功耗封套（TDP/最小/最大）、逐 DIMM 内存配置、缓存拓扑；MSR 相关块无 msr 模块时各自降级
- `vid`：Intel 显示逐核 `0x198` VID 请求电压（PCU/FIVR 目标值，未含掉压，非实测；固件按核编程时各核可不同，包级平台各核同值），AMD 显示逐 rail 真实电压（已收录主板）或 P-state 标称值。原名 `vcore` 保留为弃用别名
- `uncore`：逐 domain 显示 uncore/mesh 频率限制（仅 Intel）；sysfs 路径下同时显示 BIOS 开机值（`initial_*_freq_khz`），运行时限制被改过会以 `*` 标出；MSR/TPMI 降级路径无开机值概念，该两列显示 `-`；加 `--json` 输出 `sckoc-uncore-v1`；sysfs 驱动可用时本命令不依赖 msr 模块
- `dump <reg> [hi:lo]`：在每个 socket 上读取指定 MSR，可选 `hi:lo` 只取位段，例如 `dump 0x198 47:32`
- `uninstall [-y]`：自动识别安装方式并完整卸载，`-y` 跳过确认
- `help` / `-h`：详细用法、环境变量、示例
- `version` / `-V`：打印版本

环境变量：`INT=<秒>` 设采样窗口（默认 1），`DMI=<路径>` 覆盖 dmidecode 路径。

注：RHEL/Rocky 系 `sudo` 的 `secure_path` 不含 `/usr/local/bin`，脚本方式（install.sh）安装后非 root 用户请用 `sudo /usr/local/bin/sckoc` 或切换 root shell；rpm/deb 安装在 `/usr/bin`，无此问题。

## 卸载

```bash
sudo sckoc uninstall          # 交互确认，加 -y 跳过
```

自动识别安装方式（脚本 / rpm / deb）并完整清除，包括历史版本文件、bash 补全、模块自动加载配置和软件源配置。默认保留 gcc/dmidecode/dkms/git 等系统共享包。由 install.sh 自动配置的 DKMS amd_hsmp 驱动会一并移除（通过标记文件识别），若 amd_hsmp 是你手动安装的则予以保留并提示手动清除命令。已加载的内核模块保留至下次重启（热卸载与并发读取者存在竞态）。软件损坏无法执行时的兜底：

```bash
curl -fsSL https://raw.githubusercontent.com/SkyWalkerAMD/sckoc/main/uninstall.sh | sudo bash
# 镜像：
curl -fsSL https://cdn.jsdelivr.net/gh/SkyWalkerAMD/sckoc@main/uninstall.sh | sudo bash
```

## 依赖与权限

需要 root 与 `msr` 内核模块（安装器已处理；`sckoc uncore` 在 intel-uncore-frequency sysfs 驱动可用时不依赖 msr 模块）。Mesh/IOD 频率需要 `intel-uncore-frequency(-tpmi)` 驱动（内核 5.6+/6.5+，RHEL 9 系已回移）。AMD FCLK/PPT 等需要 `/dev/hsmp`，EPYC 用内核自带 `amd_hsmp`（5.18+），Threadripper PRO 9000WX 用 DKMS `hsmp_acpi`（安装器自动处理），均需 BIOS 开启 HSMP。AMD 温度需 k10temp，电压 Rails 与真实 Vcore 需板载 Super I/O 驱动（nct6775 等，安装器自动探测）。除 DKMS 场景与 TPMI MMIO 降级路径（见 Intel 平台说明）外，全部功能在 Secure Boot + lockdown=integrity 下可用；DKMS 模块在 Secure Boot 下需 MOK 签名。

## 项目状态

- **分发渠道**：GitHub Releases（rpm / deb / 源码）、COPR（Fedora / RHEL / EPEL 8-10 / Amazon Linux）、GitHub Pages apt 仓库
- **Fedora 官方仓库**：审核提交进行中
- **多路（2S+）平台**：代码按多 socket 设计实现，尚未经双路真机验证，欢迎实测反馈

欢迎通过 [Issues](https://github.com/SkyWalkerAMD/sckoc/issues) 反馈问题或提交主板 Super I/O 通道映射，以扩充已收录主板列表。

## License

本项目以 GPL-2.0 许可发布，全部代码均为原创，包括监控主程序 `sckoc`、MSR 读取程序 `readoc`、AMD HSMP 交互 `hsmp-msg.c` 以及打包与安装脚本。
