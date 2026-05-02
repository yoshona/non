#!/usr/bin/env python3
"""
GPU Mode Switching Tool for Linux (Mechrevo / Tongfang Laptops)
Ported from Windows GCUService.exe
"""

import os
import sys
import time
import logging
import subprocess
from pathlib import Path
from typing import Optional

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler()]
)
log = logging.getLogger("gpu_switch")


# ============================================================
# GPU Controller — Linux Native GPU Switching
# ============================================================
class GpuController:
    """Controls NVIDIA dGPU on Linux using PCI / bbswitch / Runtime PM."""

    def __init__(self, pci_addr: str = "auto"):
        self._pci_addr = pci_addr
        self._detect_pci()

    def _detect_pci(self):
        if self._pci_addr != "auto":
            return
        try:
            r = subprocess.run(["lspci", "-D", "-d", "10de:"],
                               capture_output=True, text=True, timeout=5)
            if r.returncode == 0 and r.stdout.strip():
                self._pci_addr = r.stdout.strip().split()[0]
                log.info(f"Detected dGPU PCI: {self._pci_addr}")
        except FileNotFoundError:
            log.debug("lspci not found")
        except Exception as e:
            log.debug(f"PCI detection: {e}")

    # ---- Status ----
    @property
    def is_dgpu_off(self) -> bool:
        """True if dGPU is removed/powered off"""
        if not self._pci_addr or self._pci_addr == "auto":
            return False
        return not Path(f"/sys/bus/pci/devices/{self._pci_addr}").exists()

    def status(self) -> dict:
        return {
            "mode": "IGPU Only" if self.is_dgpu_off else "Hybrid/dGPU",
            "pci_addr": self._pci_addr or "N/A",
            "dgpu_removed": self.is_dgpu_off,
        }

    # ---- GPU Switching ----
    def switch_to_igpu_only(self) -> bool:
        """Disable dGPU — switch to iGPU only"""
        log.info("Switching to IGPU Only...")

        for method in [
            self._pci_remove,
            self._bbswitch_off,
            self._runtime_pm_auto,
            self._nvidia_pm_off,
        ]:
            if method():
                log.info("IGPU Only mode enabled")
                return True

        log.error("All GPU disable methods failed")
        return False

    def switch_to_hybrid(self) -> bool:
        """Re-enable dGPU — switch to Hybrid"""
        log.info("Switching to Hybrid (re-enabling dGPU)...")

        for method in [
            self._pci_rescan,
            self._bbswitch_on,
            self._runtime_pm_on,
        ]:
            if method():
                log.info("Hybrid mode enabled")
                return True

        log.error("All GPU enable methods failed")
        return False

    # ---- PCI remove/rescan ----
    def _pci_remove(self) -> bool:
        if not self._pci_addr or self._pci_addr == "auto":
            return False
        remove_path = Path(f"/sys/bus/pci/devices/{self._pci_addr}/remove")
        if not remove_path.exists():
            return False
        if os.access(remove_path, os.W_OK):
            remove_path.write_text("1")
        else:
            subprocess.run(["sudo", "bash", "-c",
                f"echo 1 > /sys/bus/pci/devices/{self._pci_addr}/remove"],
                capture_output=True, timeout=10)
        time.sleep(1)
        return self.is_dgpu_off

    def _pci_rescan(self) -> bool:
        rescan = Path("/sys/bus/pci/rescan")
        if not rescan.exists():
            return False
        if os.access(rescan, os.W_OK):
            rescan.write_text("1")
        else:
            subprocess.run(["sudo", "bash", "-c", "echo 1 > /sys/bus/pci/rescan"],
                           capture_output=True, timeout=10)
        time.sleep(2)
        return not self.is_dgpu_off

    # ---- bbswitch ----
    def _bbswitch_off(self) -> bool:
        bb = Path("/proc/acpi/bbswitch")
        if not bb.exists():
            return False
        r = subprocess.run(["sudo", "tee", "/proc/acpi/bbswitch"],
                           input="OFF", capture_output=True, text=True, timeout=5)
        return "OFF" in (r.stdout or "")

    def _bbswitch_on(self) -> bool:
        bb = Path("/proc/acpi/bbswitch")
        if not bb.exists():
            return False
        r = subprocess.run(["sudo", "tee", "/proc/acpi/bbswitch"],
                           input="ON", capture_output=True, text=True, timeout=5)
        return "ON" in (r.stdout or "")

    # ---- Runtime PM ----
    def _runtime_pm_auto(self) -> bool:
        if not self._pci_addr:
            return False
        ctrl = Path(f"/sys/bus/pci/devices/{self._pci_addr}/power/control")
        if ctrl.exists():
            if os.access(ctrl, os.W_OK):
                ctrl.write_text("auto")
            else:
                subprocess.run(["sudo", "bash", "-c",
                    f"echo auto > {ctrl}"], capture_output=True, timeout=5)
            return True
        return False

    def _runtime_pm_on(self) -> bool:
        if not self._pci_addr:
            return False
        ctrl = Path(f"/sys/bus/pci/devices/{self._pci_addr}/power/control")
        if ctrl.exists():
            if os.access(ctrl, os.W_OK):
                ctrl.write_text("on")
            else:
                subprocess.run(["sudo", "bash", "-c",
                    f"echo on > {ctrl}"], capture_output=True, timeout=5)
            return True
        return False

    # ---- NVIDIA Persistence Mode ----
    def _nvidia_pm_off(self) -> bool:
        try:
            return subprocess.run(["nvidia-smi", "-pm", "0"],
                                  capture_output=True, timeout=5).returncode == 0
        except FileNotFoundError:
            return False


# ============================================================
# EC Controller — Embedded Controller (ACPI/EC) Access
# ============================================================
class EcController:
    EC_CMD = 0x66
    EC_DATA = 0x62

    def __init__(self):
        self._methods = []
        try:
            if Path("/sys/kernel/debug/ec/ec0/io").exists():
                self._methods.append("ec_sys")
        except PermissionError:
            pass
        try:
            if Path("/proc/acpi/call").exists():
                self._methods.append("acpi_call")
        except PermissionError:
            pass
        try:
            if Path("/dev/port").exists():
                self._methods.append("port_io")
        except PermissionError:
            pass
        if self._methods:
            log.info(f"EC access: {', '.join(self._methods)}")
        else:
            log.info("EC access not available")

    @property
    def available(self) -> bool:
        return bool(self._methods)

    def read(self, addr: int) -> Optional[int]:
        if "ec_sys" in self._methods:
            return self._ec_sys_read(addr)
        if "acpi_call" in self._methods:
            return self._acpi_read(addr)
        if "port_io" in self._methods:
            return self._port_read(addr)
        return None

    def write(self, addr: int, value: int):
        if "ec_sys" in self._methods:
            self._ec_sys_write(addr, value)
        elif "acpi_call" in self._methods:
            self._acpi_write(addr, value)
        elif "port_io" in self._methods:
            self._port_write(addr, value)

    def _ec_sys_read(self, addr: int) -> Optional[int]:
        try:
            data = Path("/sys/kernel/debug/ec/ec0/io").read_bytes()
            return data[addr] if addr < len(data) else None
        except Exception as e:
            log.debug(f"ec_sys read: {e}")
            return None

    def _ec_sys_write(self, addr: int, value: int):
        try:
            p = Path("/sys/kernel/debug/ec/ec0/io")
            data = bytearray(p.read_bytes())
            if addr < len(data):
                data[addr] = value & 0xFF
                p.write_bytes(bytes(data))
        except Exception as e:
            log.debug(f"ec_sys write: {e}")

    def _acpi_read(self, addr: int) -> Optional[int]:
        try:
            r = subprocess.run(["sudo", "tee", "/proc/acpi/call"],
                               input=f"\\_SB.PCI0.LPCB.EC0.RDEC {addr:04X}",
                               capture_output=True, text=True, timeout=5)
            if "0x" in (r.stdout or ""):
                return int(r.stdout.split("0x")[1], 16)
        except Exception:
            pass
        return None

    def _acpi_write(self, addr: int, value: int):
        try:
            subprocess.run(["sudo", "tee", "/proc/acpi/call"],
                           input=f"\\_SB.PCI0.LPCB.EC0.WREC {addr:04X} {value:02X}",
                           capture_output=True, text=True, timeout=5)
        except Exception as e:
            log.debug(f"acpi_call write: {e}")

    def _port_read(self, addr: int) -> Optional[int]:
        try:
            with open("/dev/port", "rb") as f:
                f.seek(addr)
                return f.read(1)[0]
        except Exception:
            return None

    def _port_write(self, addr: int, value: int):
        try:
            with open("/dev/port", "wb") as f:
                f.seek(addr)
                f.write(bytes([value & 0xFF]))
        except Exception:
            pass


# ============================================================
# Power Source Detection
# ============================================================
def is_on_ac_power() -> bool:
    paths = [
        "/sys/class/power_supply/AC0/online",
        "/sys/class/power_supply/AC/online",
        "/sys/class/power_supply/ACAD/online",
    ]
    for p in paths:
        try:
            return Path(p).read_text().strip() == "1"
        except Exception:
            continue
    return True  # assume AC


# ============================================================
# CLI
# ============================================================
def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="GPU Mode Switching Tool for Linux Laptops"
    )
    parser.add_argument("command", nargs="?", default=None,
                        choices=["on", "off", "auto", "status", "ec-read", "ec-write"],
                        help="Command to execute")
    parser.add_argument("--pci", default="auto",
                        help="dGPU PCI address, e.g. 0000:01:00.0")
    parser.add_argument("--simulate", action="store_true",
                        help="Simulate without hardware access")
    parser.add_argument("--ec-addr", type=lambda x: int(x, 0),
                        help="EC register address (hex)")
    parser.add_argument("--ec-value", type=lambda x: int(x, 0),
                        help="EC register value to write (hex)")
    parser.add_argument("--interactive", "-i", action="store_true",
                        help="Run in interactive mode")
    args = parser.parse_args()

    gpu = GpuController(args.pci) if not args.simulate else "sim"
    ec = EcController() if not args.simulate else "sim"

    def _exec(cmd):
        if cmd == "status":
            if args.simulate:
                print("mode:     IGPU Only (simulated)")
                print("dgpu_pci: auto (simulated)")
                print("ec:       False (simulated)")
            else:
                s = gpu.status()
                print(f"mode:     {s['mode']}")
                print(f"dgpu_pci: {s['pci_addr']}")
                print(f"dgpu_off: {s['dgpu_removed']}")
                print(f"ec:       {ec.available}")
                print(f"ac_power: {is_on_ac_power()}")
        elif cmd == "on":
            if args.simulate:
                log.info("[SIM] dGPU disabled (IGPU Only)")
            else:
                gpu.switch_to_igpu_only()
        elif cmd == "off":
            if args.simulate:
                log.info("[SIM] dGPU enabled (Hybrid)")
            else:
                gpu.switch_to_hybrid()
        elif cmd == "auto":
            on_ac = is_on_ac_power() if not args.simulate else False
            if on_ac:
                _exec("off")
            else:
                _exec("on")
        elif cmd == "ec-read":
            if args.simulate:
                print("EC read: 0x00 (simulated)")
            elif ec.available and args.ec_addr is not None:
                v = ec.read(args.ec_addr)
                print(f"EC[0x{args.ec_addr:04X}] = 0x{v:02X}" if v is not None else "EC read failed")
            else:
                print("EC not available or no address specified")
        elif cmd == "ec-write":
            if args.simulate:
                log.info(f"[SIM] EC write 0x{args.ec_addr:04X} = 0x{args.ec_value:02X}")
            elif ec.available and args.ec_addr is not None and args.ec_value is not None:
                ec.write(args.ec_addr, args.ec_value)
                log.info(f"EC write 0x{args.ec_addr:04X} = 0x{args.ec_value:02X}")
            else:
                print("EC not available or missing addr/value")

    if args.interactive or not args.command:
        print("GPU Mode Switch Tool")
        print("  on   — IGPU Only (disable dGPU)")
        print("  off  — Hybrid (enable dGPU)")
        print("  auto — Auto based on AC power")
        print("  stat — Status")
        print("  quit — Exit\n")
        while True:
            try:
                cmd = input("gpu> ").strip().lower()
                if cmd in ("q", "quit", "exit"):
                    break
                _exec(cmd)
            except (KeyboardInterrupt, EOFError):
                break
    else:
        _exec(args.command)


if __name__ == "__main__":
    main()
