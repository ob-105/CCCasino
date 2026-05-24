-- slots/startup.lua
-- Three-reel slot machine with animated reels and win effects.
-- Hardware: monitor (any side), disk drive (any side)

local wallet = dofile("/casino/lib/wallet.lua")
math.randomseed(os.epoch("utc"))

local mon = peripheral.find("monitor")
assert(mon, "Attach a monitor to the slots computer")
mon.setTextScale(0.5)
local W, H = mon.getSize()

local drv = wallet.find_drive()

-- ── wallet ────────────────────────────────────────────────────────────────────
local wd, chips = nil, 0

local function refresh_wallet()
    wd, chips = nil, 0
    if drv and disk.isPresent(drv) then
        local w = wallet.load(drv)
        if w then wd=w; chips=w.balance end
    end
end

local function flush_wallet()
    if not wd then return end
    wd.balance = chips; wallet.save(wd, drv)
end

refresh_wallet()

-- ── symbols ───────────────────────────────────────────────────────────────────
local SYMS = {
    { key="7",   disp=" 7 ", col=colors.yellow,  weight=3  },
    { key="BAR", disp="BAR", col=colors.white,   weight=5  },
    { key="BEL", disp="BEL", col=colors.orange,  weight=5  },
    { key="CHR", disp="CHR", col=colors.red,     weight=6  },
    { key="LEM", disp="LEM", col=colors.lime,    weight=6  },
}
local POOL = {}
for _, s in ipairs(SYMS) do
    for _ = 1, s.weight do POOL[#POOL+1] = s end
end
local function rsym() return POOL[math.random(#POOL)] end

-- ── payouts ───────────────────────────────────────────────────────────────────
local THREE_MULT = { ["7"]=50, BAR=20, BEL=10, CHR=8, LEM=5 }

local function calc_win(s1,s2,s3,bet)
    local k1,k2,k3 = s1.key,s2.key,s3.key
    if k1==k2 and k2==k3 then return bet*(THREE_MULT[k1] or 3) end
    local sv = (k1=="7" and 1 or 0)+(k2=="7" and 1 or 0)+(k3=="7" and 1 or 0)
    if sv>=2 then return bet*5 end
    if k1==k2 or k2==k3 or k1==k3 then return bet*2 end
    if k1=="CHR" or k2=="CHR" or k3=="CHR" then return bet end
    return 0
end

-- ── state ─────────────────────────────────────────────────────────────────────
local BET_OPTS = {1,5,10,25,50,100,500}
local bet      = 10
local reels    = { SYMS[4], SYMS[1], SYMS[3] }
local last_win = nil
local spinning = false
local btns     = {}

-- ── drawing ───────────────────────────────────────────────────────────────────
local function fill(x1,y1,x2,y2,bg)
    mon.setBackgroundColor(bg)
    local row=string.rep(" ",x2-x1+1)
    for y=y1,y2 do mon.setCursorPos(x1,y); mon.write(row) end
end
local function mp(x,y,s,fg,bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(x,y); mon.write(s)
end
local function centre(y,s,fg,bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(math.floor((W-#s)/2)+1,y); mon.write(s)
end
local function abtn(x1,y1,x2,y2,id,label,bg,fg)
    fill(x1,y1,x2,y2,bg)
    mp(x1+math.floor((x2-x1+1-#label)/2),y1+math.floor((y2-y1)/2),label,fg,bg)
    btns[#btns+1]={x1=x1,y1=y1,x2=x2,y2=y2,id=id}
end

-- Draw one reel cell: 9 wide × 3 tall for maximum visual impact.
local REEL_W, REEL_H = 9, 3
local function draw_reel(cx,cy,sym,stopped,flash_col)
    local bg = flash_col or (stopped and colors.white or colors.lightGray)
    local border_col = stopped and colors.black or colors.gray
    fill(cx,cy,cx+REEL_W-1,cy+REEL_H-1,bg)
    mon.setBackgroundColor(bg); mon.setTextColor(border_col)
    mon.setCursorPos(cx,cy);    mon.write("\xd5"..string.rep("\xcd",REEL_W-2).."\xb8")
    mon.setCursorPos(cx,cy+1);  mon.write("\xb3"..string.rep(" ",REEL_W-2).."\xb3")
    mon.setCursorPos(cx,cy+2);  mon.write("\xd4"..string.rep("\xcd",REEL_W-2).."\xbe")
    -- symbol centred in the cell
    mon.setTextColor(sym.col)
    local sx = cx + math.floor((REEL_W-#sym.disp)/2)
    mon.setCursorPos(sx,cy+1); mon.write(sym.disp)
end

-- ── win effects ───────────────────────────────────────────────────────────────
local function jackpot_anim(win_amount)
    local cols = {colors.yellow,colors.orange,colors.yellow,colors.lime,colors.yellow,colors.orange}
    for i=1,#cols do
        fill(1,1,W,H,cols[i])
        centre(math.floor(H/2)-2, string.rep("\x01",W-4),         colors.black, cols[i])
        centre(math.floor(H/2)-1, "  \x01\x01  JACKPOT!  \x01\x01  ",    colors.black, cols[i])
        centre(math.floor(H/2),   "   +"..win_amount.." CHIPS!!!  ",       colors.black, cols[i])
        centre(math.floor(H/2)+1, "   7   7   7   ",                       colors.black, cols[i])
        centre(math.floor(H/2)+2, string.rep("\x01",W-4),         colors.black, cols[i])
        sleep(0.18)
    end
    sleep(1.0)
end

local function win_flash(reels_result, win_amount)
    local rx = math.floor((W-(3*REEL_W+2*2))/2)+1
    local ry = 4
    for i=1,4 do
        local flash = i%2==0 and colors.lime or colors.green
        for j=1,3 do draw_reel(rx+(j-1)*(REEL_W+2),ry,reels_result[j],true,flash) end
        sleep(0.12)
    end
end

-- ── render ────────────────────────────────────────────────────────────────────
local PAYOUT_LINES = {
    " 7 7 7  \xd7 50  JACKPOT",
    " BAR BAR BAR  \xd7 20",
    " BEL BEL BEL  \xd7 10",
    " CHR CHR CHR  \xd7 8",
    " LEM LEM LEM  \xd7 5",
    " Two 7s  \xd7 5 | Pair  \xd7 2 | Cherry  \xd7 1",
}

local function render(disp_reels,stopped_flags)
    mon.setBackgroundColor(colors.black); mon.clear()
    btns={}
    disp_reels    = disp_reels    or reels
    stopped_flags = stopped_flags or {true,true,true}

    -- decorative header
    fill(1,1,W,1,colors.yellow)
    local stars = string.rep("\x04",math.floor((W-20)/2))
    centre(1, stars.."  LUCKY  SLOTS  "..stars, colors.black, colors.yellow)

    -- balance / disk
    fill(1,2,W,2,colors.black)
    if wd then
        mp(2,2,"\x10 "..chips.." chips",colors.white,colors.black)
        mp(W-8,2,"[disk ok]",colors.lime,colors.black)
    else
        mp(2,2,"!! NO DISK -- chips not saved !!",colors.orange,colors.black)
    end

    -- reels (3 × REEL_W with 2-char gaps, centred)
    local rx = math.floor((W-(3*REEL_W+2*2))/2)+1
    local ry = 4
    for i=1,3 do
        draw_reel(rx+(i-1)*(REEL_W+2), ry, disp_reels[i], stopped_flags[i])
    end

    -- payline indicator ─────────────────────────────────────────────────────────
    local pl_y = ry+1  -- middle row of reels = payline
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.yellow)
    mon.setCursorPos(1,pl_y); mon.write("\x10")
    mon.setCursorPos(W,pl_y); mon.write("\x11")

    -- win / loss indicator
    local res_y = ry+REEL_H+1
    fill(1,res_y,W,res_y,colors.black)
    if last_win ~= nil then
        if last_win > 0 then
            centre(res_y,"  \x01  WIN!  +"..last_win.." chips  \x01  ",colors.black,colors.lime)
        else
            centre(res_y,"  No win this spin  ",colors.gray,colors.black)
        end
    end

    -- bet selector
    local by = res_y+2
    fill(1,by,W,by,colors.black)
    mp(2,by,"BET:",colors.lightGray,colors.black)
    local bx=7
    for _,b in ipairs(BET_OPTS) do
        local lbl=tostring(b)
        local bw=#lbl+2
        local sel=b==bet
        abtn(bx,by,bx+bw-1,by,"bet_"..b,lbl,sel and colors.orange or colors.gray,sel and colors.black or colors.white)
        bx=bx+bw+1
    end

    -- spin button
    local sy=by+2
    if spinning then
        fill(1,sy,W,sy+1,colors.black)
        centre(sy,"  \x1b \x1b  SPINNING...  \x1a \x1a  ",colors.yellow,colors.black)
    elseif chips>=bet then
        local lbl="  \x10  SPIN  "..bet.."c  \x11  "
        abtn(math.floor(W/2)-#lbl/2,sy,math.floor(W/2)+#lbl/2,sy+1,"spin",lbl,colors.green,colors.black)
    else
        fill(1,sy,W,sy+1,colors.black)
        centre(sy,"Not enough chips (need "..bet..")",colors.red,colors.black)
    end

    -- payout table (if there's room)
    local py=sy+3
    if py+#PAYOUT_LINES<=H-1 then
        fill(1,py-1,W,H-1,colors.black)
        mp(2,py-1,"Payouts:",colors.gray,colors.black)
        for i,line in ipairs(PAYOUT_LINES) do
            mp(3,py+i-1,line,colors.lightGray,colors.black)
        end
    end

    -- leave
    abtn(1,H,math.floor(W/3),H,"leave","LEAVE TABLE",colors.purple,colors.white)
end

-- ── spin ──────────────────────────────────────────────────────────────────────
local function do_spin()
    if chips<bet or spinning then return end
    spinning=true
    chips=chips-bet

    local result   = {rsym(),rsym(),rsym()}
    local display  = {rsym(),rsym(),rsym()}
    local stopped  = {false,false,false}
    local stop_at  = {16,22,28}

    for tick=1,30 do
        for i=1,3 do
            if tick>=stop_at[i] then
                stopped[i]=true; display[i]=result[i]
            else
                display[i]=rsym()
            end
        end
        render(display,stopped)
        sleep(0.04+tick*0.005)
    end

    local win=calc_win(result[1],result[2],result[3],bet)
    chips=chips+win
    last_win=win
    reels=result

    -- celebratory effects
    if win>=bet*50 then
        jackpot_anim(win)
    elseif win>0 then
        win_flash(result, win)
    end

    flush_wallet()
    spinning=false
    render()
end

-- ─�� input ─────────────────────────────────────────────────────────────────────
local function handle_touch(x,y)
    for _,b in ipairs(btns) do
        if x>=b.x1 and x<=b.x2 and y>=b.y1 and y<=b.y2 then
            if b.id=="spin" and not spinning then
                do_spin()
            elseif b.id=="leave" then
                flush_wallet()
                fill(1,1,W,H,colors.purple)
                centre(math.floor(H/2),"Saved "..chips.."c to disk.  Goodbye!",colors.white,colors.purple)
                sleep(2); error("player left")
            elseif b.id:sub(1,4)=="bet_" then
                bet=tonumber(b.id:sub(5)) or bet; render()
            end
            return
        end
    end
end

-- ── main loop ─────────────────────────────────────────────────────────────────
render()
while true do
    local ev={os.pullEvent()}
    if ev[1]=="monitor_touch" then handle_touch(ev[3],ev[4])
    elseif ev[1]=="disk" or ev[1]=="disk_eject" then
        refresh_wallet(); last_win=nil; render()
    end
end
