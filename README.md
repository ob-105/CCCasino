# CCCasino

A full casino system for Minecraft using CC:Tweaked. Players trade resources for a signed floppy-disk wallet, then use it at any game machine. Chips are written back to the disk after every round — and the disk is cryptographically signed so players can't edit their balance at home.

## Games

| Game | Folder | Players |
|------|--------|---------|
| Cashier | `cashier/` | Operator-run |
| Poker (Texas Hold'em) | `poker/` | 2–4 |
| Slot Machine | `slots/` | 1 |
| Roulette | `roulette/` | 1 |

## Quick Install

Run this on each CC:Tweaked computer:

```
wget https://raw.githubusercontent.com/ob-105/CCCasino/main/install.lua install
install
```

Select the computer's role, reboot, done.

## First-Time Setup

1. Install on all casino computers using the command above.
2. On **every** casino computer, open `/casino/lib/wallet.lua` and change the line:
   ```lua
   local SECRET = "CHANGE_ME_to_a_long_unique_secret_key_abc123xyz789"
   ```
   to a long random string **that is the same on every machine**. This is what prevents players from forging chip balances.
3. Reboot each computer — they auto-start their assigned game.

## How the Wallet Works

- Players bring a blank floppy to the **Cashier**. The operator receives their resources, enters the player's name and chip amount, and issues the disk.
- The disk contains a `wallet.dat` file with a cryptographic signature. Editing the balance without the secret key breaks the signature — the disk is rejected at every game machine.
- After every hand/spin, the balance is automatically written back to disk.
- When the player wants to cash out, they return to the Cashier. The operator reads the balance, gives resources, and wipes the disk.

## File Layout

```
install.lua          ← one-command installer
lib/
  wallet.lua         ← shared crypto library (on every casino computer)
cashier/
  startup.lua        ← cashier terminal
poker/
  dealer.lua         ← dealer computer (center of table)
  player.lua         ← player computer (one per seat)
slots/
  startup.lua        ← slot machine
roulette/
  startup.lua        ← roulette table
```
