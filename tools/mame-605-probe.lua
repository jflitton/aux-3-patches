-- MAME autoboot script: run A/UX 3.1 (AWS 95 /unix) on macqd605 with in-memory patches.
-- Addresses are for the 3.1 kernel on AUX_3_1_1GB.dsk; 3.0.1 differs (re-derive from symbols).
--
--   OUT=log STOP=secs [STUB_EGRET=1] mame macqd605 -ram 128M -debug -debugger none \
--       -autoboot_script tools/mame-605-probe.lua ...
--
-- Patches: machineID 0x5C -> 0x1C (Centris 650 boardinit case; BOARD=switch rewrites only
-- the switch value in boardinit and leaves machineID alone), then devices[5] = 0 so
-- memsize uses the generic banksize probe instead of memcdjsize (MEMCjr reg 0x2C reads 0).
-- STUB_EGRET=1 makes aEgretDispatch (the ROM's _EgretDispatch, patched by A/UX) return at
-- once with pbResult = 0 instead of driving the Cuda with Egret signalling.
-- PATCHED=1: the disk's kernel already carries the 605 patch (patches/memcjr/build.sh +
-- tools/binpatch.py); apply nothing in RAM, only log.
-- Breakpoints stay disabled until the kernel's _start so Mac OS code at the same low
-- addresses doesn't trigger them.
--
-- UDUMP=dir saves the u-area (virtual 0x12fff000, 4KB) every 5s after t=30 (ps-style view).
-- EXECLOG=1 logs every exec (setregs) and exit with u_comm/u_psargs ("X ..." lines).
-- SYSCALLS=n logs the first n system calls ("S num comm args").
-- CUDA=build/cuda-NAME.lua (tools/cuda-mame-patch.py on build/memcjr/kernel-605.elf/.bin, from
-- patches/memcjr/build.sh) loads the Cuda transport at _start and
-- sets devices[1] (Egret/Cuda present) after boardinit.
-- VIDEOLOG=1 traces video_find (slot, devbase, VPBlock, driver lookups).
-- PRODINFO=file loads a prepared 0x34-byte ProductInfo copy into A/UX's buffer after
-- setupProductInfo and points ProductInfoPtr at it.
-- TRACE_SDM=file traces instructions from callStartSDeclMgr until panic().
-- VRAMDUMP=file writes the 1MB of VRAM (physical 0xF9000000) at the end.
-- TIMELOG=1 logs init_time's _ReadDateTime result and each _EgretDispatch result ("e ...").
-- Log lines: "P xx" = kernel putchar byte, "E ..." = EgretDispatch param block,
-- "PANIC fmt=..." = panic() format pointer + return addresses.

local dbg = manager.machine.debugger
local cpu = manager.machine.devices[":maincpu"]
local out = io.open(os.getenv("OUT"), "w")
local ids = {}
local function bp(a, act) ids[#ids + 1] = cpu.debug:bpset(a, "1", act .. '; g') end

local patched = os.getenv("PATCHED")
if patched then
  -- nothing to do: the kernel patches itself
elseif os.getenv("BOARD") == "switch" then
  -- only boardinit's switch sees 0x1C; machineID stays 0x5C for everyone else
  ids[#ids + 1] = cpu.debug:bpset(0x58812, "d0 == 5c", 'printf "boardinit switch 5c -> 1c\\n"; d0=1c; g')
else
  bp(0x583de, 'printf "boardinit id=%x -> 1c\\n", w@5afa6; w@5afa6=1c')
end
local cuda = os.getenv("CUDA") and dofile(os.getenv("CUDA"))
bp(0x5421c, 'printf "after boardinit devices1=%x devices5=%x cputype=%x monitorID=%x obv_monitor=%x\\n", b@5b3cf, b@5b3d3, d@5af9c, b@5b67e, d@5b3b6' ..
  (patched and '' or '; b@5b3d3=0') .. (cuda and '; b@5b3cf=1' or ''))
if patched then
  bp(0x58b7a, 'printf "setup_lowmem_globals ProductInfoPtr=%x VRAM phys=%x log32=%x\\n", d@5b6b8, d@(d@5b6b8+d@(d@5b6b8+8)), d@(d@5b6b8+d@(d@5b6b8+8)+4)')
end
bp(0x54238, 'printf "memsize done numbanks=%x b0=%x %x %x %x b1=%x %x %x %x\\n", d@5b0c4, d@5b0c8, d@5b0cc, d@5b0d0, d@5b0d4, d@5b0d8, d@5b0dc, d@5b0e0, d@5b0e4')
bp(0x100077e8, 'printf "main()\\n"')
bp(0x10020f1c, 'printf "P %02x\\n", b@(a7+7)')
bp(0x10021088, 'printf "PANIC fmt=%x args %x %x ret %x %x %x %x %x %x\\n", d@(a7+4), d@(a7+8), d@(a7+c), d@a7, d@(a7+10), d@(a7+14), d@(a7+18), d@(a7+1c), d@(a7+20)')
local egret = 'printf "E type=%02x cmd=%02x p=%08x cnt=%04x buf=%x compl=%x ret=%x\\n", b@a0, b@(a0+1), d@(a0+2), w@(a0+6), d@(a0+8), d@(a0+10), d@a7'
if os.getenv("STUB_EGRET") then
  egret = egret .. '; w@(a0+e)=0; pc=10049e76'
end
bp(0x10049e6c, egret)
if os.getenv("TIMELOG") then
  -- init_time's _ReadDateTime result, and each _EgretDispatch's result as the ROM sees it
  bp(0x10014d20, 'printf "ReadDateTime mac_basetime=%x\\n", d@12018a8c')
  bp(0x10049e74, 'printf "e result=%x p=%08x d0=%x\\n", w@(d@a7+e), d@(d@a7+2), d0')
end
if os.getenv("EXECLOG") then
  -- u_comm at u+0x340, u_psargs at u+0x3a2 (A/UX 3.1)
  local comm = 'd@12fff340, d@12fff344, d@12fff348, d@12fff34c'
  local args = 'd@12fff3a2, d@12fff3a6, d@12fff3aa, d@12fff3ae, d@12fff3b2, d@12fff3b6, d@12fff3ba, d@12fff3be'
  bp(0x10007280, 'printf "X exec %08x%08x%08x%08x | %08x%08x%08x%08x%08x%08x%08x%08x\\n", ' .. comm .. ', ' .. args)
  bp(0x100172e8, 'printf "X exit(%x) %08x%08x%08x%08x\\n", d@(a7+4), ' .. comm)
end
if os.getenv("SYSCALLS") then
  -- syscall0+0x78: d3 = system call number; log the first SYSCALLS calls
  ids[#ids + 1] = cpu.debug:bpset(0x1002e694, "temp0 < " .. os.getenv("SYSCALLS"),
    'temp0 = temp0 + 1; g')
  -- syscall0+0xfa (after the handler): d3 = number, u_error at u+0xde, u_arg[] at u+0xa8
  ids[#ids + 1] = cpu.debug:bpset(0x1002e716, "temp1 < " .. os.getenv("SYSCALLS"),
    'temp1 = temp1 + 1; printf "S %d err=%d args=%x %x %x %08x%08x%08x%08x\\n", d3, b@12fff0de, d@12fff0a8, d@12fff0ac, d@12fff0b0, d@12fff340, d@12fff344, d@12fff348, d@12fff34c; g')
end
if os.getenv("VIDEOLOG") then
  -- video_find (3.1): slot loop, getDevBase / getVPBlock / getVideoDriver results
  bp(0x10047a9c, 'printf "V slot=%x rbv_mon=%x obv_mon=%x\\n", d3, d@5b3aa, d@5b3b6')
  bp(0x10047ac8, 'printf "V getDevBase=%x\\n", d0')
  bp(0x10047aea, 'printf "V getVPBlock=%x\\n", d0')
  bp(0x10047b02, 'printf "V getVideoDriver=%x\\n", d0')
  bp(0x10047b5c, 'printf "V video_count=%x\\n", d@1202e0b0')
  bp(0x10049c2c, 'printf "V StartSDeclMgr -> d0=%x\\n", d0')
  bp(0x58aae, 'printf "V restoreVideoInfoPtr rbv_base=%x dd8=%x PI@dd8+8=%x\\n", d@5b3ae, d@dd8, d@(d@dd8+8)')
  bp(0x100470c2, 'printf "V slotmgr sel=%x pb=%x slot=%x id=%x cat=%x/%x/%x/%x\\n", d@(a7+4), d@(a7+8), b@(d@(a7+8)+31), b@(d@(a7+8)+32), w@(d@(a7+8)+28), w@(d@(a7+8)+2a), w@(d@(a7+8)+2c), w@(d@(a7+8)+2e)')
  bp(0x1004712c, 'printf "V slotmgr -> %x\\n", d@(a6-4)')
end
if os.getenv("PRODINFO") then
  -- after setupProductInfo (boardinit+0x14): install a prepared ProductInfo copy (3.1 addresses)
  -- PRODINFO_AT = physical load address, PRODINFO_PTR = the address ProductInfoPtr gets
  local at = os.getenv("PRODINFO_AT") or "5b684"
  local ptr = os.getenv("PRODINFO_PTR") or "5b684"
  bp(0x583f2, 'load ' .. os.getenv("PRODINFO") .. ',' .. at .. '; d@5b6b8=' .. ptr .. '; printf "ProductInfo copy at %x\\n", d@5b6b8')
end
if os.getenv("TRACE_SDM") then
  -- instruction trace from callStartSDeclMgr until panic
  bp(0x10049bf4, 'trace ' .. os.getenv("TRACE_SDM") .. ',0,noloop')
  bp(0x10021088, 'trace off,0')
end
for _, i in ipairs(ids) do cpu.debug:bpdisable(i) end
local start = 'printf "_start\\n"; bpenable'
if cuda then
  -- check the original cEgretDispatch bytes are where we expect, then patch in RAM
  start = start .. string.format('; printf "cuda: orig %%x (expect %x)\\n", d@%x; load %s,%x',
    cuda.check[2], cuda.check[1], cuda.blob, cuda.blob_phys)
  for _, st in ipairs(cuda.stubs) do
    start = start .. string.format('; w@%x=4ef9; d@%x=%x', st[1], st[1] + 2, st[2])
  end
end
cpu.debug:bpset(0x54000, "1", start .. '; g')
dbg.execution_state = "run"

local stop = tonumber(os.getenv("STOP") or "90")
local shown, last = 0, 0
notifier = emu.add_machine_frame_notifier(function()
  local log = dbg.consolelog
  for i = shown + 1, #log do if log[i] ~= "" then out:write(log[i], "\n") end end
  shown = #log
  local t = manager.machine.time.seconds
  if t - last >= 5 then
    last = t
    manager.machine.video:snapshot()
    local udir = os.getenv("UDUMP")
    if udir and t > 30 then
      dbg:command(string.format("save %s/u%03d.bin,12fff000,1000", udir, math.floor(t)))
    end
    out:write(string.format("t=%.0f PC=%08x SR=%04x\n", t, cpu.state["PC"].value, cpu.state["SR"].value))
    out:flush()
  end
  if t > stop then
    local dump = os.getenv("VRAMDUMP")
    if dump then
      local prog = cpu.spaces["program"]
      local f = io.open(dump, "wb")
      for a = 0xf9000000, 0xf90ffffc, 4 do f:write(string.pack(">I4", prog:read_u32(a))) end
      f:close()
    end
    out:close(); manager.machine:exit()
  end
end)
