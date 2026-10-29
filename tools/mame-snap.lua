-- MAME autoboot script: save a snapshot every 4 emulated seconds.
-- mame macqd605 -autoboot_script tools/mame-snap.lua -snapshot_directory DIR -seconds_to_run N ...
-- CPUID=2226 makes the CPU ID register ($5FFFFFFC) read $A55A2226: a 33MHz Quadra 605
-- (Gestalt 95) instead of MAME's 25MHz one ($2225, Gestalt 94). CPUID=2221 / 2222 make it
-- an LC/Performa 475 at 25 / 33MHz (Gestalt 89 / 90) with a full 68040, which MAME's own
-- maclc475 (a 68LC040) can't be.
if os.getenv("CPUID") then
  local id = 0xa55a0000 | tonumber(os.getenv("CPUID"), 16)
  cpuid_tap = manager.machine.devices[":maincpu"].spaces["program"]:install_read_tap(
    0x5ffffffc, 0x5fffffff, "cpuid", function(offset, data, mask) return id end)
end
local last = 0
notifier = emu.add_machine_frame_notifier(function()
  local t = manager.machine.time.seconds
  if t - last >= 4 then last = t; manager.machine.video:snapshot() end
end)
