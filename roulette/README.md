# Roulette

European roulette (single zero, numbers 0–36) with a full touch-screen betting board.

## Hardware

| Component | Requirement |
|-----------|-------------|
| Monitor | **2 blocks wide** minimum at 0.5 text scale (~51 chars). Taller is better for the result area. |
| Disk Drive | Any side. |

> A single 1×1 monitor is too narrow for the number grid. Place two monitor blocks side by side.

## Install

```
wget https://raw.githubusercontent.com/ob-105/CCCasino/main/install.lua install
install
```

Select **5. Roulette Table**, then reboot.

## Playing

1. Insert wallet disk into the disk drive.
2. Tap a **chip size** at the top of the screen (1 / 5 / 10 / 25 / 50 / 100).
3. Tap cells on the betting board to place bets. Each tap adds one chip of the selected size. Tap the same cell multiple times to stack bets. Cells with a bet on them turn **yellow**.
4. Tap **SPIN** to play. The total bet is deducted from your balance and the result is shown.
5. Tap **CLEAR** to remove all pending bets without spinning.
6. Tap **LEAVE TABLE** when done — balance is saved and the program exits.

## Betting Board Layout

```
[ 0 ] [ 3 ][ 6 ][ 9 ]…[36] [C3]
      [ 2 ][ 5 ][ 8 ]…[35] [C2]
      [ 1 ][ 4 ][ 7 ]…[34] [C1]
      [ 1st 12 ][ 2nd 12 ][ 3rd 12 ]
      [1-18][EVEN][RED][BLK][ODD][19-36]
```

- **Red numbers:** 1 3 5 7 9 12 14 16 18 19 21 23 25 27 30 32 34 36
- **Green:** 0 only
- **Black:** all others

## Payouts

| Bet | Pays |
|-----|------|
| Straight-up (single number) | 35:1 |
| Red / Black | 1:1 |
| Odd / Even | 1:1 |
| 1–18 / 19–36 | 1:1 |
| 1st / 2nd / 3rd Dozen | 2:1 |
| Column (C1 / C2 / C3) | 2:1 |

Zero (0) loses all outside bets. Straight-up bet on 0 pays normally at 35:1.

## Notes

- You can place multiple different bets in the same spin — the payout from each is calculated independently.
- Playing without a disk is allowed but the balance is not saved when you leave.
