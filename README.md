# msr-sck

Intel/AMD 服务器与工作站的只读硬件监控工具,基于 [intel/msr-tools](https://github.com/intel/msr-tools) 的 `rdmsr` 派生。纯读取设计,兼容 Secure Boot / kernel lockdown (integrity) 环境。

**当前版本: 1.0.0**

## 支持平台

- **Intel** family 6:Xeon W890/W790 平台、HEDT(X299)及更早支持 MSR 的型号
- **AMD** family 19h/1Ah(Zen3/4/5):EPYC、Threadripper(HSMP 相关功能仅 EPYC 可用)

## 功能

**Platform 概览**:Secure Boot 状态、kernel lockdown 档位、OC Lock(Intel `0x194`)、SMT 开关、NUMA 节点数、SMU 固件版本(AMD)

**每 Socket**:
- Vcore、最热核心温度(TjMax 对照)、包级 PC2/PC6 驻留率、节流标志(THROTTLING / PROCHOT)
- Core 当前/基准频率;Mesh 与 IOD-S/IOD-N 多域 uncore 频率(TPMI sysfs,含 Min/Max)
- DRAM 频率与电压(SMBIOS)、DRAM 功耗(Intel RAPL)、DDR 带宽利用率(AMD HSMP)
- Pkg 功耗(RAPL)、PL1/PL2 功率墙及使能/锁定(Intel)、PPT 功率墙(AMD)、FCLK/MCLK、Fmax/Fmin、CCLK Limit、C0%(AMD)

**每核心**:有效频率(APERF/MPERF)、温度、Vcore、C0/C6 驻留率(Intel)、核心功耗(AMD);SMT 开启时自动按物理核聚合去重

字段读取失败时显示 N/A 或自动隐藏,不输出伪造数值。

## 安装

**方式一:一键脚本**(任何发行版,克隆仓库或单独下载 install.sh 均可)

```bash
curl -fsSL https://raw.githubusercontent.com/SkyWalkerAMD/msr-sck/main/install.sh | sudo bash
```

自包含:自动装依赖(gcc、dmidecode)、编译组件、部署命令与 bash 补全、设置 msr 模块开机加载。重复运行即升级,自动清理旧版本。

**方式二:软件包**(从 [Releases](https://github.com/GITHUB_USER/msr-sck/releases) 下载)

```bash
sudo dnf install ./msr-sck-1.0.0-1.x86_64.rpm      # Rocky/RHEL/Fedora
sudo apt install ./msr-sck_1.0.0-1_amd64.deb        # Ubuntu/Debian
```

**方式三:COPR 仓库**(RHEL 系,真正的 `dnf install msr-sck`)

```bash
sudo dnf copr enable GITHUB_USER/msr-sck
sudo dnf install msr-sck
```

自行构建软件包:`rpmbuild -ba packaging/msr-sck.spec`(需将源码 tar 放入 SOURCES)或 `bash packaging/build-deb.sh`。

## 使用

```bash
sudo msr-sck                    # 完整监控概览(默认 mon)
sudo msr-sck vcore              # 逐核 Vcore(验证每核调压)
sudo msr-sck dump 0x198 47:32   # 逐 socket 读任意 MSR 位段
msr-sck -V                      # 版本
sudo INT=2 msr-sck              # 采样窗口 2 秒(默认 1 秒)
sudo watch -n 3 msr-sck         # 持续刷新
```

支持 Tab 补全(命令名与子命令)。

## 依赖与权限

需要 root 与 `msr` 内核模块(安装器已处理)。Mesh/IOD 频率需要 `intel-uncore-frequency(-tpmi)` 驱动(内核 5.6+/6.5+,RHEL 9 系已回移);AMD FCLK/PPT 等需要内核 `amd_hsmp` 驱动(5.18+)且 BIOS 开启 HSMP。全部功能在 Secure Boot + lockdown=integrity 下可用。

## License

GPL-2.0。`rdmsr.c` 源自 intel/msr-tools(Copyright Transmeta Corp. / H. Peter Anvin),其余组件为本仓库新增。
