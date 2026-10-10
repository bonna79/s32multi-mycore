# OutRunners Link (alpha test build)
Modification of the original core using AI, specifically Claude.

### Introduction

The original source code for this core can be found at the following link:
https://github.com/meathax/s32multi

The version available in the **Releases** section is a modified version of the core that allows **OutRunners** to be played using **two MiSTer FPGA systems connected together** with a modified USB 3.0 male-to-male cable.

> **IMPORTANT:** The cable must have the **5V power line (pin 1, VBUS) disconnected**. If you use a standard cable with the 5V power pin still connected, you may damage your MiSTer FPGA systems.
>
> **Always check with a multimeter before connecting:** the 5V pin must not carry 5V, and **no pin may get more than 3.3V**.

**WARNING:** I take no responsibility for any damage. Before connecting the two systems, make absolutely sure that the **5V power connection in the USB 3.0 cable has been disconnected**.

Read the guide in PDF format before using the core:
- English: https://github.com/bonna79/s32multi-mycore/blob/main/OutRunners_Link_two_MiSTer_Guide_EN_v2.pdf
- Italiano: https://github.com/bonna79/s32multi-mycore/blob/main/Guida_OutRunners_Link_due_MiSTer_v2.pdf

Technical notes on how the link works (IT/EN; some points are hypotheses still to verify): https://github.com/bonna79/s32multi-mycore/blob/main/OutRunners_Link_NET_notes_IT_EN.txt

Two MiSTer FPGAs linked through the USER port, playing Sega **OutRunners** (Multi 32 board) like two linked cabinets.

Based on Meathax's `s32multi` core (GPL). Fork with the link code: https://github.com/bonna79/s32multi-mycore

- Source commit: `4fc543f`, tag `link-ok-20261007` (the core's build date is shown in the OSD)
- `outrunners.rbf` md5: `5da6d67d9c9b9594b859f3c413dfc1b5` (4592880 bytes), in `OutRunnersLink_20261007.zip` on the **Releases** page
- MRA: [`releases/OutRunners (US) Net Link.mra`](https://github.com/bonna79/s32multi-mycore/blob/main/releases/OutRunners%20%28US%29%20Net%20Link.mra) (the stock US MRA with only `<rbf>` changed to `outrunners`)
- ROMs are **not** included. Use the same OutRunners ROM set that works with the stock MRA.

> The `releases/` folder also holds the **original** core `Arcade-SegaSystem32Multi_20260823.rbf` and the stock MRAs (`OutRunners.mra`, `_alternatives/`), **without** the link. To play linked use only `OutRunners (US) Net Link.mra` from that folder and `outrunners.rbf` from the **Releases** page.

## What this is (and is not)

The original twin cabinets talk through a Sega comm board (Z80 + data link controller + 2 KB dual-port RAM) that the game sees as shared RAM at `0x800000` plus two flags (CN/FG) at `0x801000/0x801002`. This core emulates that board at register level, like MAME's `s32comm` simulation, and moves the data between the two MiSTers over a **custom** serial protocol. It is not compatible with real cabinets.

Exactly **two** machines (master + slave). Relay/ISDN mode and 3-4 cabinet rings are not supported.

## Status

Tested and working:
- The game's *NETWORK CHECK* reaches `COMMUNICATION SUCCESS` (`THIS MACHINE ID IS 1` master / `2` slave).
- **Full races with both cars on track**: each player sees the other's car.
- Link stable for 30+ minutes and several hours of play (LED at stage 7, no drops).
- **Standard MiSTer (master) + SuperStation One (slave)**, 30 cm cable.
- **Multisystem2 + SuperStation One**, 30 cm cable **plus an about 2 m USB 3.0 extension**, Link Baud 250k.

Still alpha: reports are welcome (see below).

## Hardware

- Two MiSTers with a USER port. Tested:
  - a standard MiSTer with I/O board;
  - a **SuperStation One** with its SuperDock, **SNAC Bypass ON**;
  - a **Multisystem2 Analogue** with Heber's **SNAC Classic Cartridge** (see below).
- One **USB 3.0 Type-A to Type-A** cable with **VBUS (pin 1) not connected**. Never join the 5 V rails of two MiSTers. This is the same cable used by the PlayStation link-cable alpha (Kuba-J's PSX_MiSTer_link_cable), which also validated it.
- Optional: a normal **USB 3.0 male-to-female extension** (tested at about 2 m). It does not need modifying, as long as the 5 V line is interrupted in the cable. It must be **USB 3.0** (9 contacts): a USB 2.0 extension lacks the wires the link uses.
- Both machines use the same pins; the cable's crossed SuperSpeed pairs do the rest:
  - TX on `USER_IO[2]` (USB pin 8) arrives at `USER_IO[5]` (USB pin 5) of the other machine.
  - RX on `USER_IO[5]`.
  - The port is open-drain (a 1 releases the pin); the FPGA weak pull-ups are enabled.
- No SNAC device may be attached.

### Multisystem2: SNAC Classic Cartridge switches

Factory setting is all switches on the **left (5 V)**: that is **not** right for the link. Set them with the Multisystem2 **off**:

| Switch | Position | Label on the board | Why |
|---|---|---|---|
| SW1 | **RIGHT** | `+3V3` (Signal Lvl) | 3.3 V signals; on the left they would be 5 V and reach the other machine |
| SW2 | **RIGHT** | `+3V3` (Power Lvl) | lowest supply; with pin 1 interrupted it does not reach the other machine |
| SW3 | **LEFT** | `IO6` (SNAC) | pin 9 stays a signal; on the right it would become a 3.3 V supply |

The cartridge works only on the Multisystem2 **Analogue** (not the Digital).

## Safety checks with a multimeter (mandatory)

Multimeter on DC volts. Repeat the checks every time you change a cable, an extension, a cartridge or a machine.

1. **No 5 V through the cable chain.** Plug only one end of the full chain (cable + extension) into a USB charger. On the free end, measure every pair of the 4 long contacts: always **0 V**.
2. **No pin above 3.3 V on each machine.** With the chain connected to one powered machine only, black probe on ground (pin 4), red probe on every other contact: every reading between **0 and 3.3 V**, pin 1 at **0 V**. Repeat on the other machine.

What we measured on both the SuperStation One and the Multisystem2: pin 1 = 0 V, pin 4 (ground) = 0 V, pins 2, 3, 5, 6, 7, 8, 9 = about 3.2 V.

Connect the two machines to each other only with both powered off.

## Install

```
/media/fat/_Arcade/OutRunners (US) Net Link.mra   <- from the releases/ folder
/media/fat/_Arcade/cores/outrunners.rbf           <- from the Releases page; only ONE file starting with "outrunners"
```
Same files on both machines. The ROM zips go where the stock MRA expects them (`games/mame/`): the MRA uses `orunners.zip` / `orunnersu.zip`. The MRA is the stock US one with only the core name changed. Keep its file name: the game's network settings are saved per MRA file name.

## Setup (both machines)

OSD:
- `Cabinet Link` = **Network**
- `Link Baud` = **250k** (must be the same on both; also works with the 2 m extension)
- `Link Test` = **Off**
- `Comm RAM Clear` = **Once**
- `Comm Hi Byte` = **FF**
- `Link Role` and `Cabinet ID` are ignored (the game decides)

In the game, Test menu -> *Network Assignments*:
- `Communication` = Network
- `Privilege Mode` = **Master** on one machine and **Slave** on the other
- `Cabinet ID#` = 1 on the master, 2 on the slave
- exit the menu (the settings are stored in the game's EEPROM, per MRA file name)

Start `OutRunners (US) Net Link` on both machines, then Reset both machines from the OSD within a few seconds of each other. Both should show the *NETWORK CHECK* screen and `COMMUNICATION SUCCESS`.

## LED guide (I/O board HDD LED)

With `Link Test = Off`, the LED counts the furthest handshake stage reached, as N flashes, a pause, and repeat. It resets with the OSD Reset. On the SuperStation the LED may not be visible: watch the screen.

| Flashes | Meaning |
|---|---|
| 0 | the game has not enabled the comm board |
| 1 | board enabled (CN) |
| 2 | game wrote the "V70" signature and we answered "Z80" |
| 3 | the game read the "Z80" reply |
| 4 | the game wrote its node mode |
| 5 | valid node mode found, HELLO frames start |
| 6 | a frame from the other machine arrived |
| 7 | link up |

Fast flicker: the link had been up and no frame arrived for about 3 seconds.

`Link Test = On` (game stand-alone): the LED is steady while valid frames arrive from the other machine. Use it to check the cable, the extension, the pins and the baud rate.

## Please report

- Game region and MRA used, which machine is master and which is slave
- Which hardware (MiSTer, SuperStation, Multisystem2...) and cable length / extension
- What each screen shows after Reset, and the LED stage on each machine
- In a race: does the other car follow the other player's steering and speed, any stutter or desync
- Anything that drops the link (LED flickers fast)

## Credits and license

Core by Meathax (`s32multi`), link code in the fork above. SNAC Classic Cartridge for Multisystem2 by Heber Ltd. The source of this build is the commit named at the top; the repository's LICENSE file applies (GPL).
