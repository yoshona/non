# Mechrevo 笔记本 dGPU 电源控制逆向研究报告

> 适用机型：Mechrevo / Tongfang 清仁（同方）平台
> 目标 GPU：NVIDIA RTX 5070 Ti Laptop GPU (PCI DEV_2F80 / DEV_2F18)
> DSDT 来源：AcpiTbls.rw（完整 DSDT 反编译）

---

## 1. 概述

Mechrevo 的 Control Center（控制中心）通过 GCUService.exe 后台服务控制 dGPU 电源状态。
该服务不直接操作硬件，而是通过 WMI-ACPI 接口调用固件中定义的 ACPI 方法，由 BIOS/UEFI
完成实际的电源切换。

本文档记录了对 DSDT（Differentiated System Description Table）的完整逆向分析结果，
包括 ACPI 调用链、WMI 接口映射、电源资源管理机制，以及 Windows/Linux 下的实现方案。

---

## 2. ACPI 方法调用链

Control Center 控制 dGPU 的完整调用链：

```
GCUService.exe (用户态)
    │
    ├─ Windows: WMI (root\wmi → AcpiTest_MULong)
    │           Invoke-CimMethod → GetSetULong(UInt64 payload)
    │
    ├─ Linux:   /proc/acpi/call (acpi_call 内核模块)
    │           echo '\_SB.PC00.LPCB.EC0.IGPS 0' > /proc/acpi/call
    │
    ▼
AMW0 设备 (ACPI WMI 设备, _HID=PNP0C14, _UID=1)
    │
    ▼
WMBC(Arg0, Arg1=4, Arg2)                    ← DSDT 行 184019
    │  Arg1=4 时: Store(Arg2, AC00) 然后 Return(OEMG(AC00))
    │
    ▼
OEMG(AC00)                                  ← DSDT 行 184060
    │  读取 AC00 缓冲区的 SAC1 字段进行分发
    │  SAC1=0x0300 时进入 GPU 模式控制分支
    │  检查 IGPM==1 后调用 IGPS(SA00)
    │
    ▼
IGPS(Arg0) on \_SB.PC00.LPCB.EC0            ← DSDT 行 185360
    │  嵌入式控制器 (EC0) 上的 GPU 电源状态方法
    │  Arg0=0: dGPU 开启 (Bus Check)
    │  Arg0=1: dGPU 关闭 (Eject)
    │
    ▼
RP09 (PCIe Root Port 9) 及其 PXP 电源资源
    PXP._ON  → dGPU 插槽上电
    PXP._OFF → dGPU 插槽断电
    PXP._STA → 查询电源状态
```

**关键发现：OEMF（SETC 使用的处理函数）不包含 SAC1==0x0300 的分支。
只有 OEMG（GetSetULong 使用的处理函数）才有 GPU 模式控制。** 这意味着必须使用
GetSetULong（Arg1=4）而非 SetULong（Arg1=2）来触发 IGPS。

---

## 3. AC00 数据缓冲区

AC00 是一个 40 字节（0x28）的缓冲区，定义在 DSDT 行 183625，是 WMI-ACPI 通信的核心数据结构：

```
偏移    字段名    类型        说明
────    ──────    ────        ────
0x00    SA00      Byte        子命令 (0=dGPU开, 1=dGPU关, 2=查询)
0x01    SA01      Byte        子参数 1
0x02    SA02      Byte        子参数 2
0x03    SA03      Byte        子参数 3
0x04    SAC0      DWord       数据字段 0
0x04    SAC1      DWord       功能码 (0x0300 = GPU模式控制)
0x08    SAC2      DWord       数据字段 2
0x0C    SAC3      DWord       数据字段 3
0x10    SAC4      DWord       数据字段 4
0x14    SAC5      DWord       数据字段 5
0x18    SAC6      DWord       数据字段 6
0x1C    SAC7      DWord       数据字段 7
0x20    SAC8      DWord       数据字段 8
0x24    SAC9      DWord       数据字段 9
```

注意：SA00 和 SAC0/SAC1 共享偏移 0x00-0x07 的空间。
SA00 是 Byte 字段（offset 0），SAC1 是 DWord 字段（offset 4），它们不重叠。

---

## 4. OEMG 分发表

OEMG（DSDT 行 184060）根据 SAC1 的值进行功能分发：

| SAC1 值  | 功能           | 说明                         |
|----------|---------------|------------------------------|
| 0x0000   | WKBC()        | 通用控制                     |
| 0x0001   | WKBC()        | 通用控制                     |
| 0x0100   | RKBC()        | 键盘背光控制                 |
| 0x0200   | SCMD()        | 系统命令                     |
| **0x0300** | **IGPS()**  | **GPU 模式控制** (需 IGPM==1) |
| 0x0400   | MTJM          | 其他功能                     |
| 0x0500+  | ...           | 其他功能                     |

**SAC1=0x0300 分支详细逻辑**（DSDT 行 184079-184108）：

```
If SAC1 == 0x0300:
    If IGPM == 1:                    ← IGPM 是 GPU 模式标志
        If SA00 == 1:
            Return IGPS(1)           ← dGPU 关闭
        If SA00 == 0:
            Return IGPS(0)           ← dGPU 开启
        If SA00 == 2:
            Return DGPS()            ← 查询 dGPU 电源状态
        If SA00 == 3:
            Return 0x55              ← 未知/未实现
```

IGPM (IGPU Mode) 是一个 ACPI 变量，必须为 1 才能触发 GPU 控制。正常系统状态下 IGPM==1。

---

## 5. WMBC WMI 分发

WMBC（DSDT 行 184019）是 WMI 设备 AMW0 的核心方法分发器。
Windows 通过 WMI 类 `AcpiTest_MULong`（命名空间 `root\wmi`）暴露这些方法：

| WMI 方法      | Arg1 | 内部操作                        | 说明                    |
|--------------|------|---------------------------------|------------------------|
| GetULong     | 1    | GETC(Arg0)                      | 读取 SACx 字段          |
| SetULong     | 2    | SETC(Arg0, Arg2)                | 写入 SACx 字段          |
| FireULong    | 3    | VINS(Arg0) + Store(Arg2, SAC1)  | 设置 SAC1 并触发通知     |
| **GetSetULong** | **4** | **Store(Arg2, AC00) + OEMG(AC00)** | **原子写入+执行，触发 IGPS** |

**关键发现：只有 GetSetULong（Arg1=4）会调用 OEMG。** FireULong（Arg1=3）只设置 SAC1
字段并发通知，不执行 OEMG 分发。SetULong（Arg1=2）调用的是 OEMF 而非 OEMG，
而 OEMF 没有 SAC1=0x0300 分支。

### GetSetULong 的 payload 编码

GetSetULong 接收一个 UInt64 参数，该参数通过 `Store(Arg2, AC00)` 写入 AC00 缓冲区。
由于 AC00 是 40 字节缓冲区，而 UInt64 只有 8 字节，Store 操作只覆盖 AC00 的前 8 字节
（即 SA00..SA03 和 SAC0/SAC1）。

**Payload 编码（小端序）**：

```
UInt64 payload 布局:
  Byte [0]    = SA00 (子命令: 0/1/2)
  Byte [1..3] = SA01, SA02, SA03 (通常为 0)
  Byte [4..7] = SAC1 (功能码，小端 DWord)

计算公式:
  payload = (uint64)SAC1 << 32 | SA00

示例:
  IGPS(0) hybrid: payload = 0x0000030000000000  (SA00=0, SAC1=0x0300)
  IGPS(1) igpu:   payload = 0x0000030000000001  (SA00=1, SAC1=0x0300)
```

---

## 6. IGPS 方法详解

IGPS（DSDT 行 185360）定义在嵌入式控制器 `\._SB.PC00.LPCB.EC0` 上，
使用 `IGMX` 互斥锁保证序列化执行。

### 6.1 IGPS(0) — dGPU 开启（Hybrid 模式）

```
IGPS(0):
    If PXP._STA != 0:              ← 电源已开
        RP09._PS3()                ← 仅调试日志（不做实际操作！）
        IGPU = 0xAA
        Return 0xAA

    Else:                          ← PXP._STA == 0（电源已关）
        IGPU = 0
        Notify(RP09, 0x00)         ← Bus Check: 重新枚举 root port
        Notify(RP09.PXSX, 0x00)    ← Bus Check: 重新枚举子设备 (dGPU)
        Return IGPU (0)
```

### 6.2 IGPS(1) — dGPU 关闭（iGPU Only 模式）

```
IGPS(1):
    If PXP._STA == 0:              ← 电源已关
        Notify(RP09.PXSX, 0x03)    ← Eject Request: 请求移除子设备
        PXSX._PSC = 0              ← 设置电源状态为 D0
        Wait for PXSX._PSC == 0x03 (D3hot)  ← 等待设备进入 D3
            Timeout: 100ms × 100 = 10s
        If 等待成功:
            IGPU = 1               ← 设置 iGPU 模式标志
            Notify(RP09, 0x00)     ← Bus Check
            Return 1
        If 超时:
            IGPU = 2               ← 设置异常标志
            Return 2

    Else:                          ← PXP._STA != 0（电源仍开）
        RP09._PS3()                ← 仅调试日志
        IGPU = 0xAA
        Return 0xAA
```

### 6.3 IGPS 返回值含义

| 返回值 | 含义                                                            |
|--------|-----------------------------------------------------------------|
| 0      | dGPU 已开启（IGPU=0，已发送 Bus Check 通知）                    |
| 1      | dGPU 已关闭（IGPU=1，设备已 eject，已发送 Bus Check）           |
| 2      | 关闭超时（设备未能进入 D3 热状态）                               |
| 0xAA   | PXP 电源状态与请求不匹配：调用 _PS3（仅调试日志），未实际切换    |

**0xAA 的含义**：IGPS 检查 PXP._STA，发现与预期不符，调用了 `_PS3()`。
但 `_PS3()` 在 DSDT 中**只有 ADBG 调试日志输出**，不会真正改变电源状态。
这意味着要成功切换，PXP 的电源状态必须与操作方向一致。

---

## 7. PXP 电源资源

PXP（DSDT 行 29869）是定义在 RP09（PCIe Root Port 9）下的 PowerResource：

```
PowerResource(PXP, 0, 0) {
    Name(_STA, 1)                   ← 初始状态: ON

    Method(_ON) {                   ← 上电
        检查 VDID (Vendor/Device ID)
        检查 IGPU 状态
        若 VEND=0x10DE (NVIDIA):
            调用 PON()             ← GPIO 操作：开启插槽电源
            调用 L23D()            ← 配置 PCIe 链路
            设置 CMDR, D0ST       ← PCI 命令寄存器
            配置 ASPM (LTRE→LREN)
            Store(1, CEDR)        ← 使能时钟
            配置 NVIDIA 特定寄存器 (GFID 依赖)
        若 VEND=0x1002 (AMD):
            类似流程，AMD 特定配置

    Method(_OFF) {                  ← 断电
        检查设备状态
        调用 POFF()                ← GPIO 操作：关闭插槽电源
        设置相关寄存器

    Method(_STA) {                  ← 状态查询
        返回电源状态 (0=OFF, 1=ON)
}
```

### 7.1 关键发现：_PS3 vs PXP._OFF

**直接调用 RP09._PS3() 不会触发 PXP._OFF。** _PS3()（DSDT 行 29863）只包含 ADBG
调试日志，没有实际的电源状态变更。PXP._OFF 只在操作系统电源管理框架主动管理
PowerResource 时被调用。

**Windows 上**：只有 `Disable-PnpDevice`（root port）才会让 Windows PnP 管理器
调用 PXP._OFF，然后 `Enable-PnpDevice` 调用 PXP._ON。

**Linux 上**：内核的 ACPI 电源资源管理在 PCI 设备移除/重新扫描时会自动管理
PXP 的 _ON/_OFF。

---

## 8. Windows 实现方案（gpu-switch.ps1）

### 8.1 WMI-ACPI 调用

Windows 通过 `AcpiTest_MULong` WMI 类（命名空间 `root\wmi`）调用 ACPI 方法：

```powershell
# payload 编码（注意 UInt64 移位）
$funcHi = [uint64]$Function -shl 32    # 必须先转 UInt64！
$payload = [uint64]$SubCommand -bor $funcHi

# 调用 GetSetULong
Invoke-CimMethod -InputObject $inst -MethodName 'GetSetULong' `
    -Arguments @{ $getSetParam = $payload }
```

**PowerShell 陷阱**：`768 -shl 32` 在 Int32 上结果是 768（移位被截断到 0-31 位）。
必须 `[uint64]$Function -shl 32` 先转换类型。

### 8.2 Hybrid 模式（dGPU 开启）— Restore-NvidiaDGpu

```
Step 1: IGPS(0) via WMI
    → 设置 IGPU=0，若 PXP._STA==0 则发送 Notify(RP09, BusCheck)
    → 若 PXP._STA!=0 则返回 0xAA（仅调试）

Step 2: Root Port 电源循环
    → Disable-PnpDevice(root port)  → Windows 调用 PXP._OFF
    → Enable-PnpDevice(root port)   → Windows 调用 PXP._ON  → 硬件上电
    → 这步是关键：确保 PXP 实际执行了电源切换

Step 3: 清除残留设备 + PCIe 重扫描
    → pnputil /remove-device 移除 ghost 设备
    → CM_Reenumerate_DevNode 重枚举 root port

Step 4: 等待 dGPU 出现 + 驱动恢复
    → 检测 Display class NVIDIA 设备
    → 若出现 Code 10：重启 nvlddmkm 驱动服务
```

### 8.3 iGPU Only 模式（dGPU 关闭）— Switch-IGpuOnly

```
Step 1: 禁用 NVIDIA 驱动
    → Disable-PnpDevice(NVIDIA display devices)

Step 2: 禁用 Root Port + IGPS(1)
    → Disable-PnpDevice(root port)  → Windows 调用 PXP._OFF
    → IGPS(1) → Notify(RP09.PXSX, Eject) + Notify(RP09, BusCheck)

Step 3: PCIe 热移除 + 清理残留
    → CM_Request_Device_Eject(NVIDIA PCIe device)
    → pnputil /remove-device 清理
```

### 8.4 Code 10 问题

热插拔 dGPU 后可能出现 Code 10 错误：
*"This device cannot start. The driver trying to start is not the same as the driver
for the POSTed display adapter."*

**原因**：NVIDIA 驱动无法绑定到热插拔后非 POSTed 的显示适配器。
**解决方案**：`Restart-Service nvlddmkm`（重启 NVIDIA 驱动服务）。

---

## 9. Linux 实现方案（gpu_switch.py）

### 9.1 ACPI 方法调用

Linux 通过 `acpi_call` 内核模块提供的 `/proc/acpi/call` 接口直接调用 ACPI 方法，
无需经过 WMI 层：

```python
# 写入方法调用
subprocess.run(["sudo", "tee", "/proc/acpi/call"],
               input="\\_SB.PC00.LPCB.EC0.IGPS 0")

# 读取返回值
result = Path("/proc/acpi/call").read_text()  # 如 "0x0"
```

ACPI 路径优先使用 `\_SB.PC00.LPCB.EC0.IGPS`（与 DSDT 一致），
回退到 `\_SB.PCI0.LPCB.EC0.IGPS`（某些 BIOS 版本使用 PCI0）。

### 9.2 Root Port 检测

通过 sysfs 路径解析自动检测 dGPU 所在的 PCIe Root Port：

```python
# sysfs PCI 设备路径结构：
# /sys/devices/pci0000:00/0000:00:01.0/0000:01:00.0
#                           ^root port      ^dGPU

real = Path(f"/sys/bus/pci/devices/{pci_addr}").resolve()
parent = real.parent  # 即 root port
```

### 9.3 Hybrid 模式（dGPU 开启）

```
Step 1: IGPS(0) via /proc/acpi/call
Step 2: Root Port 电源循环
    → power/control = "off"
    → PCI rescan (内核触发 PXP._ON)
Step 3: 等待 dGPU PCI 设备出现 (lspci / sysfs 检测)
Step 4: modprobe nvidia 加载驱动
```

### 9.4 iGPU Only 模式（dGPU 关闭）

```
Step 1: modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia
Step 2: 禁用 root port + IGPS(1)
    → power/control = "off" (内核触发 PXP._OFF)
    → echo 1 > /sys/bus/pci/devices/{root_port}/remove
    → IGPS(1) via /proc/acpi/call
Step 3: echo 1 > /sys/bus/pci/devices/{dgpu}/remove
```

### 9.5 前置条件

```bash
# 加载 acpi_call 内核模块
sudo modprobe acpi_call

# 永久加载
echo "acpi_call" | sudo tee /etc/modules-load.d/acpi_call.conf
```

---

## 10. 已发现并解决的问题

### 10.1 两步调用破坏 SAC1

**问题**：最初使用 FireULong 设置 SAC1，再调用 GetSetULong 执行 OEMG。
但 GetSetULong 的 `Store(Arg2, AC00)` 会用新的 UInt64 覆盖整个 AC00 前 8 字节，
导致之前 FireULong 设置的 SAC1 被覆盖。

**解决**：改用单次 GetSetULong 调用，在 UInt64 payload 中同时编码 SA00 和 SAC1。

### 10.2 PowerShell Int32 移位溢出

**问题**：`768 -shl 32` 在 PowerShell 中等于 768（Int32 移位截断到 0-31 位），
导致 payload 为 `0x0000000000000300` 而非 `0x0000030000000000`。
OEMG 收到 SAC1=0（因为 SA00=0x300 的低字节）而不是 SAC1=0x0300。

**解决**：`[uint64]$Function -shl 32` 先转换为 UInt64 再移位。

### 10.3 PSCustomObject 返回值解析

**问题**：`Invoke-CimMethod` 返回 PSCustomObject 而非 CimInstance，
导致遍历 CimInstanceProperties 时无法获取返回值。

**解决**：添加 PSCustomObject 分支，检查 `$getResult.PSObject.Properties['Return']`。

### 10.4 直接 _PS3 不调用 PXP._OFF

**问题**：IGPS(0/1) 在 PXP._STA!=0 时只调用 RP09._PS3()，但 _PS3 只有调试日志。
通过 ACPI IOCTL 直接评估 IGPS 不会改变 PXP 的实际电源状态。

**解决**：通过 Windows PnP Disable/Enable-PnpDevice 操作 root port，
由 Windows 电源管理框架调用 PXP._OFF/_ON。

### 10.5 Code 10 热插拔驱动不匹配

**问题**：dGPU 热插拔后，NVIDIA 驱动报告 Code 10。
原因是驱动无法绑定到非 POSTed 的热插拔显示适配器。

**解决**：`Restart-Service nvlddmkm` 重启 NVIDIA 内核驱动。

---

## 11. DSDT 关键位置索引

| 内容               | DSDT 行号 | 说明                              |
|--------------------|----------|-----------------------------------|
| AC00 缓冲区定义    | 183625   | 40 字节 WMI 数据缓冲区             |
| SAC0-SAC9 字段定义 | 183633   | CreateDWordField 偏移 0x00-0x24   |
| SA00-SA03 字段定义 | 183643   | CreateByteField 偏移 0x00-0x03    |
| WMBC 方法          | 184019   | WMI 核心分发器 (Arg1=1/2/3/4)     |
| OEMG 方法          | 184060   | 功能分发表 (含 SAC1=0x0300 GPU)   |
| OEMF 方法          | 184355   | SetULong 处理函数 (无 GPU 分支)   |
| IGPS 方法          | 185360   | GPU 电源控制核心方法               |
| PXP 电源资源       | 29869    | RP09 Root Port 电源资源 _ON/_OFF  |
| _PS3 方法          | 29863    | Root Port D3 状态（仅调试日志）   |

---

## 12. 总结

1. **dGPU 电源控制的核心是 IGPS 方法**，定义在嵌入式控制器 EC0 上
2. **必须通过 GetSetULong（Arg1=4）→ OEMG → IGPS 路径调用**，其他 WMI 方法无法触发
3. **PXP._ON/_OFF 是实际的硬件电源切换操作**，但只有操作系统的电源管理框架会调用它们
4. **在 Windows 上需要配合 PnP 设备禁用/启用 root port** 来触发 PXP 状态切换
5. **在 Linux 上通过 PCI 设备移除/重新扫描让内核管理 PXP 状态**
6. **热插拔后可能需要重启 NVIDIA 驱动**来解决 Code 10 问题
