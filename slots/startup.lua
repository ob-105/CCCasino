-- slots/startup.lua
-- One computer drives up to 4 independent slot machine stations.
-- Hardware per station: wired modem on a side (back/right/left/front)
--   connected to a monitor + disk drive on that wired network.

pcall(function()
    local au = dofile("/casino/lib/autoupdate.lua")
    au.check({
        {"/lib/autoupdate.lua", "/casino/lib/autoupdate.lua"},
        {"/lib/wallet.lua",     "/casino/lib/wallet.lua"},
        {"/slots/startup.lua",  "/casino/slots/startup.lua"},
    })
end)

local wallet = dofile("/casino/lib/wallet.lua")
math.randomseed(os.epoch("utc"))

-- ── symbols & payouts ─────────────────────────────────────────────────────────
local SYMS = {
    { key="7",   disp=" 7 ", fg=colors.black, bg=colors.yellow, weight=3 },
    { key="BAR", disp="BAR", fg=colors.black, bg=colors.white,  weight=5 },
    { key="BEL", disp="BEL", fg=colors.black, bg=colors.orange, weight=5 },
    { key="CHR", disp="CHR", fg=colors.white, bg=colors.red,    weight=6 },
    { key="LEM", disp="LEM", fg=colors.black, bg=colors.lime,   weight=6 },
}
local POOL = {}
for _, s in ipairs(SYMS) do for _=1,s.weight do POOL[#POOL+1]=s end end
local function rsym() return POOL[math.random(#POOL)] end

local THREE_MULT = {["7"]=50, BAR=20, BEL=10, CHR=8, LEM=5}
local function calc_win(s1,s2,s3,bet)
    local k1,k2,k3 = s1.key,s2.key,s3.key
    if k1==k2 and k2==k3 then return bet*(THREE_MULT[k1] or 3) end
    local sv = (k1=="7" and 1 or 0)+(k2=="7" and 1 or 0)+(k3=="7" and 1 or 0)
    if sv>=2 then return bet*5 end
    if k1==k2 or k2==k3 or k1==k3 then return bet*2 end
    if k1=="CHR" or k2=="CHR" or k3=="CHR" then return bet end
    return 0
end

local BET_OPTS = {1,5,10,25,50,100,500}
local REEL_W   = 9  -- each reel is this many characters wide (includes borders)

-- ── station discovery ─────────────────────────────────────────────────────────
local SIDES = {"back","right","left","front"}
local stations   = {}
local mon_to_st  = {}

for _, side in ipairs(SIDES) do
    if peripheral.getType(side) == "modem" then
        local modem = peripheral.wrap(side)
        if modem.getNamesRemote then   -- wired modems only
            local mon_name, drv_name = nil, nil
            for _, name in ipairs(modem.getNamesRemote()) do
                local t = peripheral.getType(name)
                if t == "monitor" and not mon_name then mon_name = name end
                if t == "drive"   and not drv_name then drv_name = name end
            end
            if mon_name then
                local mon = peripheral.wrap(mon_name)
                for _, s in ipairs({3,2.5,2,1.5,1,0.5}) do
                    mon.setTextScale(s)
                    local w,h = mon.getSize()
                    if w >= 26 and h >= 12 then break end
                end
                local W,H = mon.getSize()
                local st = {
                    side=side, mon_name=mon_name, mon=mon, drv=drv_name,
                    W=W, H=H,
                    bet=10, reels={SYMS[4],SYMS[1],SYMS[3]},
                    last_win=nil, spinning=false, btns={},
                    wd=nil, chips=0,
                }
                stations[#stations+1] = st
                mon_to_st[mon_name]   = st
            end
        end
    end
end

-- fallback: direct peripherals (single-machine / dev mode)
if #stations == 0 then
    local mon = peripheral.find("monitor")
    if mon then
        mon.setTextScale(1)
        local W,H = mon.getSize()
        local drv_obj = peripheral.find("drive")
        local drv = drv_obj and peripheral.getName(drv_obj) or nil
        local mn  = peripheral.getName(mon)
        local st  = {
            side="direct", mon_name=mn, mon=mon, drv=drv,
            W=W, H=H,
            bet=10, reels={SYMS[4],SYMS[1],SYMS[3]},
            last_win=nil, spinning=false, btns={},
            wd=nil, chips=0,
        }
        stations[1] = st
        mon_to_st[mn] = st
    end
end

assert(#stations > 0, "No slot machine stations found. Attach wired modems with monitors.")

-- ── drawing helpers ───────────────────────────────────────────────────────────
local function fill(st,x1,y1,x2,y2,bg)
    st.mon.setBackgroundColor(bg)
    local row = string.rep(" ", math.max(0,x2-x1+1))
    for y=y1,y2 do st.mon.setCursorPos(x1,y); st.mon.write(row) end
end
local function mp(st,x,y,s,fg,bg)
    if bg then st.mon.setBackgroundColor(bg) end
    if fg then st.mon.setTextColor(fg) end
    st.mon.setCursorPos(x,y); st.mon.write(s)
end
local function centre(st,y,s,fg,bg)
    if bg then st.mon.setBackgroundColor(bg) end
    if fg then st.mon.setTextColor(fg) end
    local x = math.max(1, math.floor((st.W-#s)/2)+1)
    st.mon.setCursorPos(x,y); st.mon.write(s)
end
local function abtn(st,x1,y1,x2,y2,id,label,bg,fg)
    fill(st,x1,y1,x2,y2,bg)
    local lx = x1 + math.floor((x2-x1+1-#label)/2)
    local ly = y1 + math.floor((y2-y1)/2)
    mp(st,lx,ly,label,fg,bg)
    st.btns[#st.btns+1] = {x1=x1,y1=y1,x2=x2,y2=y2,id=id}
end

local function draw_reel(st,cx,cy,sym,stopped,flash_col)
    local cellbg = flash_col or (stopped and sym.bg or colors.gray)
    local cellfg = flash_col and colors.black or (stopped and sym.fg or colors.white)
    -- top strip: \x9f (solid teletext block) in cell colour on black
    st.mon.setTextColor(cellbg); st.mon.setBackgroundColor(colors.black)
    st.mon.setCursorPos(cx,cy); st.mon.write(string.rep("\x9f",REEL_W))
    -- symbol row
    fill(st,cx,cy+1,cx+REEL_W-1,cy+1,cellbg)
    local sx = cx + math.floor((REEL_W-#sym.disp)/2)
    st.mon.setTextColor(cellfg); st.mon.setBackgroundColor(cellbg)
    st.mon.setCursorPos(sx,cy+1)
    if stopped or flash_col then
        st.mon.write(sym.disp)
    else
        -- spinning blur: shade blocks in dark grey
        st.mon.setTextColor(colors.darkGray); st.mon.setBackgroundColor(colors.gray)
        st.mon.setCursorPos(cx,cy+1)
        st.mon.write(string.rep("\x7f",REEL_W))
    end
    -- bottom strip
    st.mon.setTextColor(cellbg); st.mon.setBackgroundColor(colors.black)
    st.mon.setCursorPos(cx,cy+2); st.mon.write(string.rep("\x9f",REEL_W))
end

-- ── wallet ────────────────────────────────────────────────────────────────────
local function refresh_wallet(st)
    st.wd, st.chips = nil, 0
    if st.drv and disk.isPresent(st.drv) then
        local w = wallet.load(st.drv)
        if w then st.wd=w; st.chips=w.balance end
    end
end
local function flush_wallet(st)
    if not st.wd then return end
    st.wd.balance = st.chips
    wallet.save(st.wd, st.drv)
end

-- ── layout ────────────────────────────────────────────────────────────────────
-- Fixed rows (works for H >= 12):
--   1-2  : animated header
--   3    : balance / disk status
--   4-6  : reels  (REEL_H = 3)
--   5    : payline (middle of reels)
--   8    : win / loss result
--   9    : bet selector
--   10-11: spin button  (or 10 only if H <= 12)
--   12+  : payout table if room
--   H    : LEAVE button
local L = { hdr1=1, hdr2=2, bal=3, ry=4, pl=5, res=8, by=9, sy=10 }

local HDR_COLS = {
    colors.red, colors.orange, colors.yellow, colors.lime,
    colors.green, colors.cyan, colors.blue, colors.purple,
    colors.magenta, colors.pink,
}
local PAYOUT_LINES = {
    " 7  7  7   x50  JACKPOT!",
    " BAR BAR BAR  x20",
    " BEL BEL BEL  x10",
    " CHR CHR CHR  x8",
    " LEM LEM LEM  x5",
    " Two 7s x5 | Pair x2 | Cherry x1",
}

-- ── render ────────────────────────────────────────────────────────────────────
local function render(st, disp_reels, stopped_flags)
    st.mon.setBackgroundColor(colors.black); st.mon.clear()
    st.btns = {}
    disp_reels    = disp_reels    or st.reels
    stopped_flags = stopped_flags or {true,true,true}
    local W, H = st.W, st.H

    -- animated header
    local t  = math.floor(os.epoch("utc") / 250) % #HDR_COLS
    local t2 = (t+1) % #HDR_COLS
    local hc1 = HDR_COLS[t+1]
    local hc2 = HDR_COLS[t2+1]
    fill(st,1,1,W,1,hc1)
    local stars = string.rep("\x9f", math.max(0,math.floor((W-16)/2)))
    centre(st,1, stars.."  LUCKY SLOTS  "..stars, colors.black, hc1)
    -- alternating \x9f blocks with swapped fg/bg per column — two-colour weave
    for i=1,W do
        st.mon.setTextColor(i%2==0 and hc1 or hc2)
        st.mon.setBackgroundColor(i%2==0 and hc2 or hc1)
        st.mon.setCursorPos(i,2); st.mon.write("\x9f")
    end

    -- balance row
    fill(st,1,3,W,3,colors.black)
    if st.wd then
        local name = (st.wd.player_name or "Player"):sub(1,12)
        mp(st,2,3, "> "..name, colors.white, colors.black)
        local cs = st.chips.."c"
        mp(st,W-#cs-1,3, cs, colors.yellow, colors.black)
    else
        centre(st,3, "  Insert chip disk  ", colors.orange, colors.black)
    end

    -- reels
    local rx = math.floor((W-(3*REEL_W+4))/2)+1
    for i=1,3 do
        draw_reel(st, rx+(i-1)*(REEL_W+2), L.ry, disp_reels[i], stopped_flags[i])
    end
    -- payline arrows
    st.mon.setBackgroundColor(colors.black); st.mon.setTextColor(colors.yellow)
    st.mon.setCursorPos(1,L.pl); st.mon.write(">")
    st.mon.setCursorPos(W,L.pl); st.mon.write("<")

    -- win/loss result
    fill(st,1,L.res,W,L.res,colors.black)
    if st.last_win ~= nil then
        if st.last_win > 0 then
            centre(st,L.res, "  *  WIN!  +"..st.last_win.."c  *  ", colors.black, colors.lime)
        else
            centre(st,L.res, "  No win this spin  ", colors.gray, colors.black)
        end
    end

    -- bet row
    fill(st,1,L.by,W,L.by,colors.black)
    mp(st,2,L.by, "BET:", colors.lightGray, colors.black)
    local bx=7
    for _,b in ipairs(BET_OPTS) do
        local lbl=tostring(b); local bw=#lbl+2
        if bx+bw <= W-1 then
            local sel=b==st.bet
            abtn(st, bx,L.by, bx+bw-1,L.by, "bet_"..b, lbl,
                sel and colors.orange or colors.gray,
                sel and colors.black  or colors.white)
            bx=bx+bw+1
        end
    end

    -- spin button
    local sh = H <= 12 and 1 or 2
    if L.sy+sh-1 <= H-1 then
        if st.spinning then
            fill(st,1,L.sy,W,L.sy+sh-1,colors.black)
            centre(st,L.sy, "  <<  SPINNING...  >>  ", colors.yellow, colors.black)
        elseif not st.wd then
            fill(st,1,L.sy,W,L.sy+sh-1,colors.black)
        elseif st.chips >= st.bet then
            local lbl="  >  SPIN  "..st.bet.."c  <  "
            local bx2=math.max(1,math.floor((W-#lbl)/2)+1)
            local ex=math.min(W,bx2+#lbl-1)
            abtn(st, bx2,L.sy, ex,L.sy+sh-1, "spin", lbl, colors.green, colors.black)
        else
            fill(st,1,L.sy,W,L.sy+sh-1,colors.black)
            centre(st,L.sy, "  Need "..st.bet.."c to spin  ", colors.red, colors.black)
        end
    end

    -- payout table (if room below spin button)
    local py = L.sy + sh + 1
    if py + #PAYOUT_LINES <= H-1 then
        fill(st,1,py-1,W,H-1,colors.black)
        mp(st,2,py-1,"Payouts:",colors.gray,colors.black)
        for i,line in ipairs(PAYOUT_LINES) do
            mp(st,3,py+i-1, line, colors.lightGray, colors.black)
        end
    end

    -- leave button
    abtn(st,1,H, math.max(2,math.floor(W/5)),H, "leave","LEAVE",colors.purple,colors.white)
end

-- ── spin ──────────────────────────────────────────────────────────────────────
local function do_spin(st)
    if st.chips < st.bet or st.spinning then return end
    st.spinning = true
    st.chips    = st.chips - st.bet

    local result  = {rsym(),rsym(),rsym()}
    local display = {rsym(),rsym(),rsym()}
    local stopped = {false,false,false}
    local stop_at = {16,22,28}

    for tick=1,30 do
        for i=1,3 do
            if tick >= stop_at[i] then stopped[i]=true; display[i]=result[i]
            else display[i]=rsym() end
        end
        render(st,display,stopped)
        sleep(0.04+tick*0.005)
    end

    local win = calc_win(result[1],result[2],result[3],st.bet)
    st.chips = st.chips + win
    st.last_win = win
    st.reels = result

    -- per-reel landing bounce
    local rx = math.floor((st.W-(3*REEL_W+4))/2)+1
    for j=1,3 do
        for i=1,4 do
            local fc = i%2==0 and result[j].bg or colors.lightGray
            draw_reel(st, rx+(j-1)*(REEL_W+2), L.ry, result[j], true, fc)
            sleep(0.07)
        end
    end

    if win >= st.bet*50 then
        -- JACKPOT: 10-frame full-screen color blast
        local jc={colors.yellow,colors.orange,colors.yellow,colors.lime,colors.yellow,
                  colors.orange,colors.yellow,colors.lime,colors.yellow,colors.orange}
        for _,c in ipairs(jc) do
            fill(st,1,1,st.W,st.H,c)
            centre(st,math.floor(st.H/2)-2, string.rep("\x9f",st.W-2), colors.black,c)
            centre(st,math.floor(st.H/2)-1, "  JACKPOT!!!  ",          colors.black,c)
            centre(st,math.floor(st.H/2),   "  +"..win.." CHIPS!  ",   colors.black,c)
            centre(st,math.floor(st.H/2)+1, "   7   7   7   ",         colors.black,c)
            centre(st,math.floor(st.H/2)+2, string.rep("\x9f",st.W-2), colors.black,c)
            sleep(0.15)
        end
        sleep(1.2)
    elseif win > 0 then
        -- win: 8-frame green/lime flash
        local wc={colors.lime,colors.green,colors.lime,colors.green,
                  colors.lime,colors.green,colors.lime,colors.green}
        for _,fc in ipairs(wc) do
            fill(st,1,1,st.W,st.H,fc)
            centre(st,math.floor(st.H/2)-1, string.rep("\x9f",st.W-2), colors.black,fc)
            centre(st,math.floor(st.H/2),   "  WIN!  +"..win.."c  ",   colors.black,fc)
            centre(st,math.floor(st.H/2)+1, string.rep("\x9f",st.W-2), colors.black,fc)
            sleep(0.1)
        end
        sleep(0.4)
    end

    flush_wallet(st)
    st.spinning = false
    render(st)
end

-- ── touch ─────────────────────────────────────────────────────────────────────
local function handle_touch(st,x,y)
    for _,b in ipairs(st.btns) do
        if x>=b.x1 and x<=b.x2 and y>=b.y1 and y<=b.y2 then
            if b.id=="spin" and not st.spinning then
                do_spin(st)
            elseif b.id=="leave" then
                flush_wallet(st)
                fill(st,1,1,st.W,st.H,colors.purple)
                centre(st,math.floor(st.H/2)-1,"  Saved "..st.chips.."c to disk  ",colors.white,colors.purple)
                centre(st,math.floor(st.H/2),  "  Goodbye!  ",                     colors.white,colors.purple)
                sleep(2)
                refresh_wallet(st)
                st.last_win = nil
                render(st)
            elseif b.id:sub(1,4)=="bet_" then
                st.bet = tonumber(b.id:sub(5)) or st.bet
                render(st)
            end
            return
        end
    end
end

-- ── per-station loop ──────────────────────────────────────────────────────────
local function run_station(st)
    refresh_wallet(st)
    render(st)
    local anim_tmr = os.startTimer(0.3)
    while true do
        local ev = {os.pullEvent()}
        if ev[1]=="monitor_touch" and ev[2]==st.mon_name then
            handle_touch(st,ev[3],ev[4])
            anim_tmr = os.startTimer(0.3)
        elseif (ev[1]=="disk" or ev[1]=="disk_eject") and ev[2]==st.drv then
            refresh_wallet(st)
            st.last_win = nil
            render(st)
            anim_tmr = os.startTimer(0.3)
        elseif ev[1]=="timer" and ev[2]==anim_tmr then
            if not st.spinning then render(st) end
            anim_tmr = os.startTimer(0.3)
        end
    end
end

-- ── launch ────────────────────────────────────────────────────────────────────
if #stations == 1 then
    run_station(stations[1])
else
    local tasks = {}
    for _,st in ipairs(stations) do tasks[#tasks+1]=function() run_station(st) end end
    parallel.waitForAll(table.unpack(tasks))
end
