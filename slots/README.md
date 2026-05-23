# Slot Machine

A three-reel slot machine with animated spinning reels and a built-in payout table.

## Hardware

| Component | Requirement |
|-----------|-------------|
| Monitor | Any size, any side. Taller monitors show the payout table. |
| Disk Drive | Any side. Player inserts their wallet disk to play. |

## Install

```
wget https://raw.githubusercontent.com/ob-105/CCCasino/main/install.lua install
install
```

Select **4. Slots Machine**, then reboot.

## Playing

1. Insert wallet disk into the disk drive.
2. Tap a **bet amount** (1 / 5 / 10 / 25 / 50 / 100 / 500 chips).
3. Tap **SPIN**. The reels animate and stop left to right.
4. Winnings (if any) are added to your balance immediately.
5. Balance is saved to disk after every spin.
6. Tap **LEAVE TABLE** when done — balance is saved and the program exits.

## Symbols & Payouts

| Result | Payout |
|--------|--------|
| 7 – 7 – 7 | ×50 **JACKPOT** |
| BAR – BAR – BAR | ×20 |
| BEL – BEL – BEL | ×10 |
| CHR – CHR – CHR | ×8 |
| LEM – LEM – LEM | ×5 |
| Any two 7s | ×5 |
| Any matching pair | ×2 |
| Any cherry (CHR) | ×1 (stake back) |
| No match | ×0 (lose bet) |

Payout is multiplied by your current bet size. The 7 is the rarest symbol; lemons and cherries are most common.

## Notes

- Playing without a disk is allowed but the balance is not saved when you leave.
- If a disk is inserted while the machine is idle, the balance updates automatically.
