-- poker/dealer.lua
-- Texas Hold'em — main table computer
-- Monitor: 2w x 5h, attached to this computer, font auto-set to 0.5
-- Modem:   wireless, listens ch10, broadcasts ch11
-- Run: dealer [num_players]   default 4

local NUM_PLAYERS = tonumber(arg and arg[1]) or 4
local START_CHIPS = 500
local SMALL_BLIND = 5
local BIG_BLIND   = 10
local DEALER_CH   = 10
local BCAST_CH    = 11

math.randomseed(os.epoch("utc"))

-- ── Peripherals ───────────────────────────────────────────────
local mon = peripheral.find("monitor")
assert(mon, "No monitor found")
mon.setTextScale(0.5)
local W, H = mon.getSize()

local modem = peripheral.find("modem")
if modem then modem.open(DEALER_CH); modem.open(BCAST_CH) end

-- ── Cards ─────────────────────────────────────────────────────
local SUITS = {"H","D","C","S"}
local RANKS = {"A","2","3","4","5","6","7","8","9","T","J","Q","K"}
local SUIT_COL = {H=colors.red,D=colors.red,C=colors.gray,S=colors.gray}
local RANK_VAL = {A=14,["2"]=2,["3"]=3,["4"]=4,["5"]=5,["6"]=6,
                  ["7"]=7,["8"]=8,["9"]=9,T=10,J=11,Q=12,K=13}

local function new_deck()
    local d={}
    for _,s in ipairs(SUITS) do for _,r in ipairs(RANKS) do
        d[#d+1]={r=r,s=s}
    end end
    return d
end
local function shuffle(d)
    for i=#d,2,-1 do local j=math.random(i); d[i],d[j]=d[j],d[i] end
end

-- ── Hand evaluator ────────────────────────────────────────────
local function uniq_count(t)
    local s={}; local n=0
    for _,v in ipairs(t) do if not s[v] then s[v]=true; n=n+1 end end
    return n
end

local function eval5(cards)
    local v,s={},{}
    for _,c in ipairs(cards) do v[#v+1]=RANK_VAL[c.r]; s[#s+1]=c.s end
    table.sort(v,function(a,b)return a>b end)
    local flush=s[1]==s[2] and s[2]==s[3] and s[3]==s[4] and s[4]==s[5]
    local straight=v[1]-v[5]==4 and uniq_count(v)==5
    if not straight and v[1]==14 and v[2]==5 and v[3]==4 and v[4]==3 and v[5]==2 then
        straight=true; v={5,4,3,2,1}
    end
    local cnt={}; for _,x in ipairs(v) do cnt[x]=(cnt[x]or 0)+1 end
    local g={}; for val,c in pairs(cnt) do g[#g+1]={c,val} end
    table.sort(g,function(a,b)return a[1]==b[1] and a[2]>b[2] or a[1]>b[1] end)
    if straight and flush then return {8,v[1]} end
    if g[1][1]==4 then return {7,g[1][2],(g[2] and g[2][2] or 0)} end
    if g[1][1]==3 and g[2] and g[2][1]==2 then return {6,g[1][2],g[2][2]} end
    if flush then return {5,v[1],v[2],v[3],v[4],v[5]} end
    if straight then return {4,v[1]} end
    if g[1][1]==3 then return {3,g[1][2],(g[2] and g[2][2] or 0),(g[3] and g[3][2] or 0)} end
    if g[1][1]==2 and g[2] and g[2][1]==2 then return {2,g[1][2],g[2][2],(g[3] and g[3][2] or 0)} end
    if g[1][1]==2 then return {1,g[1][2],(g[2] and g[2][2] or 0),(g[3] and g[3][2] or 0),(g[4] and g[4][2] or 0)} end
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
    comb(1,{}); return best
end

local HAND_NAMES={"High Card","One Pair","Two Pair","Three of a Kind",
                  "Straight","Flush","Full House","Four of a Kind","Straight Flush"}
local function hand_name(h) return HAND_NAMES[(h and h[1] or 0)+1] or "?" end

-- ── Layout ────────────────────────────────────────────────────
-- Player zones: top strip (P1 left, P2 right) + bottom strip (P3 left, P4 right)
-- Center zone: community cards
local PZH = math.max(6, math.floor(H * 0.22))  -- player zone height in chars
local HW  = math.floor(W / 2)

-- PZ[id] = {x1,y1,x2,y2}
local PZ = {
    [1] = {x1=1,    y1=1,       x2=HW, y2=PZH},
    [2] = {x1=HW+1, y1=1,       x2=W,  y2=PZH},
    [3] = {x1=1,    y1=H-PZH+1, x2=HW, y2=H},
    [4] = {x1=HW+1, y1=H-PZH+1, x2=W,  y2=H},
}
local CZ  = {y1=PZH+1, y2=H-PZH}   -- community zone y bounds

-- ── Game state ────────────────────────────────────────────────
local G = {
    deck={}, top=1, community={},
    hands={}, chips={}, bets={}, pot=0,
    dealer_btn=1, phase="waiting",
    active={}, turn=0, current_bet=0,
    acted={}, result_lines={},
    waiting_raise=nil,  -- pid waiting to enter raise amount
}
local connected = {}

for i=1,NUM_PLAYERS do
    G.chips[i]=START_CHIPS; G.bets[i]=0
    G.active[i]=false; G.acted[i]=false; G.hands[i]={}
end

-- ── Modem ─────────────────────────────────────────────────────
local function send_p(pid,msg)
    if not modem then return end
    msg.target=pid
    modem.transmit(BCAST_CH,DEALER_CH,textutils.serialize(msg))
end
local function bcast(msg)
    if not modem then return end
    msg.target=0
    modem.transmit(BCAST_CH,DEALER_CH,textutils.serialize(msg))
end

-- ── Drawing ───────────────────────────────────────────────────
local function mfill(x1,y1,x2,y2,bg,fg,char)
    mon.setBackgroundColor(bg)
    if fg then mon.setTextColor(fg) end
    local row=string.rep(char or " ",x2-x1+1)
    for y=y1,y2 do mon.setCursorPos(x1,y); mon.write(row) end
end

local function mprint(x,y,txt,fg,bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(x,y); mon.write(txt)
end

local function mcentre(x1,x2,y,txt,fg,bg)
    local x=x1+math.floor((x2-x1+1-#txt)/2)
    mprint(x,y,txt,fg,bg)
end

-- Draw a community card: 5 wide x 3 tall at (x,y)
local function draw_community_card(x,y,card,flash)
    if not card then
        -- empty slot outline
        mon.setBackgroundColor(colors.green)
        mon.setTextColor(colors.lime)
        mon.setCursorPos(x,y);   mon.write("+---+")
        mon.setCursorPos(x,y+1); mon.write("|   |")
        mon.setCursorPos(x,y+2); mon.write("+---+")
        return
    end
    local bg = flash and colors.yellow or colors.white
    local sc = SUIT_COL[card.s] or colors.gray
    local r  = card.r
    local s  = card.s
    -- inner 3 chars: rank left-padded, suit centred
    local top = r..string.rep(" ",3-#r)
    local bot = string.rep(" ",3-#r)..r
    mon.setBackgroundColor(bg); mon.setTextColor(sc)
    mon.setCursorPos(x,y);   mon.write("+---+")
    mon.setCursorPos(x,y+1); mon.write("|"..top.."|")
    mon.setCursorPos(x,y+2); mon.write("+---+")
    -- suit indicator dot below
    mon.setCursorPos(x+2,y+1); mon.setTextColor(sc); mon.write(s)
end

-- Draw small card back (2 wide x 1 tall) in a player zone
local function draw_card_back_sm(x,y)
    mon.setBackgroundColor(colors.blue)
    mon.setTextColor(colors.cyan)
    mon.setCursorPos(x,y); mon.write("[/]")
end

-- Player zone render
local function render_zone(pid)
    local z=PZ[pid]
    local zw=z.x2-z.x1+1
    local zh=z.y2-z.y1+1

    local is_turn  = G.turn==pid and G.phase~="waiting" and G.phase~="showdown" and G.waiting_raise==nil
    local is_raise = G.waiting_raise==pid
    local folded   = G.phase~="waiting" and G.phase~="showdown" and not G.active[pid]

    local hdr_bg = is_turn and colors.lime or (folded and colors.black or colors.gray)
    local hdr_fg = is_turn and colors.black or colors.white

    -- Header row
    mfill(z.x1,z.y1,z.x2,z.y1,hdr_bg)
    local lbl = "P"..pid..(G.dealer_btn==pid and "(D)" or "")
    local info = G.chips[pid].."c"
    mprint(z.x1+1,z.y1,lbl,hdr_fg,hdr_bg)
    mprint(z.x2-#info,z.y1,info,hdr_fg,hdr_bg)

    -- Status / card backs row(s)
    local mid_bg = folded and colors.black or colors.gray
    for y=z.y1+1,z.y2-1 do mfill(z.x1,y,z.x2,y,mid_bg) end

    if G.phase~="waiting" and G.phase~="showdown" then
        if folded then
            mcentre(z.x1,z.x2,z.y1+1,"FOLDED",colors.red,colors.black)
        elseif is_raise then
            mcentre(z.x1,z.x2,z.y1+1,"Entering raise...",colors.yellow,colors.gray)
        else
            -- show card backs + bet
            if G.active[pid] then
                local cx=z.x1+math.floor(zw/2)-3
                draw_card_back_sm(cx,z.y1+1)
                draw_card_back_sm(cx+4,z.y1+1)
            end
            if G.bets[pid] and G.bets[pid]>0 then
                local bet_str="bet:"..G.bets[pid]
                mcentre(z.x1,z.x2,z.y1+2,bet_str,colors.yellow,colors.gray)
            end
        end
    end

    -- Button row (bottom of zone)
    mfill(z.x1,z.y2,z.x2,z.y2,colors.black)
    if is_turn then
        -- draw action buttons
        local acts = G._valid_actions or {}
        local n = #acts
        if n>0 then
            local bw=math.floor(zw/n)
            for i,act in ipairs(acts) do
                local bx1=z.x1+(i-1)*bw
                local bx2=(i==n) and z.x2 or z.x1+i*bw-1
                local bg,fg
                if act=="fold" then bg=colors.red; fg=colors.white
                elseif act=="check" then bg=colors.gray; fg=colors.white
                elseif act=="call" then bg=colors.green; fg=colors.black
                elseif act=="raise" then bg=colors.orange; fg=colors.black
                else bg=colors.gray; fg=colors.white end
                mfill(bx1,z.y2,bx2,z.y2,bg)
                local lbl2=act:upper()
                if act=="call" then lbl2="CALL "..math.min(G.current_bet-G.bets[pid],G.chips[pid]) end
                mcentre(bx1,bx2,z.y2,lbl2,fg,bg)
            end
        end
    elseif G.phase=="waiting" or G.phase=="showdown" then
        if not connected[pid] then
            mcentre(z.x1,z.x2,z.y2,"(offline)",colors.gray,colors.black)
        else
            mcentre(z.x1,z.x2,z.y2,"ready",colors.lime,colors.black)
        end
    end
end

-- Community zone render
local PHASE_LABEL={waiting="Waiting for Players",preflop="Pre-Flop",
                   flop="Flop",turn="Turn",river="River",showdown="Showdown"}

local function render_community()
    local y1,y2=CZ.y1,CZ.y2
    mfill(1,y1,W,y2,colors.green)

    -- Title / phase bar
    local ph=PHASE_LABEL[G.phase] or G.phase
    local pot_str=" POT: "..G.pot.." "
    mfill(1,y1,W,y1,colors.black)
    mcentre(1,W,y1,ph,colors.yellow,colors.black)
    mprint(W-#pot_str+1,y1,pot_str,colors.yellow,colors.black)

    -- Community cards: 5 cards, each 5w x 3h, centred vertically and horizontally
    local card_w=5; local gap=2; local total=5*card_w+4*gap
    local cx=math.floor((W-total)/2)+1
    local cy=y1+math.floor((y2-y1-3)/2)+1
    for i=1,5 do
        local x=cx+(i-1)*(card_w+gap)
        draw_community_card(x,cy,G.community[i],false)
    end

    -- Result lines at showdown
    if G.phase=="showdown" then
        local ry=cy+4
        for i,line in ipairs(G.result_lines) do
            if ry+i-1<=y2-1 then
                mcentre(1,W,ry+i-1,line,colors.yellow,colors.green)
            end
        end
    end

    -- Start / Next hand button
    if G.phase=="waiting" or G.phase=="showdown" then
        local btn=G.phase=="waiting" and "[ START GAME ]" or "[ NEXT HAND ]"
        local bx=math.floor((W-#btn)/2)+1
        mfill(bx,y2,bx+#btn-1,y2,colors.lime)
        mprint(bx,y2,btn,colors.black,colors.lime)
    end
end

local function render()
    mon.setBackgroundColor(colors.green); mon.clear()
    render_community()
    for i=1,NUM_PLAYERS do render_zone(i) end
end

-- ── Animations ────────────────────────────────────────────────
local function anim_deal_to(pid)
    -- Flash player zone briefly in white to simulate card being dealt
    local z=PZ[pid]
    mfill(z.x1,z.y1,z.x2,z.y2,colors.white)
    sleep(0.07)
    render_zone(pid)
end

local function anim_community_card(idx)
    -- Flash the newly added card yellow, then normal
    local card_w=5; local gap=2; local total=5*card_w+4*gap
    local cx=math.floor((W-total)/2)+1
    local cy=CZ.y1+math.floor((CZ.y2-CZ.y1-3)/2)+1
    local x=cx+(idx-1)*(card_w+gap)
    draw_community_card(x,cy,G.community[idx],true)
    sleep(0.15)
    draw_community_card(x,cy,G.community[idx],false)
end

local function anim_win(winners)
    for _=1,3 do
        for _,w in ipairs(winners) do
            local z=PZ[w]
            mfill(z.x1,z.y1,z.x2,z.y2,colors.yellow)
        end
        sleep(0.12)
        for _,w in ipairs(winners) do render_zone(w) end
        sleep(0.1)
    end
end

-- ── Helpers ───────────────────────────────────────────────────
local function deal_card() local c=G.deck[G.top]; G.top=G.top+1; return c end

local function next_active_after(pos)
    for i=1,NUM_PLAYERS do
        local p=((pos-1+i)%NUM_PLAYERS)+1
        if G.active[p] then return p end
    end
end

local function count_active()
    local n=0; for i=1,NUM_PLAYERS do if G.active[i] then n=n+1 end end; return n
end

local function valid_actions_for(pid)
    local acts={"fold"}
    local call_amt=math.max(0,G.current_bet-G.bets[pid])
    if call_amt==0 then acts[#acts+1]="check"
    else acts[#acts+1]="call" end
    if G.chips[pid]>call_amt then acts[#acts+1]="raise" end
    return acts
end

local advance_phase  -- forward decl

local function notify_turn()
    local p=G.turn
    if not p or p==0 then return end
    local acts=valid_actions_for(p)
    G._valid_actions=acts
    local call_amt=math.max(0,G.current_bet-G.bets[p])
    send_p(p,{type="your_turn",valid_actions=acts,
              call_amount=call_amt,pot=G.pot,current_bet=G.current_bet})
    render()
end

local function bcast_state()
    bcast({type="state",phase=G.phase,community=G.community,
           pot=G.pot,bets=G.bets,chips=G.chips,active=G.active,turn=G.turn})
end

-- ── Betting ───────────────────────────────────────────────────
local function post_bet(p,amount)
    amount=math.min(amount,G.chips[p])
    G.chips[p]=G.chips[p]-amount
    G.bets[p]=G.bets[p]+amount
    G.pot=G.pot+amount
    if G.bets[p]>G.current_bet then
        G.current_bet=G.bets[p]
        for i=1,NUM_PLAYERS do if i~=p then G.acted[i]=false end end
    end
    G.acted[p]=true
end

local function next_turn()
    if count_active()<=1 then advance_phase(); return end
    local start=G.turn
    for i=1,NUM_PLAYERS do
        local p=((start-1+i)%NUM_PLAYERS)+1
        if G.active[p] and (not G.acted[p] or G.bets[p]<G.current_bet) then
            G.turn=p; G._valid_actions=nil
            bcast_state(); notify_turn(); return
        end
    end
    advance_phase()
end

local function do_action(pid,action,raise_to)
    if G.turn~=pid then return end
    G.waiting_raise=nil
    if action=="fold" then
        G.active[pid]=false; G.acted[pid]=true
    elseif action=="check" then
        G.acted[pid]=true
    elseif action=="call" then
        post_bet(pid,math.max(0,G.current_bet-G.bets[pid]))
    elseif action=="raise" then
        local min_r=G.current_bet+BIG_BLIND
        local to=math.max(min_r,raise_to or min_r)
        post_bet(pid,to-G.bets[pid])
    end
    next_turn()
end

-- ── Phase transitions ─────────────────────────────────────────
local function reset_street()
    for i=1,NUM_PLAYERS do G.bets[i]=0; G.acted[i]=false end
    G.current_bet=0
end

local function start_street(first)
    G.turn=first; G._valid_actions=nil
    bcast_state(); notify_turn()
end

local function do_showdown()
    for i=1,NUM_PLAYERS do
        if G.active[i] then bcast({type="reveal",player=i,hand=G.hands[i]}) end
    end
    local scores={}
    for i=1,NUM_PLAYERS do
        if G.active[i] then
            local seven={}
            for _,c in ipairs(G.hands[i]) do seven[#seven+1]=c end
            for _,c in ipairs(G.community) do seven[#seven+1]=c end
            scores[i]=best7(seven)
        end
    end
    local best_s,winners=nil,{}
    for i=1,NUM_PLAYERS do
        if scores[i] then
            if not best_s or score_gt(scores[i],best_s) then
                best_s=scores[i]; winners={i}
            elseif not score_gt(best_s,scores[i]) then
                winners[#winners+1]=i
            end
        end
    end
    local share=math.floor(G.pot/#winners)
    G.result_lines={}
    for _,w in ipairs(winners) do
        G.chips[w]=G.chips[w]+share
        G.result_lines[#G.result_lines+1]="P"..w.." wins "..share.." ("..hand_name(scores[w])..")"
    end
    bcast_state()
    for i=1,NUM_PLAYERS do
        local won=false
        for _,w in ipairs(winners) do if w==i then won=true end end
        send_p(i,{type="result",won=won,winners=winners,
                  result_lines=G.result_lines,
                  hand_name=scores[i] and hand_name(scores[i]) or nil,
                  community=G.community})
    end
    anim_win(winners)
    render()
end

advance_phase = function()
    G._valid_actions=nil
    if count_active()<=1 then
        local winner=nil
        for i=1,NUM_PLAYERS do if G.active[i] then winner=i end end
        if winner then
            G.chips[winner]=G.chips[winner]+G.pot
            G.result_lines={"P"..winner.." wins "..G.pot.." (all folded)"}
        end
        G.phase="showdown"
        bcast_state(); anim_win({winner}); render(); return
    end
    local first=next_active_after(G.dealer_btn)
    if G.phase=="preflop" then
        G.phase="flop"
        G.community[1]=deal_card(); G.community[2]=deal_card(); G.community[3]=deal_card()
        reset_street()
        bcast({type="community",cards=G.community})
        render()
        for i=1,3 do anim_community_card(i); sleep(0.1) end
        start_street(first)
    elseif G.phase=="flop" then
        G.phase="turn"
        G.community[4]=deal_card()
        reset_street()
        bcast({type="community",cards=G.community})
        render(); anim_community_card(4)
        start_street(first)
    elseif G.phase=="turn" then
        G.phase="river"
        G.community[5]=deal_card()
        reset_street()
        bcast({type="community",cards=G.community})
        render(); anim_community_card(5)
        start_street(first)
    elseif G.phase=="river" then
        G.phase="showdown"
        do_showdown()
    end
end

-- ── Start hand ────────────────────────────────────────────────
local function start_hand()
    local cnt=0; for i=1,NUM_PLAYERS do if connected[i] then cnt=cnt+1 end end
    if cnt<2 then
        G.result_lines={"Need at least 2 players connected"}; render(); return
    end
    G.deck=new_deck(); shuffle(G.deck); G.top=1
    G.community={}; G.pot=0; G.current_bet=0; G.result_lines={}
    G._valid_actions=nil; G.waiting_raise=nil
    G.dealer_btn=next_active_after(G.dealer_btn) or 1
    for i=1,NUM_PLAYERS do
        G.active[i]=connected[i] and G.chips[i]>0
        G.bets[i]=0; G.acted[i]=false; G.hands[i]={}
    end
    -- Deal with animation
    for round=1,2 do
        for p=1,NUM_PLAYERS do
            if G.active[p] then
                G.hands[p][round]=deal_card()
                anim_deal_to(p); sleep(0.08)
            end
        end
    end
    -- Send hole cards privately
    for i=1,NUM_PLAYERS do
        if G.active[i] then
            send_p(i,{type="deal",hand=G.hands[i],player=i,
                      dealer=G.dealer_btn})
        end
    end
    -- Blinds
    local sb=next_active_after(G.dealer_btn)
    local bb=next_active_after(sb)
    post_bet(sb,SMALL_BLIND); post_bet(bb,BIG_BLIND)
    G.acted[sb]=false; G.acted[bb]=false
    G.current_bet=BIG_BLIND
    G.phase="preflop"
    G.turn=next_active_after(bb)
    bcast_state(); notify_turn()
end

-- ── Touch on main monitor ─────────────────────────────────────
local function handle_touch(tx,ty)
    -- Community zone: start/next button
    if ty>=CZ.y1 and ty<=CZ.y2 then
        if (G.phase=="waiting" or G.phase=="showdown") and ty==CZ.y2 then
            local btn=G.phase=="waiting" and "[ START GAME ]" or "[ NEXT HAND ]"
            local bx=math.floor((W-#btn)/2)+1
            if tx>=bx and tx<=bx+#btn-1 then start_hand() end
        end
        return
    end
    -- Player zones
    for pid=1,NUM_PLAYERS do
        local z=PZ[pid]
        if tx>=z.x1 and tx<=z.x2 and ty>=z.y1 and ty<=z.y2 then
            if ty==z.y2 and G.turn==pid and G._valid_actions then
                -- Button row
                local zw=z.x2-z.x1+1
                local acts=G._valid_actions
                local n=#acts
                local lx=tx-z.x1  -- 0-indexed local x
                local bw=math.floor(zw/n)
                local btn_idx=math.floor(lx/bw)+1
                if btn_idx<1 then btn_idx=1 end
                if btn_idx>n then btn_idx=n end
                local action=acts[btn_idx]
                if action=="raise" then
                    G.waiting_raise=pid
                    send_p(pid,{type="enter_raise",
                                min_raise=G.current_bet+BIG_BLIND,
                                pot=G.pot,chips=G.chips[pid]})
                    render()
                else
                    do_action(pid,action)
                end
            end
            return
        end
    end
end

-- ── Main loop ─────────────────────────────────────────────────
render()
if modem then bcast({type="dealer_ready",num_players=NUM_PLAYERS}) end

while true do
    local ev={os.pullEvent()}
    if ev[1]=="monitor_touch" then
        handle_touch(ev[3],ev[4])
    elseif ev[1]=="modem_message" then
        local msg=textutils.unserialize(ev[5] or "")
        if msg then
            if msg.type=="hello" and msg.player then
                connected[msg.player]=true
                send_p(msg.player,{type="ack",player=msg.player,
                                   chips=G.chips[msg.player],phase=G.phase})
                render()
            elseif msg.type=="action" and msg.player then
                do_action(msg.player,msg.action,msg.raise_to)
            end
        end
    elseif ev[1]=="key" and ev[2]==keys.s then
        if G.phase=="waiting" or G.phase=="showdown" then start_hand() end
    end
end
