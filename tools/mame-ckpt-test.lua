-- MAME autoboot script: test a checkpoint kernel (CKPT=1 build: modules/memcjr/memcjr.S,
-- modules/sonora/sonora.S) by holding a checkpoint key (1-9, 0, Q-P) from t=15s until
-- the kernel starts. Logs every kernel _start and every jump to the ROM's restart entry
-- (d0 = the checkpoint) with the time. Snapshot every 10s.
--   KEY=5 OUT=log STOP=230 mame macqd605 -ram 32M -debug -debugger none -hard CLONE.hd \
--     -autoboot_script tools/mame-ckpt-test.lua -snapshot_directory DIR -video none -nothrottle
--   CPUID=2226: the CPU ID register reads $A55A2226, a 33MHz 605 (see tools/mame-snap.lua)
-- On maclc3 / maclc3p it first loads tools/mame-lc3.lua (ROM CPU test fix, FPU on).
local dbg = manager.machine.debugger
local here = debug.getinfo(1, "S").source:match("^@(.*/)") or ""
if manager.machine.system.name:match("^maclc3") then dofile(here .. "mame-lc3.lua") end
if os.getenv("CPUID") then
  local id = 0xa55a0000 | tonumber(os.getenv("CPUID"), 16)
  cpuid_tap = manager.machine.devices[":maincpu"].spaces["program"]:install_read_tap(
    0x5ffffffc, 0x5fffffff, "cpuid", function(offset, data, mask) return id end)
end
local cpu = manager.machine.devices[":maincpu"]
local key = os.getenv("KEY")
local field, fname
for tag, port in pairs(manager.machine.ioport.ports) do
  for name, f in pairs(port.fields) do
    if key and name:sub(1, 1):upper() == key:upper() and (#name == 1 or name:sub(2, 3) == "  ") then
      field, fname = f, name
    end
  end
end
local f = io.open(os.getenv("OUT"), "w")
f:write("key: " .. tostring(fname) .. "\n")
-- launch's kernel info block (a0) carries machineID at +$B0 (_start's scopy%)
cpu.debug:bpset(0x54000, "d0 == 536d7201", 'printf "kernel _start, machineID %x\\n", w@(a0+0xb0); g')
cpu.debug:bpset(0x4080000a, "1", 'printf "ROM restart, d0=%d\\n", d0; g')
dbg.execution_state = "run"
local shown, held, last = 0, false, 0
notifier = emu.add_machine_frame_notifier(function()
  local t = manager.machine.time.seconds
  if field and t > 15 and not held then field:set_value(1); held = true end
  local log = dbg.consolelog
  for i = shown + 1, #log do
    f:write(string.format("%.1f %s\n", t, log[i]))
    if log[i]:find("kernel _start") and field then field:clear_value(); field = nil end
  end
  shown = #log
  if t - last >= 10 then last = t; manager.machine.video:snapshot(); f:flush() end
  if t > tonumber(os.getenv("STOP")) then f:close(); manager.machine:exit() end
end)
