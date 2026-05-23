-- poker/player.lua
-- Texas Hold'em player terminal for CCCasino
-- Hardware: 1h×2w monitor, wireless modem
-- Run: player.lua <player_number>   (1..4)

local pid = tonumber(arg and arg[1])
assert(pid, "Usage: player.lua <player_number>")

local BCAST_CH  = 11  -- listen for dealer broadcasts
local DEALER_CH = 10  -- send to dealer

math.randomseed(os.epoch("utc"))

-- ── Peripherals ──────────────────────────────────────────────────────────────
local mon = peripheral.find("monitor")
assert(mon, "Attach a 1h×2w monitor to this computer")
mon.setTextScale(0.5)
local W, H = mon.getSize()

local modem = peripheral.find("modem")
assert(modem, "Attach a wireless modem to this computer")
modem.open(BCAST_CH)

-- ── Player state ─────────────────────────────────────────────────────────────
local state = {
    hand        = {},         -- {card,card}
    community   = {},
    phase       = "waiting",
    chips       = 500,
    pot         = 0,
    bets        = {},
    active      = {},
    turn        = 0,
    call_amount = 0,
    valid_actions = {},
    result_lines  = {},
    all_hands     = {},       -- revealed hands at showdown
    current_bet   = 0,
}

local raise_input = ""   -- digits typed for a raise amount
local entering_raise = false

-- ── Drawing helpers ──────────────────────────────────────────────────────────
local SUIT_SYM = {H="\xe2\x99\xa5",D="\xe2\x99\xa6",C="\xe2\x99\xa3",S="\xe2\x99\xa0"}
local SUIT_COL = {H=colors.red,D=colors.red,C=colors.black,S=colors.black}

local function cls(bg)
    mon.setBackgroundColor(bg or colors.black)
    mon.clear()
end

local function mprint(x,y,txt,fg,bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(x,y)
    mon.write(txt)
end

local function hfill(y,bg,fg,txt)
    mon.setBackgroundColor(bg)
    mon.setCursorPos(1,y)
    mon.write(string.rep(" ",W))
    if txt then
        mon.setTextColor(fg or colors.white)
        mon.setCursorPos(math.floor((W-#txt)/2)+1,y)
        mon.write(txt)
    end
end

-- Draw a card: 7 wide × 5 tall (bigger, since player monitor has space)
local function draw_card(x,y,card,face_up)
    if not card then
        -- empty slot
        for dy=0,4 do
            mon.setBackgroundColor(colors.gray)
            mon.setTextColor(colors.lightGray)
            mon.setCursorPos(x,y+dy)
            if dy==0 then mon.write("\xe2\x94\x8c\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x90")
            elseif dy==4 then mon.write("\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x98")
            else mon.write("\xe2\x94\x82     \xe2\x94\x82") end
        end
        return
    end
    if not face_up then
        for dy=0,4 do
            mon.setBackgroundColor(colors.blue)
            mon.setTextColor(colors.cyan)
            mon.setCursorPos(x,y+dy)
            if dy==0 then mon.write("\xe2\x95\x94\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x97")
            elseif dy==4 then mon.write("\xe2\x95\x9a\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x9d")
            else mon.write("\xe2\x95\x91\xe2\x96\x93\xe2\x96\x93\xe2\x96\x93\xe2\x96\x93\xe2\x96\x93\xe2\x95\x91") end
        end
        return
    end
    local sc = SUIT_COL[card.s] or colors.black
    local sym = SUIT_SYM[card.s] or "?"
    local r   = card.r or "?"
    local mid = r..sym   -- e.g. "A♥" or "10♦"
    -- pad to 5 chars
    while #mid < 5 do mid = mid.." " end

    mon.setBackgroundColor(colors.white); mon.setTextColor(sc)
    mon.setCursorPos(x,y);   mon.write("\xe2\x95\x94\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x97")
    mon.setCursorPos(x,y+1); mon.write("\xe2\x95\x91"..r.."   \xe2\x95\x91")
    mon.setCursorPos(x,y+2); mon.write("\xe2\x95\x91  "..sym.."  \xe2\x95\x91")
    mon.setCursorPos(x,y+3); mon.write("\xe2\x95\x91   "..r.."\xe2\x95\x91")
    mon.setCursorPos(x,y+4); mon.write("\xe2\x95\x9a\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x9d")
end

-- ── Button layout ─────────────────────────────────────────────────────────────
-- Buttons occupy the bottom row(s)
-- Divide bottom row into sections based on valid_actions

local BTN_Y = H   -- buttons on last line
local btn_regions = {}  -- {x1,x2,action} populated in render

local function render_buttons()
    btn_regions = {}
    hfill(BTN_Y, colors.black)

    local actions = state.valid_actions
    if #actions == 0 then return end

    local section = math.floor(W / #actions)
    for i, act in ipairs(actions) do
        local x1 = (i-1)*section + 1
        local x2 = i==# actions and W or i*section
        local bg, fg
        if act=="fold"  then bg=colors.red;    fg=colors.white
        elseif act=="check" then bg=colors.gray;   fg=colors.white
        elseif act=="call"  then bg=colors.green;  fg=colors.black
        elseif act=="raise" then bg=colors.orange; fg=colors.black
        else bg=colors.gray; fg=colors.white end

        mon.setBackgroundColor(bg)
        mon.setCursorPos(x1,BTN_Y)
        mon.write(string.rep(" ",x2-x1+1))
        local lbl
        if act=="call" then
            lbl="CALL "..state.call_amount
        elseif act=="raise" then
            lbl=entering_raise and "RAISE: "..raise_input or "RAISE"
        else
            lbl=act:upper()
        end
        mon.setTextColor(fg)
        mon.setCursorPos(math.floor((x1+x2-#lbl)/2)+1, BTN_Y)
        mon.write(lbl)
        btn_regions[#btn_regions+1]={x1=x1,x2=x2,action=act}
    end
end

-- ── Main render ───────────────────────────────────────────────────────────────
local PHASE_LABEL={waiting="Waiting",preflop="Pre-Flop",flop="Flop",
                   turn="Turn",river="River",showdown="Showdown"}

local function render()
    cls(colors.black)

    -- Header: player id, chips, phase
    hfill(1, colors.black)
    local phase_str = PHASE_LABEL[state.phase] or state.phase
    local header = "P"..pid.."  Chips:"..state.chips.."  "..phase_str.."  POT:"..state.pot
    mprint(2,1,header,colors.yellow,colors.black)

    -- Hole cards — two large cards centered in the top portion
    local card_w = 7
    local gap = 2
    local total_cards_w = 2*card_w + gap
    local cx = math.floor((W - total_cards_w)/2) + 1
    local card_y = 3  -- leave row 2 for status
    draw_card(cx,        card_y, state.hand[1], true)
    draw_card(cx+card_w+gap, card_y, state.hand[2], true)

    -- Status line (row 2)
    hfill(2, colors.gray)
    if state.turn == pid and state.phase ~= "waiting" and state.phase ~= "showdown" then
        local act_str = "YOUR TURN — bet:"..state.current_bet.." call:"..state.call_amount
        mprint(2,2,act_str, colors.black, colors.lime)
    else
        local active_str = ""
        for i=1,4 do
            if state.active[i] then
                active_str = active_str.."P"..i.."("..( state.bets[i] or 0)..")  "
            end
        end
        mprint(2,2,active_str,colors.white,colors.gray)
    end

    -- Result lines at showdown
    if state.phase=="showdown" and #state.result_lines>0 then
        for i,line in ipairs(state.result_lines) do
            local y = card_y + 5 + i
            if y < BTN_Y then
                hfill(y, colors.black)
                mprint(2,y,line,colors.yellow,colors.black)
            end
        end
        -- Show other players' revealed hands
        local ry = card_y + 5 + #state.result_lines + 1
        for other, hand in pairs(state.all_hands) do
            if other ~= tostring(pid) and ry < BTN_Y then
                hfill(ry, colors.black)
                local c1 = hand[1] and hand[1].r..(SUIT_SYM[hand[1].s] or "?") or "?"
                local c2 = hand[2] and hand[2].r..(SUIT_SYM[hand[2].s] or "?") or "?"
                mprint(2,ry,"P"..other..": "..c1.." "..c2, colors.lightGray, colors.black)
                ry=ry+1
            end
        end
    end

    render_buttons()
end

-- ── Modem messaging ───────────────────────────────────────────────────────────
local function send_action(action, raise_to)
    modem.transmit(DEALER_CH, BCAST_CH,
        textutils.serialize({type="action",player=pid,action=action,raise_to=raise_to}))
end

local function connect()
    modem.transmit(DEALER_CH, BCAST_CH,
        textutils.serialize({type="hello",player=pid}))
end

-- ── Touch handling ────────────────────────────────────────────────────────────
local function handle_touch(x,y)
    if y ~= BTN_Y then return end
    for _,btn in ipairs(btn_regions) do
        if x>=btn.x1 and x<=btn.x2 then
            if btn.action=="raise" then
                if entering_raise then
                    local amt = tonumber(raise_input)
                    if amt then
                        entering_raise=false; raise_input=""
                        send_action("raise", amt)
                    end
                else
                    entering_raise=true; raise_input=""
                    render()
                end
            else
                entering_raise=false; raise_input=""
                if btn.action=="call" then
                    send_action("call", state.call_amount)
                else
                    send_action(btn.action)
                end
            end
            return
        end
    end
end

-- ── Message handler ───────────────────────────────────────────────────────────
local function handle_msg(msg)
    if not msg then return end

    -- filter: only process messages for this player or broadcast (target=0)
    local tgt = msg.target
    if tgt ~= nil and tgt ~= 0 and tgt ~= pid then return end

    if msg.type=="dealer_ready" then
        connect()

    elseif msg.type=="ack" then
        state.chips = msg.chips or state.chips
        state.phase = msg.phase or state.phase
        render()

    elseif msg.type=="deal" then
        state.hand = msg.hand or {}
        state.phase = "preflop"
        state.result_lines = {}
        state.all_hands = {}
        entering_raise = false; raise_input = ""
        render()

    elseif msg.type=="state" then
        state.phase   = msg.phase   or state.phase
        state.pot     = msg.pot     or state.pot
        state.bets    = msg.bets    or state.bets
        state.chips   = (msg.chips and msg.chips[pid]) or state.chips
        state.active  = msg.active  or state.active
        state.turn    = msg.turn    or state.turn
        render()

    elseif msg.type=="community" then
        state.community = msg.cards or {}
        render()

    elseif msg.type=="your_turn" then
        state.valid_actions = msg.valid_actions or {}
        state.call_amount   = msg.call_amount   or 0
        state.pot           = msg.pot           or state.pot
        state.current_bet   = msg.current_bet   or 0
        state.turn          = pid
        render()

    elseif msg.type=="reveal" then
        -- Another player's hand revealed at showdown
        if msg.player then
            state.all_hands[tostring(msg.player)] = msg.hand
        end
        render()

    elseif msg.type=="result" then
        state.phase        = "showdown"
        state.valid_actions= {}
        state.result_lines = msg.result_lines or {}
        if msg.community then state.community = msg.community end
        render()
    end
end

-- ── Key input for raise amount (fallback: keyboard) ───────────────────────────
local function handle_key(key)
    if not entering_raise then return end
    if key>=keys.zero and key<=keys.nine then
        raise_input = raise_input .. tostring(key - keys.zero)
        render()
    elseif key==keys.enter or key==keys.numPadEnter then
        local amt=tonumber(raise_input)
        if amt then
            entering_raise=false; raise_input=""
            send_action("raise", amt)
        end
    elseif key==keys.backspace then
        raise_input = raise_input:sub(1,-2)
        render()
    end
end

-- ── Boot ──────────────────────────────────────────────────────────────────────
cls(colors.black)
mprint(1,1,"P"..pid.." — Connecting...",colors.yellow,colors.black)
connect()

-- ── Event loop ────────────────────────────────────────────────────────────────
while true do
    local ev={os.pullEvent()}
    local etype=ev[1]

    if etype=="modem_message" then
        handle_msg(textutils.unserialize(ev[5] or ""))

    elseif etype=="monitor_touch" then
        handle_touch(ev[3],ev[4])

    elseif etype=="key" then
        handle_key(ev[2])
    end
end
