# Poker (Texas Hold'em)

4-player Texas Hold'em with private hole-card screens, wireless communication, and floppy-disk chip wallets.

## Hardware

### Dealer Computer (center of table)

| Component | Requirement |
|-----------|-------------|
| Monitor | 2 wide × 5 tall (or larger), attached to the computer. Text scale 0.5 set automatically. |
| Wireless Modem | Required. Listens on channel 10, broadcasts on channel 11. |

The dealer monitor shows community cards, pot, player status, and the START / NEXT HAND button.

### Player Computer (one per seat, up to 4)

| Component | Requirement |
|-----------|-------------|
| Corner Monitor | Attached to the **top** side of the computer. Shows actions, betting controls, and game info. |
| Foot Monitor *(optional)* | Attached to the **left** or **right** side. Shows hole cards large. Falls back to the corner monitor if absent. |
| Wireless Modem | Required. |
| Disk Drive | Any side. Player inserts their wallet disk here. |

## Install

**Dealer computer:**
```
wget https://raw.githubusercontent.com/ob-105/CCCasino/main/install.lua install
install
```
Select **2. Poker Dealer**, reboot.

**Each player computer:**
```
wget https://raw.githubusercontent.com/ob-105/CCCasino/main/install.lua install
install
```
Select **3. Poker Player**, enter this seat's number (1–4), reboot.

## Playing

1. Each player inserts their wallet disk into their computer's disk drive before the game starts. Their chip balance loads automatically.
2. On the dealer monitor, touch **START GAME** (or press `S` on the keyboard).
3. Players act by touching buttons on their corner monitor — **FOLD**, **CHECK**, **CALL**, or **RAISE**.
4. After each hand, chip balances are automatically written back to each player's disk.
5. To leave, touch **LEAVE TABLE** (purple button, bottom of corner monitor) during the waiting or showdown phase. The final balance is saved to disk.

## Game Rules

- Blinds: 5 (small) / 10 (big)
- Starting chips: taken from wallet disk, falls back to 500 if no disk
- Standard Texas Hold'em streets: Pre-Flop → Flop → Turn → River → Showdown
- Split pots handled automatically

## Configuration

Open `dealer.lua` and adjust these values at the top:

```lua
local NUM_PLAYERS = 4    -- number of seats (2-4)
local SMALL_BLIND = 5
local BIG_BLIND   = 10
```

Change `NUM_PLAYERS` to match how many player computers you've set up.

## Channels

| Channel | Purpose |
|---------|---------|
| 10 | Dealer listens (players send to this) |
| 11 | Dealer broadcasts (players listen on this) |

All computers must be on the same wireless network (within modem range).
