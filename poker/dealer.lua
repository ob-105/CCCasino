-- poker/dealer.lua
-- Texas Hold'em — dealer computer + center community card display
-- Monitor: any size, attached to this computer (center of the table)
-- Modem:   wireless, listens ch10, broadcasts ch11
-- Run: dealer [num_players]   default 4

local NUM_PLAYERS = tonumber(arg and arg[1]) or 4
local START_CHIPS = 500   -- fallback for players without a wallet disk
local SMALL_BLIND = 5
local BIG_BLIND   = 10
local DEALER_CH   = 10
local BCAST_CH    = 11

math.randomseed(os.epoch("utc"))

-- ── Peripherals ───────────────────────────────────────────────
local mon = peripheral.find("monitor")
assert(mon, "No monitor found — attach a monitor to the dealer computer")
mon.setTextScale(0.5)
local W, H = mon.getSize()

local modem = peripheral.find("modem")
if modem then modem.open(DEALER_CH); modem.open(BCAST_CH) end

-- ── Cards ─────────────────────────────────────────────────────
local SUITS    = {"H","D","C","S"}
local RANKS    = {"A","2","3","4","5","6","7","8","9","T","J","Q","K"}
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

-- ── Game state ────────────────────────────────────────────────
local G = {
    deck={}, top=1, community={},
    hands={}, chips={}, bets={}, pot=0,
    dealer_btn=1, phase="waiting",
    active={}, turn=0, current_bet=0,
    acted={}, result_lines={},
}
local connected     = {}
local player_names  = {}   -- player_names[i] = display name from disk (or "P<i>")
for i=1,NUM_PLAYERS do
    G.chips[i]=START_CHIPS; G.bets[i]=0
    G.active[i]=false; G.acted[i]=false; G.hands[i]={}
    player_names[i] = "P"..i
end

-- ── Modem ─────────────────────────────────────────────────────
local function send_p(pid,msg) msg.target=pid; if modem then modem.transmit(BCAST_CH,DEALER_CH,textutils.serialize(msg)) end end
local function bcast(msg)      msg.target=0;   if modem then modem.transmit(BCAST_CH,DEALER_CH,textutils.serialize(msg)) end end

-- ── Drawing ───────────────────────────────────────────────────
local function mfill(x1,y1,x2,y2,bg,char)
    mon.setBackgroundColor(bg)
    local row=string.rep(char or " ",x2-x1+1)
    for y=y1,y2 do mon.setCursorPos(x1,y); mon.write(row) end
end
local function mprint(x,y,txt,fg,bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(x,y); mon.write(txt)
end
local function mcentre(y,txt,fg,bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(math.floor((W-#txt)/2)+1,y); mon.write(txt)
end

-- Draw one community card: 5 wide x 3 tall
local function draw_comm_card(x,y,card,flash)
    if not card then
        mfill(x,y,x+4,y+2,colors.green)
        mon.setTextColor(colors.lime)
        mon.setCursorPos(x,y);   mon.write("+---+")
        mon.setCursorPos(x,y+1); mon.write("|   |")
        mon.setCursorPos(x,y+2); mon.write("+---+")
        return
    end
    local bg = flash and colors.yellow or colors.white
    local sc = SUIT_COL[card.s] or colors.gray
    local r  = card.r
    mon.setBackgroundColor(bg); mon.setTextColor(sc)
    mon.setCursorPos(x,y);   mon.write("+---+")
    -- inner 3 chars: rank left, suit right
    local inner = r..string.rep(" ",2-#r)..card.s
    mon.setCursorPos(x,y+1); mon.write("|"..inner.."|")
    mon.setCursorPos(x,y+2); mon.write("+---+")
end

local PHASE_LABEL={waiting="Waiting",preflop="Pre-Flop",flop="Flop",
                   turn="Turn",river="River",showdown="Showdown"}

local function render()
    mon.setBackgroundColor(colors.green); mon.clear()

    -- Title
    mfill(1,1,W,1,colors.black)
    mcentre(1," TEXAS HOLD'EM ",colors.yellow,colors.black)

    -- Phase + pot
    mfill(1,2,W,2,colors.gray)
    local ph=PHASE_LABEL[G.phase] or G.phase
    mprint(2,2,ph,colors.white,colors.gray)
    local pot_str="POT: "..G.pot
    mprint(W-#pot_str,2,pot_str,colors.yellow,colors.gray)

    -- Community cards, centred, y=4..6
    local cw=5; local gap=1; local total=5*cw+4*gap
    local cx=math.floor((W-total)/2)+1
    for i=1,5 do
        draw_comm_card(cx+(i-1)*(cw+gap), 4, G.community[i], false)
    end

    -- Player status list
    local row=8
    mfill(1,row-1,W,row-1,colors.black)
    mcentre(row-1,"Players",colors.gray,colors.black)
    for i=1,NUM_PLAYERS do
        if row>H-2 then break end
        local bg=colors.black
        local fg=colors.lightGray
        local status
        if not connected[i] then
            status="offline"
        elseif G.phase~="waiting" and not G.active[i] then
            status="folded"
        elseif G.turn==i and G.phase~="waiting" then
            status="ACTING"; bg=colors.lime; fg=colors.black
        else
            status="chips:"..G.chips[i].." bet:"..G.bets[i]
        end
        local d=G.dealer_btn==i and "(D) " or "    "
        mfill(1,row,W,row,bg)
        mprint(2,row,(player_names[i] or "P"..i)..d..status,fg,bg)
        row=row+1
    end

    -- Result lines
    if G.phase=="showdown" and #G.result_lines>0 then
        local ry=row+1
        mfill(1,ry-1,W,ry-1,colors.black)
        for i,line in ipairs(G.result_lines) do
            if ry<=H-1 then
                mfill(1,ry,W,ry,colors.black)
                mcentre(ry,line,colors.yellow,colors.black)
                ry=ry+1
            end
        end
    end

    -- Start / Next hand button
    if G.phase=="waiting" or G.phase=="showdown" then
        local btn=G.phase=="waiting" and "[ START GAME ]" or "[ NEXT HAND ]"
        local bx=math.floor((W-#btn)/2)+1
        mfill(bx,H,bx+#btn-1,H,colors.lime)
        mprint(bx,H,btn,colors.black,colors.lime)
    end
end

-- ── Animations ────────────────────────────────────────────────
local function anim_deal_flash(pid)
    -- Brief flash in player status row
    local row=8+(pid-1)
    if row>H then return end
    mfill(1,row,W,row,colors.white); sleep(0.07)
    render()
end

local function anim_community_card(idx)
    local cw=5; local gap=1; local total=5*cw+4*gap
    local cx=math.floor((W-total)/2)+1
    local x=cx+(idx-1)*(cw+gap)
    draw_comm_card(x,4,G.community[idx],true); sleep(0.15)
    draw_comm_card(x,4,G.community[idx],false)
end

local function anim_win(winners)
    if not winners or #winners==0 then return end
    for _=1,3 do
        for _,w in ipairs(winners) do
            local row=8+(w-1)
            if row<=H then mfill(1,row,W,row,colors.yellow) end
        end
        sleep(0.12)
        render(); sleep(0.1)
    end
end

-- ── Game helpers ──────────────────────────────────────────────
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

local advance_phase

local function bcast_state()
    bcast({type="state",phase=G.phase,community=G.community,
           pot=G.pot,bets=G.bets,chips=G.chips,active=G.active,turn=G.turn,
           current_bet=G.current_bet})
end

local function notify_turn(p)
    local call_amt=math.max(0,G.current_bet-(G.bets[p] or 0))
    call_amt=math.min(call_amt,G.chips[p] or 0)
    local acts={"fold"}
    if call_amt==0 then acts[#acts+1]="check" else acts[#acts+1]="call" end
    if (G.chips[p] or 0)>call_amt then acts[#acts+1]="raise" end
    send_p(p,{type="your_turn",valid_actions=acts,
              call_amount=call_amt,pot=G.pot,current_bet=G.current_bet})
end

-- ── Betting ───────────────────────────────────────────────────
local function post_bet(p,amount)
    amount=math.min(amount,G.chips[p] or 0)
    G.chips[p]=(G.chips[p] or 0)-amount
    G.bets[p]=(G.bets[p] or 0)+amount
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
        if G.active[p] and (not G.acted[p] or (G.bets[p] or 0)<G.current_bet) then
            G.turn=p; bcast_state(); render(); notify_turn(p); return
        end
    end
    advance_phase()
end

local function do_action(pid,action,raise_to)
    if G.turn~=pid then return end
    if action=="fold" then
        G.active[pid]=false; G.acted[pid]=true
    elseif action=="check" then
        G.acted[pid]=true
    elseif action=="call" then
        post_bet(pid,math.max(0,G.current_bet-(G.bets[pid] or 0)))
    elseif action=="raise" then
        local min_r=G.current_bet+BIG_BLIND
        local to=math.max(min_r,raise_to or min_r)
        post_bet(pid,to-(G.bets[pid] or 0))
    end
    next_turn()
end

-- ── Phase transitions ─────────────────────────────────────────
local function reset_street()
    for i=1,NUM_PLAYERS do G.bets[i]=0; G.acted[i]=false end
    G.current_bet=0
end
local function start_street(first)
    G.turn=first; bcast_state(); render(); notify_turn(first)
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
        G.chips[w]=(G.chips[w] or 0)+share
        G.result_lines[#G.result_lines+1]="P"..w.." wins "..share.." ("..hand_name(scores[w])..")"
    end
    bcast_state()
    for i=1,NUM_PLAYERS do
        local won=false; for _,w in ipairs(winners) do if w==i then won=true end end
        send_p(i,{type="result",won=won,winners=winners,
                  result_lines=G.result_lines,
                  hand_name=scores[i] and hand_name(scores[i]) or nil,
                  community=G.community,
                  final_chips=G.chips[i]})
    end
    anim_win(winners); render()
end

advance_phase = function()
    if count_active()<=1 then
        local winner=nil
        for i=1,NUM_PLAYERS do if G.active[i] then winner=i end end
        if winner then
            G.chips[winner]=(G.chips[winner] or 0)+G.pot
            G.result_lines={"P"..winner.." wins "..G.pot.." (all folded)"}
        end
        G.phase="showdown"; bcast_state()
        -- notify all connected players of their final chip count for disk write
        for i=1,NUM_PLAYERS do
            if connected[i] then
                local won=(i==winner)
                send_p(i,{type="result",won=won,winners=winner and {winner} or {},
                          result_lines=G.result_lines,final_chips=G.chips[i]})
            end
        end
        if winner then anim_win({winner}) end
        render(); return
    end
    local first=next_active_after(G.dealer_btn)
    if G.phase=="preflop" then
        G.phase="flop"
        G.community[1]=deal_card(); G.community[2]=deal_card(); G.community[3]=deal_card()
        reset_street(); bcast({type="community",cards=G.community})
        render(); for i=1,3 do anim_community_card(i); sleep(0.1) end
        start_street(first)
    elseif G.phase=="flop" then
        G.phase="turn"; G.community[4]=deal_card()
        reset_street(); bcast({type="community",cards=G.community})
        render(); anim_community_card(4); start_street(first)
    elseif G.phase=="turn" then
        G.phase="river"; G.community[5]=deal_card()
        reset_street(); bcast({type="community",cards=G.community})
        render(); anim_community_card(5); start_street(first)
    elseif G.phase=="river" then
        G.phase="showdown"; do_showdown()
    end
end

-- ── Start hand ────────────────────────────────────────────────
local function start_hand()
    local cnt=0; for i=1,NUM_PLAYERS do if connected[i] then cnt=cnt+1 end end
    if cnt<2 then G.result_lines={"Need 2+ players"}; render(); return end
    G.deck=new_deck(); shuffle(G.deck); G.top=1
    G.community={}; G.pot=0; G.current_bet=0; G.result_lines={}
    G.dealer_btn=next_active_after(G.dealer_btn) or 1
    for i=1,NUM_PLAYERS do
        G.active[i]=connected[i] and (G.chips[i] or 0)>0
        G.bets[i]=0; G.acted[i]=false; G.hands[i]={}
    end
    for round=1,2 do
        for p=1,NUM_PLAYERS do
            if G.active[p] then
                G.hands[p][round]=deal_card()
                anim_deal_flash(p); sleep(0.08)
            end
        end
    end
    for i=1,NUM_PLAYERS do
        if G.active[i] then
            send_p(i,{type="deal",hand=G.hands[i],player=i,dealer=G.dealer_btn})
        end
    end
    local sb=next_active_after(G.dealer_btn)
    local bb=next_active_after(sb)
    post_bet(sb,SMALL_BLIND); post_bet(bb,BIG_BLIND)
    G.acted[sb]=false; G.acted[bb]=false
    G.current_bet=BIG_BLIND
    G.phase="preflop"; G.turn=next_active_after(bb)
    bcast_state(); render(); notify_turn(G.turn)
end

-- ── Touch ─────────────────────────────────────────────────────
local function handle_touch(_,ty)
    if (G.phase=="waiting" or G.phase=="showdown") and ty==H then
        start_hand()
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
                local p = msg.player
                -- Only load disk balance on first connect; preserve in-game chips on reconnect
                if not connected[p] and msg.disk_balance and msg.disk_balance > 0 then
                    G.chips[p] = msg.disk_balance
                end
                if msg.player_name and msg.player_name ~= "" then
                    player_names[p] = msg.player_name
                end
                connected[p] = true
                send_p(p,{type="ack",player=p,
                          chips=G.chips[p],phase=G.phase})
                render()
            elseif msg.type=="action" and msg.player then
                do_action(msg.player,msg.action,msg.raise_to)
            end
        end
    elseif ev[1]=="key" and ev[2]==keys.s then
        if G.phase=="waiting" or G.phase=="showdown" then start_hand() end
    end
end
