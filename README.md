# OutRunners Link (alpha test build)
Modification of the original core using AI, specifically Claude.

### Introduction

The original source code for this core can be found at the following link:  
https://github.com/meathax/s32multi

The version available in the **Releases** section is a modified version of the core that allows **OutRunners** to be played using **two MiSTer FPGA systems connected together** with a modified USB 3.0 male-to-male cable.

**IMPORTANT:** The cable must have the **5V power line disconnected**. If you use a standard cable with the 5V power pin still connected, you may damage your MiSTer FPGA systems.

**WARNING:** I take no responsibility for any damage. Before connecting the two systems, make absolutely sure that the **5V power connection in the USB 3.0 cable has been disconnected**.

Read the guide in PDF format before using the core: https://github.com/bonna79/s32multi-mycore/blob/main/OutRunners_Link_two_MiSTer_Guide_EN.pdf

I personally used a **30 cm USB 3.0 cable** and played for several hours using two FPGA systems without any issues.

My setup consists of:

- **Master:** standard MiSTer FPGA
- **Slave:** SuperStation One FPGA

The USB 3.0 cable must be connected to the **User I/O port on both systems**, which is the same port normally used for **SNAC connections**.


Two MiSTer FPGAs linked through the USER port, playing Sega **OutRunners** (Multi 32 board) like two linked cabinets.

Based on Meathax's `s32multi` core (GPL). Fork with the link code: https://github.com/bonna79/s32multi-mycore

- Source commit: `4fc543f` (the core's build date is shown in the OSD)
- `outrunners.rbf` md5: `5da6d67d9c9b9594b859f3c413dfc1b5` (4592880 bytes)
- ROMs are **not** included. Use the same OutRunners ROM set that works with the stock MRA.

## What this is (and is not)

The original twin cabinets talk through a Sega comm board (Z80 + data link controller + 2 KB dual-port RAM) that the game sees as shared RAM at `0x800000` plus two flags (CN/FG) at `0x801000/0x801002`. This core emulates that board at register level, like MAME's `s32comm` simulation, and moves the data between the two MiSTers over a **custom** serial protocol. It is not compatible with real cabinets.

Exactly **two** machines (master + slave). Relay/ISDN mode and 3-4 cabinet rings are not supported.

## Status

Tested:
- The game's *NETWORK CHECK* reaches `COMMUNICATION SUCCESS`, with `THIS MACHINE ID IS 2` / `THIS MACHINE IS SLAVE`.
- The link stays up for 30+ minutes (LED shows stage 7, no drop).

Not verified yet: the opponent's car moving in a real race (the frames are tested in simulation only). Reports welcome.

## Hardware

- Two MiSTers with a USER port (tested: a SuperStation One with its SuperDock, SNAC bypass ON, and a standard MiSTer).
- One short **USB 3.0 Type-A to Type-A** cable (tested at 30 cm) with **VBUS (pin 1) not connected**. Never join the 5 V rails of two MiSTers. This is the same cable used by the PlayStation link-cable alpha (Kuba-J's PSX_MiSTer_link_cable), which also validated it.
- Both machines use the same pins; the cable's crossed SuperSpeed pairs do the rest:
  - TX on `USER_IO[2]` (USB pin 8) arrives at `USER_IO[5]` (USB pin 5) of the other machine.
  - RX on `USER_IO[5]`.
  - The port is open-drain (a 1 releases the pin); the FPGA weak pull-ups are enabled.
- No SNAC device may be attached.

## Install

```
/media/fat/_Arcade/OutRunners (World) Link.mra
/media/fat/_Arcade/OutRunners (US) Link.mra
/media/fat/_Arcade/cores/outrunners.rbf        <- only ONE file starting with "outrunners"
```
The ROM zips go where the stock MRA expects them (`games/mame/`). The MRAs are the stock ones with only the core name changed.

## Setup (both machines)

OSD:
- `Cabinet Link` = **Network**
- `Link Baud` = **250k** (must be the same on both)
- `Link Test` = **Off**
- `Comm RAM Clear` = **Once**
- `Comm Hi Byte` = **FF**
- `Link Role` and `Cabinet ID` are ignored (the game decides)

In the game, Test menu -> *Network Assignments*:
- `Communication` = Network
- `Privilege Mode` = **Master** on one machine and **Slave** on the other
- `Cabinet ID#` = 1 on the master, 2 on the slave
- exit the menu (the settings are stored in the game's EEPROM, per MRA file name)

Then Reset both machines from the OSD within a few seconds of each other. Both should show the *NETWORK CHECK* screen and `COMMUNICATION SUCCESS`.

## LED guide (I/O board HDD LED)

With `Link Test = Off`, the LED counts the furthest handshake stage reached, as N flashes, a pause, and repeat. It resets with the OSD Reset.

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

`Link Test = On` (game stand-alone): the LED is steady while valid frames arrive from the other machine. Use it to check the cable, the pins and the baud rate.

## Please report

- Game region and MRA used, which machine is master and which is slave
- What each screen shows after Reset, and the LED stage on each machine
- In a race: does the other car appear, does it follow the other player's steering and speed, any stutter or desync
- Anything that drops the link (LED flickers fast)

## Credits and license

Core by Meathax (`s32multi`), link code in the fork above. The source of this build is the commit named at the top; the repository's LICENSE file applies (GPL).


