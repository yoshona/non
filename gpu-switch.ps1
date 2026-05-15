# gpu-switch.ps1 — Mechrevo GPU Mode Switcher for Windows
#
# Uses ACPI IGPS method on Embedded Controller (EC0) for GPU power control,
# matching the Control Center backend. Falls back to PCIe hot-plug if ACPI fails.
#
# ACPI call chain (from DSDT analysis):
#   IGPS(0) → Notify(RP09, BusCheck) + Notify(RP09.PXSX, BusCheck) → dGPU power on
#   IGPS(1) → Notify(RP09.PXSX, Eject) → dGPU power off
#
# Called through:
#   AMW0 (WMI device) → WMBC(Arg1=4) → OEMG → IGPS on \_SB.PC00.LPCB.EC0
#
# Usage:
#   .\gpu-switch.ps1 status          Show current GPU mode
#   .\gpu-switch.sh igpu            Switch to iGPU Only (eject dGPU from PCIe)
#   .\gpu-switch.ps1 dgpu            Switch to dGPU Only (dGPU primary, needs restart)
#   .\gpu-switch.ps1 hybrid          Switch to Hybrid (rescan dGPU onto PCIe)
#
# Requires: Administrator

param(
    [Parameter(Position=0)]
    [ValidateSet("status", "igpu", "dgpu", "hybrid", "diagnose")]
    [string]$Command = "status",

    [switch]$Force,
    [switch]$DryRun,
    [switch]$Fallback  # Use PnP disable instead of WMI ACPI
)

# --- Helpers ---

function Write-Info($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-OK($msg)    { Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Warn($msg)  { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)   { Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NvidiaDisplayDevices {
    return @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -ErrorAction SilentlyContinue)
}

# --- WMI ACPI Interface ---
#
# The Control Center backend (GCUService.exe) calls WMI methods on the AMW0
# ACPI WMI device (_HID=PNP0C14, _UID=1) to control GPU modes.
#
# Call chain discovered from DSDT reverse engineering:
#   WMIEC.WMIWriteECIGPUonlyON()
#     → WMIEC.GetSetULong2(0x0300, ...) or Smrw(...)
#       → WMI method on AMW0 → WMBC(Arg1=4)
#         → OEMG(AC00) where AC00 buffer has:
#             dword[0] = SA00 (sub-command: 0=igpu_off, 1=igpu_on, 2=query)
#             dword[4] = SAC1 (function: 0x0300 = iGPU mode control)
#           OEMG dispatches to:
#             IGPS(1) — PCIe Eject dGPU (power off completely)
#             IGPS(0) — PCIe Bus Check (rescan + re-enable dGPU)
#             DGPS()  — Query dGPU power status

# P/Invoke for cfgmgr32 (PCIe eject/rescan)
if (-not ([System.Management.Automation.PSTypeName]'GpuSwitchApi').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class GpuSwitchApi {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr CreateFile(
        string lpFileName, int dwDesiredAccess, int dwShareMode,
        IntPtr lpSecurityAttributes, int dwCreationDisposition,
        int dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(
        IntPtr hDevice, int dwIoControlCode,
        byte[] lpInBuffer, int nInBufferSize,
        byte[] lpOutBuffer, int nOutBufferSize,
        out int lpBytesReturned, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    // CfgMgr32 — proper PCIe hot-eject without needing Control Center
    [DllImport("cfgmgr32.dll", SetLastError = false, CharSet = CharSet.Unicode)]
    public static extern int CM_Locate_DevNodeW(out int pdnDevInst, string pDeviceID, int ulFlags);

    [DllImport("cfgmgr32.dll", SetLastError = false, CharSet = CharSet.Unicode)]
    public static extern int CM_Request_Device_Eject(int dnDevInst, out int pVetoType,
        StringBuilder pszVetoName, int ulNameLength, int ulFlags);

    [DllImport("cfgmgr32.dll", SetLastError = false, CharSet = CharSet.Unicode)]
    public static extern int CM_Get_Parent(out int pdnDevInst, int dnDevInst, int ulFlags);

    [DllImport("cfgmgr32.dll", SetLastError = false, CharSet = CharSet.Unicode)]
    public static extern int CM_Get_Device_IDW(int dnDevInst, StringBuilder pszBuffer, int ulBufferLen, int ulFlags);

    [DllImport("cfgmgr32.dll", SetLastError = false, CharSet = CharSet.Unicode)]
    public static extern int CM_Reenumerate_DevNode(int dnDevInst, int ulFlags);
}
"@ -Language CSharp
}

# --- PCIe Hot-Eject via CfgMgr32 API ---
#
# Uses CM_Request_Device_Eject to perform a proper PCIe hot-remove of the dGPU.
# This is the same mechanism Windows uses when ACPI sends Notify(0x03) Eject Request.
# No Control Center dependency — works with just the Windows PnP/PCIe subsystem.
#
# Equivalent to Linux: echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove

function Find-NvidiaPciDeviceId {
    # Find the NVIDIA GPU PCIe device instance ID
    # Search by display class first, then by hardware ID
    $devs = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -ErrorAction SilentlyContinue)
    if ($devs.Count -eq 0) {
        $devs = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -match 'VEN_10DE' })
    }
    if ($devs.Count -eq 0) {
        return $null
    }

    # Use the first NVIDIA device — all functions share the same PCIe parent
    $dev = $devs[0]
    Write-Info "Found NVIDIA device: $($dev.InstanceId)"

    # Get the parent PCIe device (VEN_10DE) — this is what we need to eject
    # For single-function GPUs, the display adapter IS the PCIe device
    # For multi-function GPUs, we need to walk up to the parent
    $parentId = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId `
        -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data

    if ($parentId -and $parentId -match 'VEN_10DE') {
        # Parent is also NVIDIA — we're a child function, eject the parent
        Write-Info "Parent PCIe device: $parentId"
        return $parentId
    }

    # The display adapter itself is the PCIe device (common case)
    if ($dev.InstanceId -match 'VEN_10DE') {
        return $dev.InstanceId
    }

    # Last resort: try the parent anyway
    if ($parentId) {
        Write-Info "Using parent device: $parentId"
        return $parentId
    }

    return $dev.InstanceId
}

function Find-NvidiaRootPort {
    # Find the PCIe root port that the NVIDIA GPU sits behind
    $gpuId = Find-NvidiaPciDeviceId
    if ($gpuId) {
        # Walk up the device tree: GPU → PCIe bridge (if any) → Root Port
        $currentId = $gpuId
        for ($i = 0; $i -lt 5; $i++) {
            $parentId = (Get-PnpDeviceProperty -InstanceId $currentId `
                -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
            if (-not $parentId) { break }

            if ($parentId -match 'VEN_(8086|1022)') {
                Write-Info "Root port: $parentId"
                return $parentId
            }
            $currentId = $parentId
        }
    }

    # Fallback: find Intel/AMD PCIe root port that was recently disabled
    # (likely the one the GPU was connected to)
    $disabledPorts = @(Get-PnpDevice -Class 'System' -Status Error -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'VEN_(8086|1022).*DEV_' } |
        Where-Object { $_.FriendlyName -match 'Port|Bridge|Root' })
    if ($disabledPorts.Count -gt 0) {
        Write-Info "Found disabled root port: $($disabledPorts[0].InstanceId)"
        return $disabledPorts[0].InstanceId
    }

    return $null
}

function Invoke-PcieDeviceEject {
    param(
        [Parameter(Mandatory)]
        [string]$DeviceInstanceId
    )

    $devInst = 0
    $cr = [GpuSwitchApi]::CM_Locate_DevNodeW([ref]$devInst, $DeviceInstanceId, 0)
    if ($cr -ne 0) {
        Write-Err "CM_Locate_DevNode failed (CR=$cr) for $DeviceInstanceId"
        return $false
    }

    $vetoType = 0
    $vetoName = New-Object System.Text.StringBuilder(512)
    $cr = [GpuSwitchApi]::CM_Request_Device_Eject($devInst, [ref]$vetoType, $vetoName, 512, 0)

    # CR_SUCCESS = 0
    if ($cr -eq 0 -and $vetoType -eq 0) {
        return $true
    }

    if ($cr -eq 0 -and $vetoType -ne 0) {
        Write-Warn "Eject vetoed (type=$vetoType, reason=$($vetoName.ToString()))"
        return $false
    }

    # CR_CALL_NOT_IMPLEMENTED = 20 — device doesn't support eject
    # CR_NO_SUCH_DEVNODE = 13
    Write-Err "CM_Request_Device_Eject failed (CR=$cr, vetoType=$vetoType)"
    return $false
}

function Invoke-PcieRescan {
    # Rescan PCIe bus to bring back the dGPU
    # Uses CM_Reenumerate_DevNode on the root port to trigger ACPI _PS0 power-on

    # Method 1: CM_Reenumerate_DevNode on root port (triggers ACPI power-on)
    $rootPortId = Find-NvidiaRootPort
    if ($rootPortId) {
        $devInst = 0
        $cr = [GpuSwitchApi]::CM_Locate_DevNodeW([ref]$devInst, $rootPortId, 0)
        if ($cr -eq 0) {
            Write-Info "Re-enumerating root port (ACPI _PS0)..."
            $cr = [GpuSwitchApi]::CM_Reenumerate_DevNode($devInst, 0)
            if ($cr -eq 0) {
                Write-OK "Root port re-enumerated"
                return $true
            }
            Write-Warn "CM_Reenumerate_DevNode failed (CR=$cr)"
        }
        else {
            Write-Warn "CM_Locate_DevNode failed for root port (CR=$cr)"
        }
    }

    # Method 2: pnputil /scan-devices
    try {
        Write-Info "Running pnputil /scan-devices..."
        $output = pnputil /scan-devices 2>&1
        Write-Info "pnputil: $output"
        return $true
    }
    catch {
        Write-Warn "pnputil failed: $($_.Exception.Message)"
    }

    return $false
}

# --- ACPI IGPS Method Evaluation ---
#
# The DSDT defines IGPS on \_SB.PC00.LPCB.EC0 (Embedded Controller):
#   IGPS(0) — Bus Check: sends Notify(RP09, 0) + Notify(RP09.PXSX, 0)
#             to power on the dGPU and re-enumerate the PCIe slot
#   IGPS(1) — Eject: powers off the dGPU slot
#
# Access path: AMW0 (PNP0C14 WMI device) → WMBC(Arg1=4) → OEMG → IGPS
# The OEMG dispatch table uses AC00 buffer: SA00=sub-command, SAC1=0x0300=function

function Invoke-AcpiIgps {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(0, 1)]
        [int]$Mode
    )

    $modeName = switch ($Mode) { 0 { 'Bus Check (re-enable)' } 1 { 'Eject (power off)' } }
    Write-Info "Calling ACPI IGPS($Mode) — $modeName..."

    # Method 1: WMI-ACPI method invocation through AMW0 device
    $wmiResult = Invoke-WmiAcpiGpuMode -SubCommand $Mode -Function 0x0300
    if ($wmiResult) {
        Write-OK "WMI-ACPI call succeeded"
        return $true
    }

    # Method 2: Direct ACPI IOCTL on EC0 device
    $ioctlResult = Invoke-AcpiIgpsIoctl -Mode $Mode
    if ($ioctlResult) {
        return $true
    }

    Write-Warn "All ACPI method approaches failed"
    return $false
}

function Invoke-WmiAcpiGpuMode {
    param([int]$SubCommand, [int]$Function)

    # WMI-ACPI GPU mode control through AMW0 device's AcpiTest_MULong class.
    #
    # DSDT analysis:
    #   AC00 = 40-byte buffer with sub-fields:
    #     SA00 (byte 0)  = sub-command (0=dGPU on, 1=dGPU off, 2=query)
    #     SAC1 (dword 4) = function code (0x0300 = GPU mode control)
    #   OEMG dispatches: SAC1==0x0300 && IGPM==1 → IGPS(SA00)
    #
    # WMI methods → WMBC dispatch:
    #   GetULong     → Arg1=1 (GETC): read SACx fields
    #   SetULong     → Arg1=2 (SETC): write SACx fields
    #   FireULong    → Arg1=3: Store(Arg2, SAC1) + Notify (sets SAC1 only)
    #   GetSetULong  → Arg1=4: Store(Arg2, AC00) + OEMG(AC00) → triggers IGPS
    #
    # Key: GetSetULong does Store(UInt64, AC00) which writes into the EXISTING
    # 40-byte buffer (ACPICA behavior). We encode both SA00 and SAC1 in one
    # UInt64 to set everything atomically before OEMG dispatch.

    try {
        $className = 'AcpiTest_MULong'
        $class = Get-CimClass -Namespace root\wmi -ClassName $className -ErrorAction SilentlyContinue
        if (-not $class) {
            Write-Warn "$className WMI class not found"
            return $false
        }

        $instances = @(Get-CimInstance -Namespace root\wmi -ClassName $className -ErrorAction SilentlyContinue)
        if ($instances.Count -eq 0) {
            Write-Warn "No instances of $className found"
            return $false
        }

        # Get method parameter names
        $getMethod = $class.CimClassMethods | Where-Object { $_.Name -eq 'GetULong' } | Select-Object -First 1
        $getSetMethod = $class.CimClassMethods | Where-Object { $_.Name -eq 'GetSetULong' } | Select-Object -First 1
        $getParam = ($getMethod.Parameters | Select-Object -First 1).Name
        $getSetParam = ($getSetMethod.Parameters | Where-Object { $_.Name -eq 'Data' } | Select-Object -First 1).Name
        if (-not $getSetParam) { $getSetParam = ($getSetMethod.Parameters | Select-Object -First 1).Name }

        $inst = $instances[0]

        # Diagnostic: read current SAC1 value (instance 1 = GETC(1) → SAC1)
        if ($instances.Count -gt 1) {
            try {
                $readResult = Invoke-CimMethod -InputObject $instances[1] -MethodName 'GetULong' -Arguments @{ $getParam = [uint32]0 } -ErrorAction SilentlyContinue
                $sac1Before = $null
                if ($readResult -is [Microsoft.Management.Infrastructure.CimInstance]) {
                    foreach ($prop in $readResult.CimInstanceProperties) {
                        if ($prop.Name -match 'Return|Data') { $sac1Before = $prop.Value; break }
                    }
                }
                elseif ($readResult -is [System.Management.Automation.PSCustomObject]) {
                    if ($readResult.PSObject.Properties['Return']) { $sac1Before = $readResult.PSObject.Properties['Return'].Value }
                }
                Write-Info "SAC1 before call: $(if ($null -ne $sac1Before) { "0x$($sac1Before.ToString('X'))" } else { 'unknown' })"
            } catch {}
        }

        # Build UInt64 payload: SA00 (byte 0) = SubCommand, SAC1 (bytes 4-7) = Function
        # Little-endian: byte[0]=SA00, byte[4..7]=SAC1 as DWord
        # MUST cast to UInt64 BEFORE shift — PowerShell -shl on Int32 wraps at 32 bits
        $funcHi = [uint64]$Function -shl 32
        $payload = [uint64]$SubCommand -bor $funcHi
        Write-Info "GetSetULong(0x$($payload.ToString('X16'))): SA00=$SubCommand SAC1=0x$($Function.ToString('X4'))"

        $getResult = Invoke-CimMethod -InputObject $inst -MethodName 'GetSetULong' `
            -Arguments @{ $getSetParam = $payload } -ErrorAction Stop

        # Comprehensive return value logging
        Write-Info "Result type: $($getResult.GetType().FullName)"
        $returnValue = $null
        if ($getResult -is [Microsoft.Management.Infrastructure.CimInstance]) {
            foreach ($prop in $getResult.CimInstanceProperties) {
                Write-Info "  $($prop.Name) = $($prop.Value)"
                if ($prop.Name -match '^Return$') { $returnValue = $prop.Value }
            }
            if ($null -eq $returnValue) {
                $firstProp = $getResult.CimInstanceProperties | Where-Object { $_.Name -ne 'PSComputerName' } | Select-Object -First 1
                if ($firstProp) { $returnValue = $firstProp.Value }
            }
        }
        elseif ($getResult -is [uint32] -or $getResult -is [int] -or $getResult -is [uint64]) {
            $returnValue = $getResult
        }
        elseif ($getResult -is [System.Management.Automation.PSCustomObject]) {
            # PowerShell wraps CIM results as PSCustomObject
            Write-Info "  Properties: $($getResult.PSObject.Properties.Name -join ', ')"
            if ($getResult.PSObject.Properties['Return']) {
                $returnValue = $getResult.PSObject.Properties['Return'].Value
                Write-Info "  Return = $returnValue"
            }
            if ($getResult.PSObject.Properties['ReturnValue']) {
                $rvSuccess = $getResult.PSObject.Properties['ReturnValue'].Value
                Write-Info "  ReturnValue (success) = $rvSuccess"
            }
        }
        else {
            Write-Info "Unexpected result: $($getResult | Out-String)"
        }

        # Diagnostic: read SAC1 after call
        if ($instances.Count -gt 1) {
            try {
                $readResult2 = Invoke-CimMethod -InputObject $instances[1] -MethodName 'GetULong' -Arguments @{ $getParam = [uint32]0 } -ErrorAction SilentlyContinue
                $sac1After = $null
                if ($readResult2 -is [Microsoft.Management.Infrastructure.CimInstance]) {
                    foreach ($prop in $readResult2.CimInstanceProperties) {
                        if ($prop.Name -match 'Return|Data') { $sac1After = $prop.Value; break }
                    }
                }
                elseif ($readResult2 -is [System.Management.Automation.PSCustomObject]) {
                    if ($readResult2.PSObject.Properties['Return']) { $sac1After = $readResult2.PSObject.Properties['Return'].Value }
                }
                Write-Info "SAC1 after call: $(if ($null -ne $sac1After) { "0x$($sac1After.ToString('X'))" } else { 'unknown' })"
            } catch {}
        }

        if ($null -ne $returnValue) {
            Write-Info "IGPS returned: 0x$($returnValue.ToString('X')) (0=dGPU on, 1=iGPU only, 2=timeout, 0xAA=powered off via _PS3)"
            if ($SubCommand -eq 0 -and $returnValue -eq 0) {
                Write-OK "IGPS(0) succeeded — dGPU power signal sent!"
            }
            elseif ($SubCommand -eq 1 -and $returnValue -eq 1) {
                Write-OK "IGPS(1) succeeded — dGPU powered off"
            }
            elseif ($returnValue -eq 0xAA -and $SubCommand -eq 1) {
                Write-OK "IGPS(1) returned 0xAA — dGPU was active, powered off via _PS3"
            }
            elseif ($returnValue -eq 0xAA -and $SubCommand -eq 0) {
                Write-Warn "IGPS(0) returned 0xAA — PXP power was ON, called _PS3 (unexpected)"
            }
        }
        else {
            Write-Warn "GetSetULong returned no value (OEMG dispatch may not have reached IGPS)"
        }

        return $true
    }
    catch {
        Write-Warn "WMI GPU control failed: $($_.Exception.Message)"
        try {
            $class = Get-CimClass -Namespace root\wmi -ClassName 'AcpiTest_MULong' -ErrorAction SilentlyContinue
            if ($class) {
                foreach ($m in $class.CimClassMethods) {
                    $ps = @($m.Parameters | ForEach-Object { "$($_.Name):$($_.CimType)" })
                    Write-Info "  Method: $($m.Name)($($ps -join ', '))"
                }
            }
        } catch {}
    }

    return $false
}

function Invoke-AcpiIgpsIoctl {
    param([int]$Mode)

    # Try direct ACPI IOCTL on the EC0 device
    # Requires finding the correct device interface path

    $ecDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'ACPI\\PNP0C09' })

    if ($ecDevices.Count -eq 0) {
        Write-Info "EC0 device not found for IOCTL approach"
        return $false
    }

    $GENERIC_READ = 0x80000000
    $GENERIC_WRITE = 0x40000000
    $FILE_SHARE_RW = 0x03
    $OPEN_EXISTING = 3

    foreach ($ecDev in $ecDevices) {
        # Try multiple path formats
        $paths = @(
            # Format 1: \\?\ prefix (extended-length path)
            ('\\?\' + ($ecDev.InstanceId -replace '\\', '#')),
            # Format 2: Standard device path
            ('\\.\' + ($ecDev.InstanceId -replace '\\', '#')),
            # Format 3: Just the hardware ID part
            ('\\.\ACPI#PNP0C09#0'),
            ('\\.\ACPI#PNP0C09#1')
        )

        foreach ($devicePath in $paths) {
            $handle = [GpuSwitchApi]::CreateFile(
                $devicePath,
                $GENERIC_READ -bor $GENERIC_WRITE,
                $FILE_SHARE_RW,
                [IntPtr]::Zero,
                $OPEN_EXISTING,
                0,
                [IntPtr]::Zero
            )

            if ($handle -eq [IntPtr]::new(-1)) { continue }

            Write-Info "Opened EC device: $devicePath"
            try {
                # ACPI_EVAL_INPUT_BUFFER_SIMPLE_INTEGER (20 bytes)
                $inputBuffer = New-Object byte[] 20
                [BitConverter]::GetBytes([uint32]0x00000003).CopyTo($inputBuffer, 0)
                [BitConverter]::GetBytes([uint32]1).CopyTo($inputBuffer, 4)
                [System.Text.Encoding]::ASCII.GetBytes('IGPS').CopyTo($inputBuffer, 8)
                [BitConverter]::GetBytes([uint64]$Mode).CopyTo($inputBuffer, 12)

                $outputBuffer = New-Object byte[] 256
                $bytesReturned = 0

                $success = [GpuSwitchApi]::DeviceIoControl(
                    $handle, 0x00320008,
                    $inputBuffer, $inputBuffer.Length,
                    $outputBuffer, $outputBuffer.Length,
                    [ref]$bytesReturned, [IntPtr]::Zero
                )

                if ($success) {
                    Write-OK "ACPI IGPS($Mode) evaluated successfully"
                    return $true
                }
            }
            finally {
                [GpuSwitchApi]::CloseHandle($handle)
            }
        }
    }

    Write-Info "Could not open EC device for ACPI IOCTL"
    return $false
}

function Show-Diagnose {
    Write-Host "=== GPU Diagnostics ===" -ForegroundColor Cyan
    Write-Host ""

    # Show EC0 device info
    Write-Host "--- EC0 Device ---"
    $ecDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'PNP0C09' })
    foreach ($dev in $ecDevices) {
        Write-Info "$($dev.FriendlyName): $($dev.InstanceId) [$($dev.Status)]"
    }
    Write-Host ""

    # Show AMW0 (WMI) device info
    Write-Host "--- AMW0 WMI Device ---"
    $wmiDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'PNP0C14' })
    foreach ($dev in $wmiDevices) {
        Write-Info "$($dev.FriendlyName): $($dev.InstanceId) [$($dev.Status)]"
    }
    Write-Host ""

    # Show WMI classes with methods in root\wmi
    Write-Host "--- WMI Classes (root\wmi) with methods ---"
    try {
        $wmiClasses = @(Get-CimClass -Namespace root\wmi -ErrorAction SilentlyContinue |
            Where-Object { $_.CimClassMethods.Count -gt 0 })

        foreach ($class in $wmiClasses) {
            $methods = @($class.CimClassMethods | ForEach-Object { $_.Name })
            Write-Info "$($class.CimClassName): $($methods -join ', ')"
        }

        if ($wmiClasses.Count -eq 0) {
            Write-Warn "No WMI classes with methods found in root\wmi"
        }
    }
    catch {
        Write-Err "Cannot enumerate WMI classes: $($_.Exception.Message)"
    }
    Write-Host ""

    # Show AcpiTest_* method signatures (these are the AMW0 WMI methods)
    Write-Host "--- AcpiTest WMI Method Signatures ---"
    try {
        $acpiClasses = @(Get-CimClass -Namespace root\wmi -ErrorAction SilentlyContinue |
            Where-Object { $_.CimClassName -match 'AcpiTest' })

        foreach ($class in $acpiClasses) {
            Write-Host ""
            Write-Info "Class: $($class.CimClassName)"
            $instances = @(Get-CimInstance -Namespace root\wmi -ClassName $class.CimClassName -ErrorAction SilentlyContinue)
            Write-Info "  Instances: $($instances.Count)"
            foreach ($inst in $instances) {
                $instProps = $inst.CimInstanceProperties | ForEach-Object { "$($_.Name)=$($_.Value)" }
                Write-Info "  Props: $($instProps -join ', ')"
            }
            foreach ($method in $class.CimClassMethods) {
                $paramList = @($method.Parameters | ForEach-Object {
                    "$($_.Name): $($_.CimType)$($_.IsOptional ? ' (opt)' : '')" })
                Write-Info "  $($method.Name)($($paramList -join ', '))"
            }
        }
    }
    catch {
        Write-Err "Cannot get AcpiTest details: $($_.Exception.Message)"
    }
    Write-Host ""

    # Show NVIDIA/root port device info
    Write-Host "--- PCIe Devices ---"
    $nvidiaDevs = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -ErrorAction SilentlyContinue)
    foreach ($dev in $nvidiaDevs) {
        Write-Info "NVIDIA: $($dev.FriendlyName) [$($dev.Status)] $($dev.InstanceId)"
    }

    $rootPorts = @(Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'VEN_8086&DEV_AE4E' })
    foreach ($dev in $rootPorts) {
        Write-Info "Root port: $($dev.FriendlyName) [$($dev.Status)] $($dev.InstanceId)"
    }
}

# --- dGPU Recovery (shared by dgpu and hybrid) ---

function Restore-NvidiaDGpu {
    # Full dGPU recovery: ACPI IGPS(0) → root port power cycle → rescan → driver enable
    # Returns the active NVIDIA display device, or $null on failure.
    #
    # Key insight: IGPS(0) only sends Notify when PXP._STA==0.
    # When PXP._STA!=0 (power ON), IGPS(0) calls _PS3 which is just debug logging.
    # The ONLY way to toggle PXP power is through Windows PnP:
    #   Disable-PnpDevice (root port) → Windows calls PXP._OFF → PXP._STA=0
    #   Enable-PnpDevice (root port)  → Windows calls PXP._ON  → PXP._STA=1 + hardware power-on

    # Step 1: Call ACPI IGPS(0) to set IGPU=0
    Write-Info "Step 1/4: ACPI IGPS(0)..."
    if (-not $DryRun) {
        Invoke-AcpiIgps -Mode 0
        Start-Sleep -Seconds 2
    }

    # Step 2: Power cycle root port via Windows PnP (triggers PXP._OFF then PXP._ON)
    Write-Info "Step 2/4: Power cycling root port (PXP power cycle)..."
    $rootPortId = Find-NvidiaRootPort
    if ($rootPortId) {
        if (-not $DryRun) {
            $rpDev = Get-PnpDevice -InstanceId $rootPortId -ErrorAction SilentlyContinue
            if ($rpDev -and $rpDev.Status -eq 'OK') {
                Write-Info "Disabling root port..."
                Disable-PnpDevice -InstanceId $rootPortId -Confirm:$false -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            }
            Write-Info "Enabling root port..."
            Enable-PnpDevice -InstanceId $rootPortId -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            $rpDev = Get-PnpDevice -InstanceId $rootPortId -ErrorAction SilentlyContinue
            if ($rpDev -and $rpDev.Status -eq 'OK') {
                Write-OK "Root port powered on"
            }
            else {
                Write-Warn "Root port Status: $($rpDev.Status)"
            }
        }
    }
    else {
        Write-Warn "Root port not found"
    }

    # Step 3: Remove ghost NVIDIA devices, then rescan PCIe bus
    Write-Info "Step 3/4: Removing ghost devices and rescanning..."
    if (-not $DryRun) {
        $ghostDevs = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -ne 'OK' })
        foreach ($ghost in $ghostDevs) {
            Write-Info "Removing ghost: $($ghost.InstanceId)"
            pnputil /remove-device $ghost.InstanceId 2>$null | Out-Null
        }
        Start-Sleep -Seconds 1
    }

    Invoke-PcieRescan

    # Step 4: Wait for dGPU to appear (broad search: hardware ID + display class)
    Write-Info "Step 4/4: Waiting for dGPU to appear..."
    $nvidiaAny = @()
    $found = $false
    if (-not $DryRun) {
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 2
            # Primary: Display class with NVIDIA friendly name
            $nvidiaAny = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
            if ($nvidiaAny.Count -gt 0) {
                $found = $true
                Write-OK "dGPU detected: $($nvidiaAny[0].FriendlyName)"
                break
            }
            # Secondary: Display class any status (driver not loaded yet)
            $nvidiaAny = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -ne 'Unknown' })
            if ($nvidiaAny.Count -gt 0) {
                $found = $true
                Write-OK "dGPU detected: $($nvidiaAny[0].FriendlyName) (Status: $($nvidiaAny[0].Status))"
                break
            }
            # Tertiary: Any device with NVIDIA PCI vendor ID (GPU present but no driver)
            $nvidiaAny = @(Get-PnpDevice -ErrorAction SilentlyContinue |
                Where-Object { $_.InstanceId -match 'VEN_10DE&DEV_2F80' })
            if ($nvidiaAny.Count -gt 0) {
                $found = $true
                Write-OK "dGPU hardware detected: $($nvidiaAny[0].InstanceId) (Status: $($nvidiaAny[0].Status))"
                break
            }
            Write-Info "  Waiting... ($($i+1)/20)"
        }
    }

    if (-not $found) {
        return $null
    }

    # Enable driver if not OK
    $nvidiaNotOk = @($nvidiaAny | Where-Object { $_.Status -ne 'OK' })
    if ($nvidiaNotOk.Count -gt 0) {
        foreach ($dev in $nvidiaNotOk) {
            try {
                Enable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
                Write-OK "Enabled: $($dev.FriendlyName)"
                break
            }
            catch {
                $output = pnputil /enable-device $dev.InstanceId 2>&1
                if ($output -match 'successfully') {
                    Write-OK "Enabled via pnputil"
                    break
                }
                Write-Warn "Enable failed: $output"
            }
        }
        Start-Sleep -Seconds 5
    }

    # Return the active Display device, or the hardware device as fallback
    $nvidiaOk = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
    if ($nvidiaOk.Count -gt 0) {
        return $nvidiaOk[0]
    }
    # Hardware is on bus but Display driver not loaded — try driver recovery
    if ($nvidiaAny.Count -gt 0 -and $nvidiaAny[0].Status -eq 'OK') {
        Write-Info "dGPU hardware present, attempting driver recovery..."

        # Try restarting NVIDIA driver service
        try {
            $svc = Get-Service -Name 'nvlddmkm' -ErrorAction SilentlyContinue
            if ($svc) {
                Write-Info "Restarting NVIDIA driver service..."
                Restart-Service -Name 'nvlddmkm' -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 5
            }
        } catch {}

        $nvidiaOk2 = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
        if ($nvidiaOk2.Count -gt 0) {
            return $nvidiaOk2[0]
        }

        # Try enabling all NVIDIA devices found
        $allNv = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -ne 'OK' })
        foreach ($dev in $allNv) {
            try {
                Enable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
                Write-OK "Enabled: $($dev.FriendlyName)"
                break
            } catch {}
        }
        Start-Sleep -Seconds 3

        $nvidiaOk3 = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
        if ($nvidiaOk3.Count -gt 0) {
            return $nvidiaOk3[0]
        }

        # Check for Code 10 (driver mismatch with POSTed display adapter)
        $code10 = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Error' })
        if ($code10.Count -gt 0) {
            Write-Warn "NVIDIA driver reports Code 10 (hot-plug driver mismatch)"
            Write-Info "This requires a reboot for the driver to properly bind"
        }

        return $nvidiaAny[0]
    }
    return $null
}

# --- PnP Device Control (fallback, like OEM disableDGpu.ps1) ---
# Note: This only disables the driver, does NOT power off the dGPU.
# The dGPU stays on PCIe bus and continues drawing power.

function Disable-NvidiaPnp {
    $devices = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
    if ($devices.Count -eq 0) {
        Write-OK "No active NVIDIA display devices to disable"
        return $true
    }

    foreach ($dev in $devices) {
        if ($DryRun) {
            Write-Info "[DRY-RUN] Disable-PnpDevice: $($dev.FriendlyName)"
        }
        else {
            try {
                Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
                Write-OK "Disabled: $($dev.FriendlyName)"
            }
            catch {
                Write-Err "Failed: $($_.Exception.Message)"
                return $false
            }
        }
    }
    return $true
}

function Enable-NvidiaPnp {
    $devices = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status Error -ErrorAction SilentlyContinue)
    if ($devices.Count -eq 0) {
        # Check if already enabled
        $okDevices = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
        if ($okDevices.Count -gt 0) {
            Write-OK "dGPU already active"
            return $true
        }
        Write-Warn "No NVIDIA device found"
        return $false
    }

    foreach ($dev in $devices) {
        if ($DryRun) {
            Write-Info "[DRY-RUN] Enable-PnpDevice: $($dev.FriendlyName)"
        }
        else {
            try {
                Enable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
                Write-OK "Enabled: $($dev.FriendlyName)"
            }
            catch {
                Write-Err "Failed: $($_.Exception.Message)"
                return $false
            }
        }
    }
    return $true
}

# --- Commands ---

function Show-Status {
    Write-Host "=== GPU Mode Status ===" -ForegroundColor Cyan
    Write-Host ""

    $allGpus = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue)

    if ($allGpus.Count -eq 0) {
        Write-Warn "No display devices found"
        return
    }

    Write-Host "Display devices:"
    foreach ($gpu in $allGpus) {
        $icon = switch ($gpu.Status) {
            'OK'       { '[ON]  ' }
            'Error'    { '[OFF] ' }
            'Degraded' { '[WARN]' }
            default    { "[?]  " }
        }
        $color = switch ($gpu.Status) {
            'OK'    { 'Green' }
            'Error' { 'DarkGray' }
            default { 'Yellow' }
        }
        Write-Host "  $icon $($gpu.FriendlyName)" -ForegroundColor $color
    }
    Write-Host ""

    # Determine mode
    $nvidiaOk = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
    $nvidiaOff = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status Error -ErrorAction SilentlyContinue)
    $nvidiaAll = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -ErrorAction SilentlyContinue)

    if ($nvidiaOk.Count -gt 0) {
        $driver = Get-PnpDeviceProperty -InstanceId $nvidiaOk[0].InstanceId -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction SilentlyContinue
        Write-Host "  NVIDIA driver: $($driver.Data)" -ForegroundColor DarkGray
        Write-Host ""
        Write-OK "Mode: Hybrid or dGPU Only (dGPU active)"
    }
    elseif ($nvidiaOff.Count -gt 0) {
        Write-Warn "Mode: iGPU Only (dGPU disabled — still on PCIe, drawing power)"
        Write-Info "Run: .\gpu-switch.ps1 igpu  to fully power off via PCIe eject"
    }
    elseif ($nvidiaAll.Count -gt 0) {
        # Device present but not OK or Error — likely Unknown/Degraded (transitional state)
        Write-Warn "Mode: Transitional (dGPU on bus, Status: $($nvidiaAll[0].Status))"
        Write-Info "Run: .\gpu-switch.ps1 hybrid  to re-enable the driver"
    }
    else {
        Write-OK "Mode: iGPU Only (no dGPU detected — fully powered off)"
    }

    Write-Host ""
    Write-Info "Commands: igpu | dgpu | hybrid"
}

function Switch-IGpuOnly {
    Write-Info "Switching to iGPU Only mode..."
    Write-Host ""

    # Check current state
    $allNv = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -ErrorAction SilentlyContinue)
    $nvidiaOk = @($allNv | Where-Object { $_.Status -eq 'OK' })
    $nvidiaOff = @($allNv | Where-Object { $_.Status -eq 'Error' })

    if ($allNv.Count -eq 0) {
        Write-OK "Already in iGPU Only mode (no dGPU present)"
        return
    }

    # Confirm
    if (-not $Force) {
        Write-Warn "This will power off the dGPU via PCIe eject."
        Write-Warn "Applications using the dGPU will be affected."
        $confirm = Read-Host "Continue? [y/N]"
        if ($confirm -notin @('y', 'Y')) {
            Write-Info "Aborted"
            return
        }
    }

    if ($Fallback) {
        Write-Warn "Using PnP fallback — dGPU will stay on PCIe (not fully powered off)"
        Disable-NvidiaPnp
        return
    }

    # Step 1: Unload driver if still active
    if ($nvidiaOk.Count -gt 0) {
        Write-Info "Step 1/3: Unloading dGPU driver..."
        Disable-NvidiaPnp
        Start-Sleep -Seconds 2
    }
    else {
        Write-Info "Step 1/3: dGPU driver already disabled"
    }

    # Step 2: ACPI IGPS(1) to properly power off the dGPU slot
    # First disable the root port via Windows to ensure PXP._OFF is called,
    # so that IGPS(1) sees PXP._STA==0 and takes the correct branch.
    Write-Info "Step 2/3: Powering off dGPU..."
    if (-not $DryRun) {
        $rootPortId = Find-NvidiaRootPort
        if ($rootPortId) {
            $rpDev = Get-PnpDevice -InstanceId $rootPortId -ErrorAction SilentlyContinue
            if ($rpDev -and $rpDev.Status -eq 'OK') {
                Write-Info "Disabling root port to power off PXP..."
                Disable-PnpDevice -InstanceId $rootPortId -Confirm:$false -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
        }
        Invoke-AcpiIgps -Mode 1
        Start-Sleep -Seconds 2
    }

    # Step 3: PCIe eject as fallback
    Write-Info "Step 3/3: PCIe hot-eject dGPU..."

    if ($DryRun) {
        Write-Info "[DRY-RUN] CM_Request_Device_Eject on NVIDIA PCIe device"
        return
    }

    # Find the NVIDIA PCIe device to eject
    $gpuDeviceId = Find-NvidiaPciDeviceId

    if (-not $gpuDeviceId) {
        Write-OK "No NVIDIA PCIe device found — already removed from bus"
        return
    }

    Write-Info "Ejecting: $gpuDeviceId"
    $success = Invoke-PcieDeviceEject -DeviceInstanceId $gpuDeviceId

    if ($success) {
        Write-OK "dGPU ejected from PCIe — fully powered off"
    }
    else {
        Write-Warn "PCIe eject failed or vetoed"
        Write-Host ""
        Write-Warn "Possible reasons:"
        Write-Host "  - A process still has the GPU open (close GPU apps and retry)"
        Write-Host "  - The device doesn't support hot-eject"
        Write-Host "  - The GPU is in use by the display server"
        Write-Host ""
        Write-Host "Try: Disable-PnpDevice first, then re-run this script." -ForegroundColor Cyan
    }

    # Verify and clean up residual devices
    Start-Sleep -Seconds 3
    $remaining = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) {
        Write-OK "Verified: dGPU fully removed from PCIe bus"
    }
    else {
        Write-Info "Cleaning up residual NVIDIA devices (Status: $($remaining[0].Status))..."
        foreach ($dev in $remaining) {
            Write-Info "  Removing: $($dev.InstanceId) [$($dev.Status)]"
            pnputil /remove-device $dev.InstanceId 2>$null | Out-Null
        }
        Start-Sleep -Seconds 2
        $checkAgain = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -ErrorAction SilentlyContinue)
        if ($checkAgain.Count -eq 0) {
            Write-OK "dGPU fully removed from PCIe bus"
        }
        else {
            Write-Warn "NVIDIA device still present: $($checkAgain[0].Status)"
            Write-Info "dGPU may require a full power cycle to disappear"
        }
    }
}

function Switch-DGpuOnly {
    Write-Info "Switching to dGPU Only mode..."
    Write-Host ""
    Write-Warn "dGPU Only requires a restart (display mux switch)."
    Write-Host ""

    # Check if dGPU is already active
    $nvidiaOk = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)

    if ($nvidiaOk.Count -eq 0) {
        if ($DryRun) {
            Write-Info "[DRY-RUN] ACPI IGPS(0) + PCIe power cycle + rescan"
            return
        }

        # Full recovery: ACPI Bus Check + power cycle + rescan
        $dGpu = Restore-NvidiaDGpu
        if (-not $dGpu) {
            Write-Err "dGPU not detected — cannot switch to dGPU Only mode"
            Write-Host ""
            Write-Host "The dGPU may need a reboot to come back online." -ForegroundColor Yellow
            Write-Host "Try: shutdown /r /t 0" -ForegroundColor Cyan
            return
        }
        $nvidiaOk = @($dGpu)
    }

    Write-OK "dGPU is active: $($nvidiaOk[0].FriendlyName)"
    Write-Host ""

    # Set NVIDIA as preferred GPU (registry settings)
    if (-not $DryRun) {
        $dwmPath = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"
        if (Test-Path $dwmPath) {
            Set-ItemProperty -Path $dwmPath -Name "OverlayMinHardwareSupported" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        }

        $nvPath = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global"
        if (Test-Path $nvPath) {
            Set-ItemProperty -Path $nvPath -Name "PreferredGraphicsProcessor" -Value "HighPerformanceNVIDIA" -ErrorAction SilentlyContinue
        }
        Write-OK "Configured dGPU as preferred GPU"
    }

    Write-Host ""
    Write-OK "dGPU Only mode configured"
    Write-Host ""
    Write-Host -ForegroundColor Yellow "=== Restart Required ==="
    Write-Host "  dGPU Only mode involves a display mux hardware switch."
    Write-Host "  Restart to apply:  shutdown /r /t 0"
    Write-Host ""

    if (-not $Force) {
        $confirm = Read-Host "Restart now? [y/N]"
        if ($confirm -in @('y', 'Y') -and -not $DryRun) {
            shutdown /r /t 5 /c "GPU mode: switching to dGPU Only"
        }
    }
}

function Switch-Hybrid {
    Write-Info "Switching to Hybrid mode..."
    Write-Host ""

    # Check if already active
    $nvidiaOk = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
    if ($nvidiaOk.Count -gt 0) {
        Write-OK "Already in Hybrid mode (dGPU active)"
        return
    }

    if ($DryRun) {
        Write-Info "[DRY-RUN] ACPI IGPS(0) + PCIe power cycle + rescan + driver enable"
        return
    }

    # Full recovery: ACPI IGPS(0) + root port power cycle + rescan
    $dGpu = Restore-NvidiaDGpu
    if ($dGpu -and $dGpu.InstanceId) {
        # Check if the driver actually loaded (Display class with OK status)
        $nvidiaDisplayOk = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
        if ($nvidiaDisplayOk.Count -gt 0) {
            $driver = Get-PnpDeviceProperty -InstanceId $nvidiaDisplayOk[0].InstanceId -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction SilentlyContinue
            Write-OK "Hybrid mode active — dGPU: $($nvidiaDisplayOk[0].FriendlyName) (driver: $($driver.Data))"
        }
        else {
            # Hardware detected but driver didn't load (Code 10 — hot-plug mismatch)
            Write-OK "dGPU hardware restored: $($dGpu.FriendlyName)"
            Write-Warn "NVIDIA driver not loaded — reboot required for driver binding"
            Write-Host ""
            Write-Host "  shutdown /r /t 0" -ForegroundColor Cyan
        }
    }
    else {
        Write-Err "dGPU not detected after recovery"
        Write-Host ""
        Write-Host "The dGPU may need a reboot to come back online." -ForegroundColor Yellow
        Write-Host "Try: shutdown /r /t 0" -ForegroundColor Cyan
    }
}

# --- Main ---

if (-not (Test-Admin) -and $Command -ne 'status') {
    Write-Err "Requires Administrator. Run as:"
    Write-Err "  Start-Process PowerShell -Verb RunAs -ArgumentList '-NoProfile -File `"$PSCommandPath`" $Command'"
    exit 1
}

switch ($Command) {
    'status'   { Show-Status }
    'igpu'     { Switch-IGpuOnly }
    'dgpu'     { Switch-DGpuOnly }
    'hybrid'   { Switch-Hybrid }
    'diagnose' { Show-Diagnose }
}
