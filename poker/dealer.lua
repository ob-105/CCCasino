-- poker/dealer.lua
-- Texas Hold'em dealer for CCCasino
-- Hardware: 2w×5h monitor as main display, wireless modem
-- Run: dealer.lua [num_players]   (default 4)

local NUM_PLAYERS = tonumber(arg and arg[1]) or 4
local START_CHIPS  = 500
local SMALL_BLIND  = 5
local BIG_BLIND    = 10
local DEALER_CH    = 10   -- dealer listens here for player msgs
local BCAST_CH     = 11   -- dealer sends here; players listen

math.randomseed(os.epoch("utc"))

-- ── Peripherals ──────────────────────────────────────────────────────────────
local mon = peripheral.find("monitor")
assert(mon, "Attach a 2w×5h monitor to the dealer computer")
mon.setTextScale(0.5)
local W, H = mon.getSize()

local modem = peripheral.find("modem")
if modem then
    modem.open(DEALER_CH)
    modem.open(BCAST_CH)
end

-- ── Card definitions ─────────────────────────────────────────────────────────
local SUITS    = {"H","D","C","S"}
local RANKS    = {"A","2","3","4","5","6","7","8","9","T","J","Q","K"}
local SUIT_SYM = {H="\xe2\x99\xa5",D="\xe2\x99\xa6",C="\xe2\x99\xa3",S="\xe2\x99\xa0"}
local SUIT_COL = {H=colors.red,D=colors.red,C=colors.black,S=colors.black}
local RANK_VAL = {A=14,["2"]=2,["3"]=3,["4"]=4,["5"]=5,["6"]=6,["7"]=7,
                  ["8"]=8,["9"]=9,T=10,J=11,Q=12,K=13}

local function new_deck()
    local d={}
    for _,s in ipairs(SUITS) do
        for _,r in ipairs(RANKS) do d[#d+1]={r=r,s=s} end
    end
    return d
end

local function shuffle(d)
    for i=#d,2,-1 do local j=math.random(i); d[i],d[j]=d[j],d[i] end
end

-- ── Hand evaluator ───────────────────────────────────────────────────────────
local function eval5(cards)
    local v,s={},{}
    for _,c in ipairs(cards) do v[#v+1]=RANK_VAL[c.r]; s[#s+1]=c.s end
    table.sort(v,function(a,b)return a>b end)

    local flush = s[1]==s[2] and s[2]==s[3] and s[3]==s[4] and s[4]==s[5]
    local uniq={}; for _,x in ipairs(v) do uniq[x]=true end
    local straight = v[1]-v[5]==4 and #(function() local n=0 for _ in pairs(uniq) do n=n+1 end return n end)()==5
    if not straight and v[1]==14 and v[2]==5 and v[3]==4 and v[4]==3 and v[5]==2 then
        straight=true; v={5,4,3,2,1}
    end

    local cnt={}; for _,x in ipairs(v) do cnt[x]=(cnt[x]or 0)+1 end
    local g={}; for val,c in pairs(cnt) do g[#g+1]={c,val} end
    table.sort(g,function(a,b) return a[1]==b[1] and a[2]>b[2] or a[1]>b[1] end)

    if straight and flush then return {8,v[1]} end
    if g[1][1]==4 then return {7,g[1][2],g[2][2]} end
    if g[1][1]==3 and g[2] and g[2][1]==2 then return {6,g[1][2],g[2][2]} end
    if flush then return {5,v[1],v[2],v[3],v[4],v[5]} end
    if straight then return {4,v[1]} end
    if g[1][1]==3 then return {3,g[1][2],g[2] and g[2][2] or 0,g[3] and g[3][2] or 0} end
    if g[1][1]==2 and g[2] and g[2][1]==2 then return {2,g[1][2],g[2][2],g[3] and g[3][2] or 0} end
    if g[1][1]==2 then return {1,g[1][2],g[2] and g[2][2] or 0,g[3] and g[3][2] or 0,g[4] and g[4][2] or 0} end
    return {0,v[1],v[2],v[3],v[4],v[5]}
end

local function score_gt(a,b)
    for i=1,math.max(#a,#b) do
        local x,y=(a[i] or 0),(b[i] or 0)
        if x~=y then return x>y end
    end
    return false
end

local function best7(cards)
    local best=nil
    local function comb(i,cur)
        if #cur==5 then
            local h=eval5(cur)
            if not best or score_gt(h,best) then best=h end
            return
        end
        for j=i,#cards-(4-#cur) do
            cur[#cur+1]=cards[j]; comb(j+1,cur); cur[#cur]=nil
        end
    end
    comb(1,{})
    return best
end

local HAND_NAMES={"High Card","One Pair","Two Pair","Three of a Kind",
                  "Straight","Flush","Full House","Four of a Kind","Straight Flush"}
local function hand_name(h) return HAND_NAMES[(h[1] or 0)+1] or "?" end

-- ── Game state ───────────────────────────────────────────────────────────────
local G = {
    deck={}, top=1, community={},
    hands={},       -- hands[i] = {card,card}
    chips={},       -- chips[i]
    bets={},        -- bets this street
    pot=0,
    dealer_btn=1,
    phase="waiting",-- waiting|preflop|flop|turn|river|showdown
    active={},      -- active[i]=true if still in hand
    turn=0,         -- current player index
    current_bet=0,
    last_aggressor=0,
    acted={},       -- acted[i]=true this street
    result_lines={},-- shown during showdown
}

local connected={}  -- connected[i]=true

for i=1,NUM_PLAYERS do
    G.chips[i]=START_CHIPS; G.bets[i]=0
    G.active[i]=false; G.acted[i]=false; G.hands[i]={}
end

-- ── Modem ────────────────────────────────────────────────────────────────────
local function send_player(pid, msg)
    if modem then
        -- each player listens on BCAST_CH; message carries target field
        msg.target = pid
        modem.transmit(BCAST_CH, DEALER_CH, textutils.serialize(msg))
    end
end

local function broadcast_all(msg)
    if modem then
        msg.target = 0  -- 0 = all
        modem.transmit(BCAST_CH, DEALER_CH, textutils.serialize(msg))
    end
end

-- ── Drawing helpers ──────────────────────────────────────────────────────────
local function cls(bg)
    mon.setBackgroundColor(bg or colors.green)
    mon.clear()
end

local function mprint(x,y,txt,fg,bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(x,y)
    mon.write(txt)
end

local function hline(y,bg)
    mon.setBackgroundColor(bg)
    mon.setCursorPos(1,y)
    mon.write(string.rep(" ",W))
end

-- Draw a card at (x,y), 5 wide × 3 tall
local function draw_card_main(x,y,card,face_up)
    if not face_up then
        for dy=0,2 do
            mon.setBackgroundColor(colors.blue)
            mon.setTextColor(colors.cyan)
            mon.setCursorPos(x,y+dy)
            if dy==0 then mon.write("\xe2\x95\x94\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x97")
            elseif dy==2 then mon.write("\xe2\x95\x9a\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x9d")
            else mon.write("\xe2\x95\x91\xce\xb1\xce\xb1\xce\xb1\xe2\x95\x91") end
        end
        return
    end
    local sc = SUIT_COL[card.s]
    local sym = SUIT_SYM[card.s]
    local r = card.r
    -- pad rank to 2 chars
    local top_txt = (r=="10" and r or r.." ")..sym
    mon.setBackgroundColor(colors.white); mon.setTextColor(sc)
    mon.setCursorPos(x,y);   mon.write("\xe2\x95\x94\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x97")
    mon.setCursorPos(x,y+1); mon.write("\xe2\x95\x91"..top_txt.."\xe2\x95\x91")
    mon.setCursorPos(x,y+2); mon.write("\xe2\x95\x9a\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x9d")
end

-- ── Main monitor render ──────────────────────────────────────────────────────
local PHASE_LABEL={waiting="Waiting for Players",preflop="Pre-Flop",
                   flop="Flop",turn="Turn",river="River",showdown="Showdown"}

local function render()
    cls(colors.green)

    -- Header bar
    hline(1,colors.black)
    local title=" \xe2\x99\xa0 TEXAS HOLD'EM \xe2\x99\xa5 "
    mprint(math.floor((W-#title)/2)+1,1,title,colors.yellow,colors.black)

    -- Phase + pot
    hline(2,colors.gray)
    local ph = PHASE_LABEL[G.phase] or G.phase
    mprint(2,2,ph,colors.white,colors.gray)
    local pstr="POT: "..G.pot
    mprint(W-#pstr,2,pstr,colors.yellow,colors.gray)

    -- Community cards — 5 cards, each 5w×3h, centered, starting y=4
    local total_w = 5*5 + 4*1  -- 5 cards × 5wide + 4 gaps × 1
    local cx = math.floor((W-total_w)/2)+1
    for i=1,5 do
        local x = cx + (i-1)*6
        if G.community[i] then
            draw_card_main(x,4,G.community[i],true)
        else
            -- Empty placeholder
            mon.setBackgroundColor(colors.lime)
            mon.setTextColor(colors.green)
            for dy=0,2 do
                mon.setCursorPos(x,4+dy)
                if dy==0 then mon.write("\xe2\x94\x8c\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x90")
                elseif dy==2 then mon.write("\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x98")
                else mon.write("\xe2\x94\x82   \xe2\x94\x82") end
            end
        end
    end

    -- Separator
    hline(8,colors.gray)

    -- Player rows
    local row_h = math.floor((H-9)/NUM_PLAYERS)
    for i=1,NUM_PLAYERS do
        local y = 9 + (i-1)*row_h
        local is_turn = (G.turn==i and G.phase~="waiting" and G.phase~="showdown")
        local bg = is_turn and colors.lime or (G.active[i] and colors.gray or colors.black)
        local fg = is_turn and colors.black or colors.white

        hline(y,bg)
        local name="P"..i
        if G.dealer_btn==i then name=name.."(D)" end
        local status
        if not connected[i] then status="offline"
        elseif not G.active[i] and G.phase~="waiting" then status="folded"
        else status="chips:"..G.chips[i] end
        local bet_str = G.phase~="waiting" and " bet:"..G.bets[i] or ""
        mprint(2,y,name.." "..status..bet_str, fg, bg)
    end

    -- Showdown results
    if G.phase=="showdown" then
        for i,line in ipairs(G.result_lines) do
            if 9+NUM_PLAYERS*row_h+i <= H then
                hline(9+NUM_PLAYERS*row_h+i,colors.black)
                mprint(2,9+NUM_PLAYERS*row_h+i,line,colors.yellow,colors.black)
            end
        end
    end

    -- Start / Next Hand button
    if G.phase=="waiting" or G.phase=="showdown" then
        local btn_lbl = G.phase=="waiting" and "[ START GAME ]" or "[ NEXT HAND  ]"
        local bx=math.floor((W-#btn_lbl)/2)+1
        mprint(bx,H,btn_lbl,colors.black,colors.lime)
    end
end

-- ── Helpers ──────────────────────────────────────────────────────────────────
local function deal_card()
    local c=G.deck[G.top]; G.top=G.top+1; return c
end

local function next_active_after(pos)
    for i=1,NUM_PLAYERS do
        local p=((pos-1+i)%NUM_PLAYERS)+1
        if G.active[p] then return p end
    end
    return nil
end

local function count_active()
    local n=0; for i=1,NUM_PLAYERS do if G.active[i] then n=n+1 end end
    return n
end

local function active_all_acted()
    for i=1,NUM_PLAYERS do
        if G.active[i] and not G.acted[i] then return false end
    end
    return true
end

-- ── Betting ──────────────────────────────────────────────────────────────────
local function notify_current_player()
    local p=G.turn
    if not p or p==0 then return end
    local call_amt = math.max(0, G.current_bet - G.bets[p])
    call_amt = math.min(call_amt, G.chips[p])
    local actions={"fold"}
    if call_amt==0 then actions[#actions+1]="check"
    else actions[#actions+1]="call" end
    if G.chips[p]>call_amt then actions[#actions+1]="raise" end
    send_player(p,{type="your_turn",valid_actions=actions,
        call_amount=call_amt,pot=G.pot,current_bet=G.current_bet})
end

local function broadcast_state()
    broadcast_all({type="state",phase=G.phase,community=G.community,
        pot=G.pot,bets=G.bets,chips=G.chips,active=G.active,turn=G.turn})
end

local advance_phase  -- forward declaration

local function next_turn()
    if count_active()<=1 then advance_phase(); return end

    -- Find next active player who hasn't matched the bet or hasn't acted
    local start=G.turn
    for i=1,NUM_PLAYERS do
        local p=((start-1+i)%NUM_PLAYERS)+1
        if G.active[p] then
            if not G.acted[p] or G.bets[p] < G.current_bet then
                G.turn=p
                broadcast_state()
                render()
                notify_current_player()
                return
            end
        end
    end
    -- Everyone acted and matched — advance phase
    advance_phase()
end

local function post_bet(p, amount)
    amount = math.min(amount, G.chips[p])
    G.chips[p]  = G.chips[p] - amount
    G.bets[p]   = G.bets[p] + amount
    G.pot       = G.pot + amount
    if G.bets[p] > G.current_bet then
        G.current_bet = G.bets[p]
        G.last_aggressor = p
        -- reset acted for everyone else when there's a raise
        for i=1,NUM_PLAYERS do if i~=p then G.acted[i]=false end end
    end
    G.acted[p] = true
end

local function do_action(pid, action, raise_to)
    if G.turn ~= pid then return end
    if action=="fold" then
        G.active[pid]=false
        G.acted[pid]=true
    elseif action=="check" then
        G.acted[pid]=true
    elseif action=="call" then
        local call_amt=math.max(0,G.current_bet-G.bets[pid])
        post_bet(pid,call_amt)
    elseif action=="raise" then
        local min_raise = G.current_bet + BIG_BLIND
        local to = math.max(min_raise, raise_to or min_raise)
        local additional = to - G.bets[pid]
        post_bet(pid, additional)
    end
    next_turn()
end

-- ── Phase transitions ────────────────────────────────────────────────────────
local function reset_street_bets()
    for i=1,NUM_PLAYERS do G.bets[i]=0; G.acted[i]=false end
    G.current_bet=0
end

local function start_street_betting(first_to_act)
    G.turn = first_to_act
    broadcast_state()
    render()
    notify_current_player()
end

advance_phase = function()
    -- Collect remaining bets into pot already done in post_bet
    if count_active()<=1 then
        -- Everyone folded — award pot to last remaining player
        local winner=nil
        for i=1,NUM_PLAYERS do if G.active[i] then winner=i end end
        if winner then
            G.chips[winner]=G.chips[winner]+G.pot
            G.result_lines={"P"..winner.." wins "..G.pot.." (all folded)"}
        end
        G.phase="showdown"
        broadcast_state()
        render()
        return
    end

    if G.phase=="preflop" then
        G.phase="flop"
        G.community[1]=deal_card()
        G.community[2]=deal_card()
        G.community[3]=deal_card()
        reset_street_bets()
        broadcast_all({type="community",cards=G.community})
        start_street_betting(next_active_after(G.dealer_btn))

    elseif G.phase=="flop" then
        G.phase="turn"
        G.community[4]=deal_card()
        reset_street_bets()
        broadcast_all({type="community",cards=G.community})
        start_street_betting(next_active_after(G.dealer_btn))

    elseif G.phase=="turn" then
        G.phase="river"
        G.community[5]=deal_card()
        reset_street_bets()
        broadcast_all({type="community",cards=G.community})
        start_street_betting(next_active_after(G.dealer_btn))

    elseif G.phase=="river" then
        G.phase="showdown"
        do_showdown()
    end
end

-- ── Showdown ─────────────────────────────────────────────────────────────────
local function do_showdown()
    -- Reveal all hands to players
    for i=1,NUM_PLAYERS do
        if G.active[i] then
            broadcast_all({type="reveal",player=i,hand=G.hands[i]})
        end
    end

    -- Evaluate
    local scores={}
    for i=1,NUM_PLAYERS do
        if G.active[i] then
            local seven={}
            for _,c in ipairs(G.hands[i]) do seven[#seven+1]=c end
            for _,c in ipairs(G.community) do seven[#seven+1]=c end
            scores[i]=best7(seven)
        end
    end

    -- Find winner(s)
    local best_score=nil
    local winners={}
    for i=1,NUM_PLAYERS do
        if scores[i] then
            if not best_score or score_gt(scores[i],best_score) then
                best_score=scores[i]; winners={i}
            elseif not score_gt(best_score,scores[i]) then
                winners[#winners+1]=i
            end
        end
    end

    -- Split pot
    local share=math.floor(G.pot/#winners)
    G.result_lines={}
    for _,w in ipairs(winners) do
        G.chips[w]=G.chips[w]+share
        local hn=scores[w] and hand_name(scores[w]) or "?"
        G.result_lines[#G.result_lines+1]="P"..w.." wins "..share.." with "..hn
    end

    broadcast_state()
    -- Send result to each player
    for i=1,NUM_PLAYERS do
        local won=false
        for _,w in ipairs(winners) do if w==i then won=true end end
        local hn=scores[i] and hand_name(scores[i]) or nil
        send_player(i,{type="result",won=won,
            winners=winners,result_lines=G.result_lines,
            hand_name=hn, community=G.community})
    end
    render()
end

-- ── Deal new hand ─────────────────────────────────────────────────────────────
local function start_hand()
    -- Need at least 2 connected players
    local cnt=0; for i=1,NUM_PLAYERS do if connected[i] then cnt=cnt+1 end end
    if cnt<2 then
        G.result_lines={"Need at least 2 players"}
        render(); return
    end

    G.deck=new_deck(); shuffle(G.deck); G.top=1
    G.community={}
    G.pot=0; G.current_bet=0; G.result_lines={}

    -- Advance dealer button
    G.dealer_btn=next_active_after(G.dealer_btn) or 1

    for i=1,NUM_PLAYERS do
        G.active[i] = connected[i] and G.chips[i]>0
        G.bets[i]=0; G.acted[i]=false; G.hands[i]={}
    end

    -- Deal 2 cards each
    for round=1,2 do
        for p=1,NUM_PLAYERS do
            if G.active[p] then
                G.hands[p][round]=deal_card()
            end
        end
    end

    -- Post blinds
    local sb=next_active_after(G.dealer_btn)
    local bb=next_active_after(sb)
    post_bet(sb,SMALL_BLIND)
    post_bet(bb,BIG_BLIND)
    -- reset acted for blinds (they haven't had a chance to act yet)
    G.acted[sb]=false
    G.acted[bb]=false
    G.current_bet=BIG_BLIND

    G.phase="preflop"
    G.turn=next_active_after(bb)

    -- Send hands privately
    for i=1,NUM_PLAYERS do
        if G.active[i] then
            send_player(i,{type="deal",hand=G.hands[i],
                player=i, dealer=G.dealer_btn,
                sb=sb,bb=bb})
        end
    end

    broadcast_state()
    render()
    notify_current_player()
end

-- ── Touch handling on main monitor ───────────────────────────────────────────
local function handle_touch(x,y)
    if G.phase=="waiting" or G.phase=="showdown" then
        -- Check if START/NEXT button tapped
        local btn_lbl = G.phase=="waiting" and "[ START GAME ]" or "[ NEXT HAND  ]"
        local bx=math.floor((W-#btn_lbl)/2)+1
        if y==H and x>=bx and x<=bx+#btn_lbl-1 then
            start_hand()
        end
    end
end

-- ── Main loop ─────────────────────────────────────────────────────────────────
render()

-- Announce presence
if modem then
    broadcast_all({type="dealer_ready",num_players=NUM_PLAYERS})
end

while true do
    local ev={os.pullEvent()}
    local etype=ev[1]

    if etype=="monitor_touch" then
        handle_touch(ev[3],ev[4])

    elseif etype=="modem_message" then
        local msg=textutils.unserialize(ev[5] or "")
        if msg then
            if msg.type=="hello" and msg.player then
                connected[msg.player]=true
                send_player(msg.player,{type="ack",player=msg.player,
                    chips=G.chips[msg.player],phase=G.phase})
                render()

            elseif msg.type=="action" and msg.player then
                do_action(msg.player, msg.action, msg.raise_to)
            end
        end

    elseif etype=="key" then
        -- s = start/next (fallback for testing without touch)
        if ev[2]==keys.s then
            if G.phase=="waiting" or G.phase=="showdown" then
                start_hand()
            end
        end
    end
end
