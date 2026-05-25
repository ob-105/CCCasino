-- roulette/table.lua
-- Single-computer all-in-one roulette table.
--
-- Wiring (all wired modems + networking cable):
--   Computer back   → wired modem → cable → [wired modem on dealer monitor]
--   Computer bottom → wired modem → cable → [wired modem on Seat 1 monitor]
--                                          → cable → [wired modem on Seat 1 disk drive]
--   Computer left   → wired modem → cable → Seat 2 monitor + disk drive
--   Computer right  → wired modem → cable → Seat 3 monitor + disk drive
--   Computer front  → wired modem → cable → Seat 4 monitor + disk drive
--
-- Each monitor and disk drive needs its own wired modem attached to join the network.

pcall(function()
    local au = dofile("/casino/lib/autoupdate.lua")
    au.check({
        {"/lib/autoupdate.lua",   "/casino/lib/autoupdate.lua"},
        {"/lib/wallet.lua",       "/casino/lib/wallet.lua"},
        {"/roulette/table.lua",   "/casino/roulette/table.lua"},
    })
end)

local NUM_SEATS  = 4
local SPIN_DELAY = 30

math.randomseed(os.epoch("utc"))
local wallet = dofile("/casino/lib/wallet.lua")

-- ── hardware discovery ────────────────────────────────────────────────────────
-- Scans one side's wired modem network; returns {monitor=name, drive=name}.
local function scan_side(side)
    if not peripheral.isPresent(side) then return {} end
    if peripheral.getType(side) ~= "modem" then return {} end
    local m = peripheral.wrap(side)
    if type(m.getNamesRemote) ~= "function" then return {} end  -- wireless modem
    local found = {}
    for _, name in ipairs(m.getNamesRemote()) do
        local t = peripheral.getType(name)
        if t and not found[t] then found[t] = name end
    end
    return found
end

local back_net   = scan_side("back")
assert(back_net.monitor, "No monitor found on back wired network (dealer display)")
local dealer_mon = peripheral.wrap(back_net.monitor)
-- Pick the largest text scale where the monitor is still at least 30 chars wide.
-- On a 5×3 monitor this lands around scale 3–4, making text readable from a distance.
for _, s in ipairs({5.0, 4.5, 4.0, 3.5, 3.0, 2.5, 2.0, 1.5, 1.0}) do
    dealer_mon.setTextScale(s)
    local w, h = dealer_mon.getSize()
    if w >= 20 and h >= 7 then break end  -- biggest scale that still fits the 7-row layout
end
local DW, DH = dealer_mon.getSize()

local SEAT_SIDES = {"bottom", "left", "right", "front"}
local p = {}
for seat = 1, NUM_SEATS do
    local net = scan_side(SEAT_SIDES[seat])
    local mon = net.monitor and peripheral.wrap(net.monitor)
    if mon then mon.setTextScale(0.5) end
    local pw, ph = 0, 0
    if mon then pw, ph = mon.getSize() end
    p[seat] = {
        mon        = mon,
        mon_name   = net.monitor,
        drv        = net.drive,
        wd         = nil,
        chips      = 0,
        sbets      = {},
        obets      = {red=0,black=0,odd=0,even=0,low=0,high=0,d1=0,d2=0,d3=0,c1=0,c2=0,c3=0},
        chip_val   = 10,
        phase      = "attract",
        last_num   = nil,
        last_net   = nil,
        had_bets   = false,
        spin_frame = 0,
        zones      = {},
        W = pw, H = ph,
    }
end

-- Reverse lookup: peripheral name → seat number
local mon_to_seat = {}
local drv_to_seat = {}
for seat = 1, NUM_SEATS do
    if p[seat].mon_name then mon_to_seat[p[seat].mon_name] = seat end
    if p[seat].drv      then drv_to_seat[p[seat].drv]      = seat end
end

-- ── roulette constants ────────────────────────────────────────────────────────
local WHEEL = {0,32,15,19,4,21,2,25,17,34,6,27,13,36,11,30,8,23,10,5,24,16,33,1,20,14,31,9,22,18,29,7,28,12,35,3,26}
local RED_SET = {}
for _, n in ipairs({1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36}) do RED_SET[n]=true end

-- Casino chip colours (background / foreground per denomination)
local CHIP_BG = {[1]=colors.white,[5]=colors.red,[10]=colors.blue,[25]=colors.lime,[50]=colors.gray,[100]=colors.purple}
local CHIP_FG = {[1]=colors.black,[5]=colors.white,[10]=colors.white,[25]=colors.black,[50]=colors.white,[100]=colors.white}

local function num_bg(n)
    if n==0 then return colors.green end
    if RED_SET[n] then return colors.red end
    return colors.gray
end
local function wheel_pos(n)
    for i,v in ipairs(WHEEL) do if v==n then return i end end
    return 1
end

-- ── game state ────────────────────────────────────────────────────────────────
local game_phase = "betting"
local history    = {}
local last_num   = nil
local countdown  = 0
local spin_tmr   = nil
local tick_tmr   = nil

-- ── per-player helpers ────────────────────────────────────────────────────────
local function refresh_wallet(seat)
    local ps = p[seat]
    ps.wd = nil; ps.chips = 0
    if ps.drv and disk.isPresent(ps.drv) then
        local w = wallet.load(ps.drv)
        if w then ps.wd = w; ps.chips = w.balance end
    end
end

local function flush_wallet(seat)
    local ps = p[seat]
    if not ps.wd then return end
    ps.wd.balance = ps.chips
    wallet.save(ps.wd, ps.drv)
end

local function total_bets(seat)
    local t = 0
    for _,v in pairs(p[seat].sbets) do t=t+v end
    for _,v in pairs(p[seat].obets) do t=t+v end
    return t
end

local function clear_bets(seat)
    p[seat].sbets = {}
    for k in pairs(p[seat].obets) do p[seat].obets[k] = 0 end
end

local function calc_payout(seat, result)
    local ps = p[seat]
    local win = 0
    for n, amt in pairs(ps.sbets) do
        if n == result then win = win + amt * 36 end
    end
    if result > 0 then
        local ob = ps.obets
        local function em(amt, cond) if cond and amt>0 then win=win+amt*2 end end
        em(ob.red,   RED_SET[result]==true)
        em(ob.black, not RED_SET[result])
        em(ob.odd,   result%2==1)
        em(ob.even,  result%2==0)
        em(ob.low,   result>=1  and result<=18)
        em(ob.high,  result>=19 and result<=36)
        local function doz(amt,lo,hi) if result>=lo and result<=hi and amt>0 then win=win+amt*3 end end
        doz(ob.d1,1,12); doz(ob.d2,13,24); doz(ob.d3,25,36)
        local col = result%3
        if col==1 and ob.c1>0 then win=win+ob.c1*3 end
        if col==2 and ob.c2>0 then win=win+ob.c2*3 end
        if col==0 and ob.c3>0 then win=win+ob.c3*3 end
    end
    return win
end

local function count_ready()
    local n = 0
    for seat = 1, NUM_SEATS do if p[seat].phase=="ready" then n=n+1 end end
    return n
end
local function count_connected()
    local n = 0
    for seat = 1, NUM_SEATS do if p[seat].phase~="attract" then n=n+1 end end
    return n
end
local function all_ready()
    if count_connected()==0 then return false end
    for seat = 1, NUM_SEATS do if p[seat].phase=="betting" then return false end end
    return true
end
local function cancel_countdown()
    spin_tmr=nil; tick_tmr=nil; countdown=0
end
local function start_countdown()
    cancel_countdown()
    countdown = SPIN_DELAY
    spin_tmr  = os.startTimer(SPIN_DELAY)
    tick_tmr  = os.startTimer(1)
end

-- ── drawing context (set before any draw call) ────────────────────────────────
local M, CW, CH, CZ   -- current monitor, width, height, zones table

local function fill(x1,y1,x2,y2,bg)
    M.setBackgroundColor(bg)
    local row = string.rep(" ",x2-x1+1)
    for y=y1,y2 do M.setCursorPos(x1,y); M.write(row) end
end
local function mp(x,y,s,fg,bg)
    if bg then M.setBackgroundColor(bg) end
    if fg then M.setTextColor(fg) end
    M.setCursorPos(x,y); M.write(s)
end
local function centre(y,s,fg,bg)
    if bg then M.setBackgroundColor(bg) end
    if fg then M.setTextColor(fg) end
    M.setCursorPos(math.max(1,math.floor((CW-#s)/2)+1),y); M.write(s)
end
local function bcentre(y,x1,x2,s,fg,bg)
    local w=x2-x1+1; fill(x1,y,x2,y,bg)
    local ox=x1+math.floor((w-#s)/2); if ox<x1 then ox=x1 end
    M.setCursorPos(ox,y); M.setTextColor(fg); M.write(s:sub(1,w))
end
local function add_zone(x1,y1,x2,y2,kind,key)
    CZ[#CZ+1]={x1=x1,y1=y1,x2=x2,y2=y2,kind=kind,key=key}
end

-- ── dealer render ─────────────────────────────────────────────────────────────
local CELL_W      = 5
local STRIP_CELLS = math.max(3, math.floor((DW - 6) / CELL_W))
if STRIP_CELLS % 2 == 0 then STRIP_CELLS = STRIP_CELLS - 1 end  -- keep odd so there's a center cell

local function draw_strip(center, highlight)
    local total_w = STRIP_CELLS*CELL_W
    local sx      = math.floor((CW-total_w)/2)+1
    fill(1,3,CW,3,colors.black)
    for i = 1, STRIP_CELLS do
        local offset = i-math.ceil(STRIP_CELLS/2)
        local idx    = ((center+offset-1) % #WHEEL)+1
        local n      = WHEEL[idx]
        local mid    = (i==math.ceil(STRIP_CELLS/2))
        local bg     = mid and colors.yellow or num_bg(n)
        local fg     = mid and colors.black  or colors.white
        if highlight==n and mid then bg=colors.lime; fg=colors.black end
        local cx     = sx+(i-1)*CELL_W
        fill(cx,3,cx+CELL_W-1,3,bg)
        mp(cx,3,string.format(" %2d  ",n),fg,bg)  -- 5-char cell for CELL_W=5
    end
    M.setBackgroundColor(colors.black); M.setTextColor(colors.white)
    local asx = math.max(1,sx-2)
    M.setCursorPos(asx,3); M.write("<<")
    if sx+total_w+1<=CW then M.setCursorPos(sx+total_w+1,3); M.write(">>") end
end

local function render_dealer()
    M=dealer_mon; CW=DW; CH=DH; CZ={}
    M.setBackgroundColor(colors.black); M.clear()

    -- Animation phase derived from wall-clock time (no extra timer needed)
    local t = math.floor(os.epoch("utc") / 400) % 8

    -- ── row 1: animated header ────────────────────────────────────────────────
    local hdr_bg
    if game_phase=="result" and last_num~=nil then
        hdr_bg = num_bg(last_num)
    elseif game_phase=="spinning" then
        local sc={colors.orange,colors.yellow,colors.orange,colors.red,colors.orange,colors.yellow,colors.orange,colors.red}
        hdr_bg = sc[t+1]
    elseif countdown>0 then
        if countdown<=5 then
            hdr_bg = t%2==0 and colors.red or colors.orange
        elseif countdown<=15 then
            hdr_bg = t%2==0 and colors.orange or colors.yellow
        else
            hdr_bg = colors.yellow
        end
    else
        local ic={colors.green,colors.lime,colors.green,colors.green,colors.lime,colors.green,colors.green,colors.lime}
        hdr_bg = ic[t+1]
    end
    fill(1,1,CW,1,hdr_bg)
    centre(1,"***  ROULETTE  ***",colors.black,hdr_bg)

    -- ── row 2: phase / countdown / status ─────────────────────────────────────
    fill(1,2,CW,2,colors.black)
    if game_phase=="spinning" then
        fill(1,2,CW,2,colors.orange)
        centre(2,"  SPINNING!  ",colors.black,colors.orange)
    elseif countdown>0 then
        local pc
        if countdown<=5 then pc = t%2==0 and colors.red or colors.orange
        elseif countdown<=15 then pc = t%2==0 and colors.orange or colors.yellow
        else pc = colors.yellow end
        fill(1,2,CW,2,pc)
        centre(2,"  Spinning in "..countdown.."s  ",colors.black,pc)
    else
        local nr=count_ready(); local nc=count_connected()
        if nc==0 then
            centre(2,"Waiting for players...",colors.gray,colors.black)
        elseif nr==0 then
            centre(2,"Bets open  ("..nc.." player"..(nc~=1 and "s" or "")..")",colors.lime,colors.black)
        elseif nr<2 then
            centre(2,"("..nr.."/"..nc.." ready — need 2+)",colors.gray,colors.black)
        else
            fill(1,2,CW,2,colors.lime)
            centre(2,"  "..nr.." / "..nc.." ready!  ",colors.black,colors.lime)
        end
    end

    -- ── row 3: wheel strip ────────────────────────────────────────────────────
    if last_num~=nil then
        draw_strip(wheel_pos(last_num), game_phase=="result" and last_num or nil)
    else
        fill(1,3,CW,3,colors.black)
        centre(3," <  <  <  <  < ",colors.gray,colors.black)
    end

    -- ── rows 4-5: result / spinning effect ────────────────────────────────────
    fill(1,4,CW,5,colors.black)
    if game_phase=="result" and last_num~=nil then
        local rb = last_num==0 and "Green" or (RED_SET[last_num] and "Red" or "Black")
        local bg = num_bg(last_num)
        fill(1,4,CW,5,bg)
        centre(4,"  "..last_num.."  ",colors.white,bg)
        centre(5,"  "..rb:upper().."  ",colors.white,bg)
    elseif game_phase=="spinning" then
        local sc2={colors.orange,colors.yellow,colors.orange,colors.red,colors.orange,colors.yellow,colors.orange,colors.red}
        local sbg=sc2[t+1]
        fill(1,4,CW,4,sbg)
        centre(4," >  <  >  <  > ",colors.black,sbg)
        fill(1,5,CW,5,colors.black)
        centre(5,string.rep("=",math.min(CW-4,16)),colors.gray,colors.black)
    end

    -- ── row 6: player status ──────────────────────────────────────────────────
    if CH>=6 then
        fill(1,6,CW,6,colors.black)
        mp(2,6,"P:",colors.gray,colors.black)
        local px=5; local any=false
        for seat=1,NUM_SEATS do
            if p[seat].phase~="attract" then
                any=true
                local col = p[seat].phase=="ready" and colors.lime or colors.orange
                local tag = "P"..seat.." "
                if px+#tag>CW then break end
                mp(px,6,tag,col,colors.black); px=px+#tag+1
            end
        end
        if not any then mp(5,6,"(no players)",colors.gray,colors.black) end
    end

    -- ── row 7: history ────────────────────────────────────────────────────────
    if CH>=7 and #history>0 then
        fill(1,7,CW,CH,colors.black)
        mp(2,7,":",colors.gray,colors.black)
        local hx=4
        for i=#history,math.max(1,#history-10),-1 do
            local n=history[i]; local lbl=string.format(" %d ",n)
            if hx+#lbl-1<=CW then
                fill(hx,7,hx+#lbl-1,7,num_bg(n))
                mp(hx,7,lbl,colors.white,num_bg(n)); hx=hx+#lbl+1
            end
        end
    end
end

-- ── player render ─────────────────────────────────────────────────────────────
local SPIN_FRAMES = {"  <  SPINNING  >  "," ><  SPINNING ><  ","><<  SPINNING><< "}
local CW_B=3; local BOARD_X=2; local ZERO_W=4; local NUM_X=BOARD_X+ZERO_W

local function draw_board(seat, result_hl)
    local ps = p[seat]
    local by = 3
    local z_bg = (result_hl==0) and colors.lime or colors.green
    fill(BOARD_X,by,BOARD_X+ZERO_W-1,by+2,z_bg)
    local zbet=ps.sbets[0] or 0
    mp(BOARD_X+1,by+1,zbet>0 and tostring(zbet) or " 0",zbet>0 and colors.black or colors.white,z_bg)
    add_zone(BOARD_X,by,BOARD_X+ZERO_W-1,by+2,"straight",0)

    for n=1,36 do
        local col=math.ceil(n/3)
        local row=n%3==0 and 1 or (n%3==2 and 2 or 3)
        local nx=NUM_X+(col-1)*CW_B; local ny=by+(row-1)
        local bet=ps.sbets[n] or 0
        local hl=(result_hl==n)
        local bg=hl and colors.yellow or (bet>0 and colors.orange or num_bg(n))
        local fg=(hl or bet>0) and colors.black or colors.white
        local lbl
        if bet>0 then
            lbl=bet>=100 and tostring(bet):sub(1,3) or bet>=10 and tostring(bet).." " or " "..tostring(bet)
        elseif n<10 then lbl=" "..n.." " else lbl=tostring(n).." " end
        lbl=lbl:sub(1,CW_B); if #lbl<CW_B then lbl=lbl..string.rep(" ",CW_B-#lbl) end
        mp(nx,ny,lbl,fg,bg)
        add_zone(nx,ny,nx+CW_B-1,ny,"straight",n)
    end

    local cx=NUM_X+12*CW_B+1
    for i,key in ipairs({"c3","c2","c1"}) do
        local amt=ps.obets[key] or 0
        local bg=amt>0 and colors.orange or colors.gray
        local lbl=amt>0 and tostring(amt):sub(1,3) or (key=="c3" and "C3 " or key=="c2" and "C2 " or "C1 ")
        mp(cx,by+(i-1),lbl,amt>0 and colors.black or colors.white,bg)
        add_zone(cx,by+(i-1),cx+2,by+(i-1),"outside",key)
    end

    local dz=by+3; local dw=math.floor(12*CW_B/3)
    local function draw_obet(x,y,w,key,label,base_bg)
        local amt=ps.obets[key] or 0
        local bg=amt>0 and colors.orange or base_bg
        local fg=amt>0 and colors.black or colors.white
        local lbl=amt>0 and (label:sub(1,w-2).."* ") or label
        lbl=lbl:sub(1,w); if #lbl<w then lbl=lbl..string.rep(" ",w-#lbl) end
        mp(x,y,lbl,fg,bg); add_zone(x,y,x+w-1,y,"outside",key)
    end
    draw_obet(NUM_X,    dz,dw,"d1","1st 12",colors.gray)
    draw_obet(NUM_X+dw, dz,dw,"d2","2nd 12",colors.gray)
    draw_obet(NUM_X+dw*2,dz,dw,"d3","3rd 12",colors.gray)
    local ow=math.floor(12*CW_B/6); local out_y=dz+1
    local outs={{"low","1-18 ",colors.gray},{"even","EVEN ",colors.gray},{"red","RED  ",colors.red},
                {"black","BLK  ",colors.gray},{"odd","ODD  ",colors.gray},{"high","19-36",colors.gray}}
    for i,o in ipairs(outs) do draw_obet(NUM_X+(i-1)*ow,out_y,ow,o[1],o[2],o[3]) end
end

local function render_player(seat, result_hl)
    local ps = p[seat]
    if not ps.mon then return end
    M=ps.mon; CW=ps.W; CH=ps.H; ps.zones={}; CZ=ps.zones

    -- ── attract screen ────────────────────────────────────────────────────────
    if ps.phase=="attract" then
        M.setBackgroundColor(colors.black); M.clear()
        fill(1,1,CW,1,colors.green)
        centre(1,"***  ROULETTE  ***",colors.black,colors.green)
        local my=math.floor(CH/2)
        centre(my,  "  Seat "..seat.."  ",  colors.yellow, colors.black)
        centre(my+2,"Insert your chip disk", colors.white,  colors.black)
        return
    end

    M.setBackgroundColor(colors.black); M.clear()

    -- ── row 1: name (left) + balance (right) on green bar ────────────────────
    fill(1,1,CW,1,colors.green)
    local pname     = ps.wd and ps.wd.player_name or ("Seat "..seat)
    local chips_str = tostring(ps.chips).."c "
    local bc   = ps.chips>500 and colors.lime or ps.chips>100 and colors.white or colors.yellow
    local bcol = ps.wd and bc or colors.orange
    mp(CW-#chips_str, 1, chips_str, bcol, colors.green)
    mp(2, 1, pname:sub(1, CW-#chips_str-3), colors.black, colors.green)

    -- ── row 2: chip selector ─────────────────────────────────────────────────
    fill(1,2,CW,2,colors.black)
    local cx=2
    for _,cv in ipairs({1,5,10,25,50,100}) do
        local lbl=tostring(cv); local bw=#lbl+2; local sel=cv==ps.chip_val
        local cbg=sel and CHIP_BG[cv] or colors.gray
        local cfg=sel and CHIP_FG[cv] or colors.lightGray
        if sel and cx>1 then mp(cx,2,">",CHIP_BG[cv],colors.black); cx=cx+1 end
        fill(cx,2,cx+bw-1,2,cbg); mp(cx+1,2,lbl,cfg,cbg)
        add_zone(cx,2,cx+bw-1,2,"chip",cv)
        cx=cx+bw
        if sel then mp(cx,2,"<",CHIP_BG[cv],colors.black); cx=cx+2 else cx=cx+1 end
    end

    -- ── rows 3-7: betting board ───────────────────────────────────────────────
    draw_board(seat, result_hl)

    -- ── middle: result display (rows 8 .. CH-2) ───────────────────────────────
    local mid_top=8; local mid_bot=CH-2
    if mid_bot>=mid_top then
        fill(1,mid_top,CW,mid_bot,colors.black)
        if ps.phase=="result" and ps.last_num~=nil then
            local mid=math.floor((mid_top+mid_bot)/2)
            local rb=ps.last_num==0 and "Green" or (RED_SET[ps.last_num] and "Red" or "Black")
            fill(1,mid,CW,mid,num_bg(ps.last_num))
            centre(mid,"  "..ps.last_num.."  |  "..rb.."  ",colors.white,num_bg(ps.last_num))
            if mid+1<=mid_bot then
                if ps.last_net and ps.last_net>0 then
                    fill(1,mid+1,CW,mid+1,colors.lime)
                    centre(mid+1,"  WIN!  +"..ps.last_net.." chips  ",colors.black,colors.lime)
                elseif ps.last_net and ps.last_net<0 then
                    centre(mid+1,"  Lost "..(- ps.last_net).." chips  ",colors.red,colors.black)
                elseif ps.last_net then
                    centre(mid+1,"  Break even  ",colors.gray,colors.black)
                end
            end
        elseif countdown>0 and (ps.phase=="betting" or ps.phase=="ready") then
            local mid=math.floor((mid_top+mid_bot)/2)
            local pt=math.floor(os.epoch("utc")/300)%2
            local cd_col = countdown<=5  and (pt==0 and colors.red    or colors.orange)
                        or countdown<=15 and (pt==0 and colors.orange  or colors.yellow)
                        or colors.yellow
            fill(1,mid,CW,mid,cd_col)
            centre(mid,"  "..countdown.."s  ",colors.black,cd_col)
        end
    end

    -- ── bottom 2 rows: action buttons ─────────────────────────────────────────
    local by=CH-1
    fill(1,by,CW,CH,colors.black)
    if ps.phase=="betting" then
        local tot=total_bets(seat)
        if tot>0 then
            local split=math.floor(CW*2/5)
            fill(1,by,split,CH,colors.orange)
            bcentre(by,  1,split,"CLEAR BETS",colors.black,colors.orange)
            add_zone(1,by,split,CH,"action","clear")
            local can=ps.chips>=tot
            local rbg=can and colors.green or colors.gray
            local rfg=can and colors.black or colors.white
            fill(split+1,by,CW,CH,rbg)
            bcentre(by,   split+1,CW,"READY",  rfg,rbg)
            bcentre(by+1, split+1,CW,tot.."c", rfg,rbg)
            if can then add_zone(split+1,by,CW,CH,"action","ready") end
        else
            fill(1,by,CW,CH,colors.gray)
        end
    elseif ps.phase=="ready" then
        fill(1,by,CW,CH,colors.orange)
        bcentre(by,  1,CW,"CANCEL READY",colors.black,colors.orange)
        add_zone(1,by,CW,CH,"action","unready")
    end

    -- ── spinning overlay ──────────────────────────────────────────────────────
    if ps.phase=="spinning" then
        local oy=math.floor(CH/2)
        local frame=SPIN_FRAMES[(ps.spin_frame%#SPIN_FRAMES)+1]
        fill(1,oy-1,CW,oy+1,colors.orange)
        centre(oy-1,string.rep("=",CW-4),colors.black,colors.orange)
        centre(oy,frame,colors.black,colors.orange)
        centre(oy+1,string.rep("=",CW-4),colors.black,colors.orange)
    end
end

-- Update just the spin overlay on one player screen (called inside animation loop)
local function update_spin_overlay(seat)
    local ps=p[seat]
    if not ps.mon or ps.phase~="spinning" then return end
    M=ps.mon; CW=ps.W; CH=ps.H
    ps.spin_frame=ps.spin_frame+1
    local oy=math.floor(CH/2)
    local frame=SPIN_FRAMES[(ps.spin_frame%#SPIN_FRAMES)+1]
    fill(1,oy-1,CW,oy+1,colors.orange)
    centre(oy-1,string.rep("=",CW-4),colors.black,colors.orange)
    centre(oy,frame,colors.black,colors.orange)
    centre(oy+1,string.rep("=",CW-4),colors.black,colors.orange)
end

-- ── game flow ─────────────────────────────────────────────────────────────────
local function open_betting()
    game_phase="betting"; cancel_countdown()
    for seat=1,NUM_SEATS do
        clear_bets(seat)
        p[seat].last_num=nil; p[seat].last_net=nil
        p[seat].phase = p[seat].wd and "betting" or "attract"
        render_player(seat)
    end
    render_dealer()
end

local function check_ready()
    if game_phase~="betting" then return end
    local nr=count_ready()
    if nr>=2 and all_ready() then
        cancel_countdown(); do_spin(); open_betting()
    elseif nr>=2 and not spin_tmr then
        start_countdown(); render_dealer()
    elseif nr<2 and spin_tmr then
        cancel_countdown(); render_dealer()
    else
        render_dealer()
    end
end

function do_spin()   -- forward-declared via function statement so check_ready can call it
    cancel_countdown()
    game_phase="spinning"
    for seat=1,NUM_SEATS do
        if p[seat].phase~="attract" then
            p[seat].had_bets = (p[seat].phase=="ready")
            if not p[seat].had_bets then clear_bets(seat) end
            p[seat].phase="spinning"; p[seat].spin_frame=0
        end
    end
    render_dealer()
    for seat=1,NUM_SEATS do render_player(seat) end

    local result      = math.random(0,36)
    local t_idx       = wheel_pos(result)
    local s_idx       = math.random(#WHEEL)
    local dist        = (t_idx-s_idx) % #WHEEL
    local total_steps = 2*#WHEEL+dist

    for step=1,total_steps do
        local pos = ((s_idx+step-1) % #WHEEL)+1
        local t   = step/total_steps
        M=dealer_mon; CW=DW; CH=DH
        draw_strip(pos,nil)
        for seat=1,NUM_SEATS do update_spin_overlay(seat) end
        sleep(0.025+t*t*0.30)
    end

    M=dealer_mon; CW=DW; CH=DH
    draw_strip(t_idx,result); sleep(0.4)
    -- Ball-landing bounce: flash the strip row between result colour and black
    for i=1,6 do
        local bg=i%2==0 and num_bg(result) or colors.black
        fill(1,3,CW,3,bg); sleep(0.09)
    end
    draw_strip(t_idx,result)
    -- Simultaneous result-colour flash on every player screen
    local rbg=num_bg(result)
    for seat=1,NUM_SEATS do
        local ps=p[seat]
        if ps.phase=="spinning" and ps.mon then
            M=ps.mon; CW=ps.W; CH=ps.H
            fill(1,1,CW,CH,rbg)
            centre(math.floor(CH/2),"  "..result.."  ",colors.white,rbg)
        end
    end
    sleep(0.6)
    -- Dealer result announcement flash
    local rb_str=result==0 and "GREEN" or (RED_SET[result] and "RED" or "BLACK")
    M=dealer_mon; CW=DW; CH=DH
    for i=1,8 do
        local bg=i%2==0 and rbg or colors.black
        fill(1,4,CW,5,bg)
        if i%2==0 then
            centre(4,"  "..result.."  "..rb_str.."  ",colors.white,bg)
            centre(5,string.rep("=",math.min(CW-4,20)),colors.white,bg)
        end
        sleep(0.09)
    end
    draw_strip(t_idx,result)

    last_num=result
    history[#history+1]=result
    if #history>10 then table.remove(history,1) end

    game_phase="result"
    for seat=1,NUM_SEATS do
        local ps=p[seat]
        if ps.phase=="spinning" then
            local win=calc_payout(seat,result)
            ps.chips=ps.chips+win
            ps.last_net = ps.had_bets and (win-total_bets(seat)) or nil
            ps.last_num=result
            flush_wallet(seat)
            clear_bets(seat)
            ps.phase="result"
            -- Win celebration flash on player screen
            if ps.last_net and ps.last_net>0 and ps.mon then
                M=ps.mon; CW=ps.W; CH=ps.H
                local wfc={colors.lime,colors.green,colors.yellow,colors.lime,colors.green,colors.lime,colors.yellow,colors.lime}
                for _,fc in ipairs(wfc) do
                    fill(1,1,CW,CH,fc)
                    centre(math.floor(CH/2)-1,string.rep("*",math.min(CW-2,26)),colors.black,fc)
                    centre(math.floor(CH/2),  "  WIN!  +"..ps.last_net.."c  ",      colors.black,fc)
                    centre(math.floor(CH/2)+1,string.rep("*",math.min(CW-2,26)),colors.black,fc)
                    sleep(0.07)
                end
            end
            render_player(seat,result)
        end
    end
    render_dealer()
    sleep(6)
end

-- ── touch handler ─────────────────────────────────────────────────────────────
local function handle_touch(seat,x,y)
    local ps=p[seat]
    if ps.phase=="spinning" or ps.phase=="attract" then return end
    for _,z in ipairs(ps.zones) do
        if x>=z.x1 and x<=z.x2 and y>=z.y1 and y<=z.y2 then
            if z.kind=="chip" then
                ps.chip_val=z.key; render_player(seat)
            elseif z.kind=="straight" and ps.phase=="betting" then
                ps.sbets[z.key]=(ps.sbets[z.key] or 0)+ps.chip_val; render_player(seat)
            elseif z.kind=="outside" and ps.phase=="betting" then
                ps.obets[z.key]=(ps.obets[z.key] or 0)+ps.chip_val; render_player(seat)
            elseif z.kind=="action" then
                if z.key=="ready" then
                    local t=total_bets(seat)
                    if t>0 and ps.chips>=t then
                        ps.chips=ps.chips-t; flush_wallet(seat)
                        ps.phase="ready"; render_player(seat); check_ready()
                    end
                elseif z.key=="unready" and ps.phase=="ready" then
                    ps.chips=ps.chips+total_bets(seat); flush_wallet(seat)
                    ps.phase="betting"; render_player(seat); check_ready()
                elseif z.key=="clear" and ps.phase=="betting" then
                    clear_bets(seat); render_player(seat)
                end
            end
            return
        end
    end
end

-- ── disk events ───────────────────────────────────────────────────────────────
local function on_disk_insert(seat)
    refresh_wallet(seat)
    if p[seat].wd and game_phase=="betting" then
        clear_bets(seat); p[seat].last_num=nil; p[seat].last_net=nil
        p[seat].phase="betting"
        render_player(seat); render_dealer()
    else
        render_player(seat)  -- show disk ok status even if can't join yet
    end
end

local function on_disk_eject(seat)
    local was_ready=(p[seat].phase=="ready")
    p[seat].wd=nil; p[seat].chips=0
    clear_bets(seat); p[seat].last_num=nil; p[seat].last_net=nil
    p[seat].phase="attract"
    render_player(seat); render_dealer()
    if was_ready then check_ready() end
end

-- ── boot ──────────────────────────────────────────────────────────────────────
for seat=1,NUM_SEATS do refresh_wallet(seat) end
game_phase="betting"
render_dealer()
for seat=1,NUM_SEATS do
    if p[seat].wd then p[seat].phase="betting" end
    render_player(seat)
end

-- ── main loop ─────────────────────────────────────────────────────────────────
while true do
    local ev={os.pullEvent()}
    if ev[1]=="monitor_touch" then
        local seat=mon_to_seat[ev[2]]
        if seat then handle_touch(seat,ev[3],ev[4]) end
    elseif ev[1]=="disk" then
        local seat=drv_to_seat[ev[2]]
        if seat then on_disk_insert(seat) end
    elseif ev[1]=="disk_eject" then
        local seat=drv_to_seat[ev[2]]
        if seat then on_disk_eject(seat) end
    elseif ev[1]=="timer" then
        if ev[2]==spin_tmr then
            spin_tmr=nil; tick_tmr=nil; countdown=0
            do_spin(); open_betting()
        elseif ev[2]==tick_tmr then
            tick_tmr=nil
            if countdown>0 then
                countdown=countdown-1
                if countdown>0 then tick_tmr=os.startTimer(1) end
            end
            render_dealer()
            -- Keep countdown visible and pulsing on all active player screens
            for seat=1,NUM_SEATS do
                local ph=p[seat].phase
                if ph=="betting" or ph=="ready" then render_player(seat) end
            end
        end
    end
end
