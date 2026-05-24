# Roulette (Multi-Player)

European roulette (single zero, 0–36) with a central dealer wheel computer and individual player betting terminals. Up to 6 players can bet simultaneously — each on their own screen with their own disk.

## How It Works

1. The **dealer computer** sits at the center of the roulette table. The operator uses it to open betting and trigger spins.
2. Each **player terminal** is a separate computer at each seat. Players insert their wallet disk, place bets on their touch-screen board, then press **READY**.
3. The dealer wheel **auto-spins** once all connected players press READY, or the operator presses **FORCE SPIN**.
4. The winning number is announced. Each player terminal calculates its own payout independently and writes the result back to the player's disk.

## Hardware

### Dealer Computer (center of table)

| Component | Requirement |
|-----------|-------------|
| Monitor | Any size, any side. 2+ blocks wide recommended. |
| Wireless Modem | Required. Listens on channel 20, broadcasts on 21. |

The dealer monitor shows the animated spinning wheel strip, the result, player ready status, and control buttons.

### Player Terminal (one per seat, up to 6)

| Component | Requirement |
|-----------|-------------|
| Monitor | **2 blocks wide minimum** at 0.5 text scale (~51 chars). |
| Disk Drive | Any side. Player inserts their wallet disk. |
| Wireless Modem | Required. |

## Install

**Dealer computer:**
```
wget https://raw.githubusercontent.com/ob-105/CCCasino/main/install.lua install
install
```
Select **5. Roulette Dealer**, reboot.

**Each player terminal:**
```
wget https://raw.githubusercontent.com/ob-105/CCCasino/main/install.lua install
install
```
Select **6. Roulette Player**, enter this seat's number (1–6), reboot.

## Dealer Controls

| Button | Effect |
|--------|--------|
| **OPEN BETTING** | Starts a new round — players can now place bets |
| **FORCE SPIN** | Spins immediately, even if not all players are ready |
| **CLOSE BETS** | Same as FORCE SPIN — locks bets and spins |

## Playing (Player Terminal)

1. Insert wallet disk into the disk drive.
2. Wait for the dealer to open betting — the screen shows **"Place your bets!"**
3. Tap a chip size at the top (1 / 5 / 10 / 25 / 50 / 100).
4. Tap cells on the betting board to stack bets. Cells with bets turn **orange**.
5. Tap **READY** — your balance is deducted immediately and bets are locked.
6. Tap **CANCEL READY** to take your bets back and adjust.
7. When the wheel stops, the winning number highlights on your board and your payout is shown.
8. Tap **LEAVE TABLE** at any time — balance is saved to disk.

## Betting Board Layout

```
[ 0 ] [ 3 ][ 6 ][ 9 ]…[36] [C3]
      [ 2 ][ 5 ][ 8 ]…[35] [C2]
      [ 1 ][ 4 ][ 7 ]…[34] [C1]
      [ 1st 12 ][ 2nd 12 ][ 3rd 12 ]
      [1-18][EVEN][RED][BLK][ODD][19-36]
```

## Payouts

| Bet | Pays |
|-----|------|
| Straight-up (single number) | 35:1 |
| Red / Black | 1:1 |
| Odd / Even | 1:1 |
| 1–18 / 19–36 | 1:1 |
| 1st / 2nd / 3rd Dozen | 2:1 |
| Column (C1 / C2 / C3) | 2:1 |

Zero (0) loses all outside bets. Straight-up on 0 pays 35:1 as normal.

## Channels

| Channel | Purpose |
|---------|---------|
| 20 | Dealer listens (players send bets here) |
| 21 | Dealer broadcasts (players listen here) |

All computers must be within wireless modem range of each other.
