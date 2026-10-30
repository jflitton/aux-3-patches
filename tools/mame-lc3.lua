-- MAME helper for the LC III and LC III+ (maclc3, maclc3p), loaded by tools/mame-snap.lua
-- and tools/mame-ckpt-test.lua on those machines. Not needed on real hardware.
--  - MAME 0.289's 68030 keeps CACR bit 15, which only an 040 has, so the ROM's CPU test
--    (ROM+$47204) takes the machine for an 040, runs an 040 cache instruction and drops
--    into the Test Manager (black screen). Make the test take the 030 path (beq -> bra at
--    ROM+$47218) and correct the ROM checksum by the same amount (-$700), in MAME's copy
--    of the ROM only.
--  - MAME's LC III has no FPU unless its FPU setting is on, and A/UX needs one. Turn it on
--    and reset: the machine reads the setting at reset, and the new value takes effect at
--    the next frame, so the reset waits two frames.
local rom = manager.machine.memory.regions[":bootrom"]
if rom:read_u16(0x47218) == 0x6704 and rom:read_u32(0) == 0xecbbc41c then
  rom:write_u8(0x47218, 0x60)
  rom:write_u32(0, 0xecbbbd1c)
end
local port = manager.machine.ioport.ports[":config"]
local fpu = port and port.fields["FPU"]
if fpu and fpu.user_value == 0 then
  fpu.user_value = 1
  local frames = 0
  lc3_fpu_notifier = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames == 2 then manager.machine:soft_reset() end
  end)
end
