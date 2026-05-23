# CCCasino — Project Plan

---

## Currency & Economy

**Numismatics** coins as the casino currency (copper → iron → gold → diamond → netherite).

- Players insert coins into a Numismatics vault/bank linked to a CC computer via peripheral
- Each machine reads the player's balance before allowing play
- Winnings are dispensed automatically via the same vault
- Consider a central "cashier" terminal where players exchange items for coins and back

---

## Games

### Slot Machine

- Three reels displayed on a CC monitor (ASCII art symbols: cherry, bar, 7, diamond, etc.)
- Animated spin effect — cycle through symbols quickly then slow to a stop
- Reel results are RNG-determined server-side in Lua (no client-side cheating)
- Payout table shown on a side monitor
- Variable bet sizes (1x, 5x, 10x multiplier on the coin insert)
- **Create integration idea:** physical spinning reels using Create mechanical rotation + a redstone signal from the CC computer to trigger/stop them, purely decorative alongside the monitor display

### Blackjack

- Standard rules: player vs dealer, goal is 21
- Card state tracked in a Lua table — one deck (52 cards), shuffle on new shoe, burn a card
- Track which cards have been dealt so the deck depletes realistically; reshuffle when ~75% dealt
- Dealer AI: hits on soft 16 and below, stands on hard 17+
- Actions: Hit, Stand, Double Down, Split (if pair)
- Display: large monitor showing player hand, dealer hand (one card face-down until reveal), chip count
- Multiple seats possible if you run one CC computer per terminal networked via modem to a central dealer server

### Roulette

- European single-zero wheel (better odds for players, more fun)
- Betting board on one monitor, wheel result on another
- Bet types: straight up, red/black, odd/even, dozens, columns, splits, streets
- Spin result is a random number 0-36; color/odd-even/dozen all derived from that
- Animate the result on the monitor (cycle through numbers quickly before landing)
- Timer countdown for placing bets before the spin locks in

### Video Poker (addition)

- Simpler to build than full poker, great filler game
- Player is dealt 5 cards, chooses which to hold, draws replacements
- Payout based on final hand (pair of Jacks+, two pair, straight, flush, etc.)
- Single monitor terminal, low overhead

### Horse Racing (addition -- Create integration)

- 4-6 "horses" (minecarts or Create contraptions on tracks)
- Players bet on a horse at a terminal before the race starts
- CC computer triggers the race via redstone signal, randomizes speeds/outcomes
- Physical track with contraption movement visible to spectators
- Great for a social/spectator area of the casino floor

---

## Networking & Backend

- Use CC wireless modems + a **central server computer** that handles all balances and game state
- Each game terminal is a client that sends requests (`requestBet`, `requestPayout`, `getBalance`) to the server
- Central server logs all transactions (file I/O to a datastore on the server computer)
- This prevents players from exploiting individual terminals

---

## Physical Layout Ideas

- **Entrance hall** -- cashier desk (Numismatics exchange terminal)
- **Slots row** -- 4-6 slot machines along a wall
- **Table game floor** -- Blackjack tables (2-3), Roulette table, Video Poker terminals
- **Race room** -- separate room with the horse track visible through glass
- **High roller room** -- locked behind a door, higher minimum bets

---

## Visual / Atmosphere

- CC Speakers on each machine for sound effects (coin drop, win jingle, card deal clicks)
- Large monitor marquee at the entrance cycling casino name + jackpot amount
- Redstone lighting -- colored lamps, neon-style borders using Create or vanilla dye
- Create fans/flywheels as decorative spinning machinery in the background

---

## Rough Build Order

1. Central server + currency system (Numismatics integration)
2. Slot machine (simplest game logic, good for testing the payment flow)
3. Blackjack (most code complexity, do this before roulette)
4. Roulette
5. Video Poker
6. Horse Racing (most build effort, save for last)
7. Layout + atmosphere pass

---

## Notes & Decisions

- Decide on minimum/maximum bets per game
- **House edge: always a subtle baked-in advantage** -- house profits long-term but players won't feel it game-to-game; not so high that people lose constantly, not zero so players win all the time
  - **Slots** -- payout table pays slightly less than true odds (e.g. jackpot hits 1-in-200 but pays 150x, not 200x); target ~90-95% return-to-player
  - **Blackjack** -- dealer rules (stand on hard 17+) already give ~0.5-1% edge naturally; no extra tweaking needed
  - **Roulette** -- European single-zero gives 2.7% edge inherently; no extra needed
  - **Video Poker** -- tune payout table so return-to-player is ~95-97%, not 100%
  - **Horse Racing** -- displayed odds are slightly worse than each horse's true win probability
- Multiplayer: do multiple players share one Blackjack table or is each terminal solo?
- Anti-cheat: central server should validate all bets and payouts, never trust the terminal

