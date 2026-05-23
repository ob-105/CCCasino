# Cashier Terminal

The cashier is where players exchange resources for chips and cash out when they're done. An operator (you, the casino owner) runs this computer.

## Hardware

| Component | Requirement |
|-----------|-------------|
| Monitor | Any size, any side. Touch-screen recommended. |
| Disk Drive | Any side. |
| Modem | Not required. |

## Install

```
wget https://raw.githubusercontent.com/ob-105/CCCasino/main/install.lua install
install
```

Select **1. Cashier Terminal**, then reboot.

## Operating the Cashier

### Issuing a new wallet (player buys in)

1. Have the player put a **blank floppy disk** into the disk drive.
2. Tap **ISSUE NEW WALLET** on the monitor.
3. Type the player's name on the computer keyboard, press **Enter**.
4. Enter the chip amount using the keyboard or tap a quick-amount button (+100, +500, +1000, +5000), then tap **CONFIRM**.
5. Hand the disk to the player.

### Topping up an existing wallet

1. Insert the player's disk into the drive.
2. Tap **ADD CHIPS**.
3. Enter the amount to add, tap **CONFIRM**.

### Cashing out (player leaves the casino)

1. Insert the player's disk into the drive. The balance is shown on screen.
2. Tap **CASH OUT**.
3. **Give the player their resources first**, then tap **CONFIRM WIPE**.
4. The disk is cleared and returned to the player (or kept for re-use).

## Notes

- The operator handles resource exchange manually — give/receive items before confirming.
- A disk from a different casino (different `SECRET`) will show "tampered or foreign disk" and cannot be topped up or cashed out here. That's intentional.
- Removing the disk at any time safely resets the screen back to the home view.
