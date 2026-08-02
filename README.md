# PCILeech FPGA Firmware — Intel PRO/1000 PT Desktop Adapter Emulation

PCILeech FPGA firmware that emulates an **Intel PRO/1000 PT Desktop Adapter
(Intel 82572EI)**. VID `0x8086` / DID `0x107D`, Ethernet controller class code `0x020000`.

---
Discord: @JinJinovo

# English

## Overview

This firmware is based on PCILeech-FPGA and presents the FPGA as a genuine-looking
**Intel PRO/1000 PT Desktop Adapter (82572EI)** on the target system, including full
MMIO register emulation so the stock Intel e1000e driver initializes cleanly.

## Features

- **Full e1000e (82572EI) MMIO register emulation** — CTRL / CTRL_DUP / STATUS / EERD /
  MDIC / CTRL_EXT / ICR~IMC / RCTL / TCTL / RX-TX ring registers / RAL0 / RAH0 / FWSM /
  SW_FW_SYNC / PBA / PHY_CTRL / RLPML, etc.
- **Realistic EEPROM (NVM)** — Intel OUI MAC `00:1B:21:12:34:56`, device/subsystem IDs,
  valid checksum (`0xBABA`).
- **PHY (Marvell 88E1111) link-up emulation** via MDIC.
- **PCIe identity** — VID/DID `8086:107D`, class code `0x020000`, 128 KB BAR0, DSN set.
- **Anti-paste protections** are included to deter unauthorized copying and high-price
  resale of this firmware.
- **EAC (Easy Anti-Cheat) ready** — currently passes EAC without issues.

## Supported boards

| Board | Generate script | Output |
|---|---|---|
| TBX4 100T | `generate – 100T.bat` | `pcileech_zdma_100t_fpga0.bin` |
| Captain 75T / Enigma X1 | `generate – captain - 75T.bat` | `pcileech_captain_75T.bin` |

## Build (Vivado 2023.2)

1. Install Xilinx Vivado WebPACK 2023.2 (or later).
2. Open the Vivado Tcl Shell and `cd` into this directory (forward slashes).
3. Run the generate script for your board (e.g. `generate – 100T.bat`).
4. Run `source vivado_build_100t.tcl -notrace` (or `vivado_build_captain_75T.tcl` for
   the Captain board) to build the bitstream (~1 hour).
5. Flash the produced `.bin` to the FPGA.

## Verification

- Target system shows `Intel Corporation 82572EI Gigabit Ethernet Controller
  (PRO/1000 PT Desktop Adapter)`.
- `lspci -d 8086:107d -xxxx` (Linux) shows the full configuration space
  (VID/DID/class code/DSN).
- The e1000e driver (Linux `e1000e.ko` / Windows `e1e6032.sys`) loads normally;
  link up at 1000 Mb/s full duplex.
- PCILeech host-side connection works as usual (FPGA DMA is handled by the TLP
  engine and is independent of the NIC driver).

## Disclaimer

This firmware is provided for research and authorized security testing only.
Unauthorized use to bypass anti-cheat or security mechanisms may violate
service terms and applicable law. Use at your own risk.

---

# 中文说明

## 概述

本固件基于 PCILeech-FPGA，将 FPGA 模拟为一款外观真实的
**Intel PRO/1000 PT Desktop Adapter（82572EI）**，包含完整的 MMIO 寄存器模拟，
使 Intel 原版 e1000e 驱动能够正常初始化。

## 特性

- **完整的 e1000e（82572EI）MMIO 寄存器模拟** —— CTRL / CTRL_DUP / STATUS / EERD /
  MDIC / CTRL_EXT / ICR~IMC / RCTL / TCTL / 收发 ring 寄存器 / RAL0 / RAH0 / FWSM /
  SW_FW_SYNC / PBA / PHY_CTRL / RLPML 等。
- **拟真 EEPROM（NVM）** —— Intel OUI MAC `00:1B:21:12:34:56`、设备/子系统 ID、
  合法校验和（`0xBABA`）。
- **PHY（Marvell 88E1111）link up 模拟**，通过 MDIC 访问。
- **PCIe 身份** —— VID/DID `8086:107D`、类码 `0x020000`、BAR0 128KB、DSN 已设置。
- **内置防粘贴（anti-paste）保护措施**，防止未授权复制与高价倒卖本固件。
- **可在 EAC（Easy Anti-Cheat）环境中顺利通过**（当前版本已验证）。

## 支持的板卡

| 板卡 | 生成脚本 | 输出 |
|---|---|---|
| TBX4 100T | `generate – 100T.bat` | `pcileech_zdma_100t_fpga0.bin` |
| Captain 75T / Enigma X1 | `generate – captain - 75T.bat` | `pcileech_captain_75T.bin` |

## 构建（Vivado 2023.2）

1. 安装 Xilinx Vivado WebPACK 2023.2 或更高版本。
2. 打开 Vivado Tcl Shell，`cd` 到本目录（路径用正斜杠）。
3. 运行对应板卡的生成脚本（如 `generate – 100T.bat`）。
4. 运行 `source vivado_build_100t.tcl -notrace`（Captain 板卡用
   `vivado_build_captain_75T.tcl`）编译 bitstream（约 1 小时）。
5. 将生成的 `.bin` 烧录到 FPGA。

## 验证

- 目标机显示 `Intel Corporation 82572EI Gigabit Ethernet Controller
  (PRO/1000 PT Desktop Adapter)`。
- Linux 下 `lspci -d 8086:107d -xxxx` 可查看完整配置空间（VID/DID/类码/DSN）。
- e1000e 驱动（Linux `e1000e.ko` / Windows `e1e6032.sys`）正常加载，
  链路 Up、1000Mb/s 全双工。
- PCILeech 主机侧按原流程连接（FPGA 的 DMA 由 TLP 引擎完成，与网卡驱动无关）。

## 免责声明

本固件仅供研究与授权安全测试使用。未经授权用于绕过反作弊或安全机制可能违反
服务条款与法律，使用风险自负。
