#!/usr/bin/env python3
"""Boot QEMU q800 headless and take periodic screenshots.

  qemu-shots.py ROM DISK.qcow2 OUTDIR SECONDS STEP [PORT]

DISK should be a throwaway qcow2 overlay, never an original image:
  qemu-img create -f qcow2 -F raw -b /abs/path/original.dsk overlay.qcow2
Screenshots land in OUTDIR/tNNN.ppm; serial port A goes to OUTDIR/serial.log.
"""
import os, socket, subprocess, sys, time


def main():
    rom, disk, outdir, secs, step = sys.argv[1:6]
    secs, step = int(secs), int(step)
    port = int(sys.argv[6]) if len(sys.argv) > 6 else 45454
    os.makedirs(outdir, exist_ok=True)
    p = subprocess.Popen(['qemu-system-m68k', '-M', 'q800', '-m', '64', '-bios', rom,
                          '-display', 'none', '-serial', 'file:%s/serial.log' % outdir,
                          '-device', 'scsi-hd,scsi-id=0,drive=hd0',
                          '-drive', 'file=%s,format=qcow2,if=none,id=hd0' % disk,
                          '-monitor', 'tcp:127.0.0.1:%d,server,nowait' % port])
    time.sleep(1)
    s = socket.create_connection(('127.0.0.1', port))
    t = 0
    while t < secs:
        time.sleep(step)
        t += step
        s.sendall(b'screendump %s/t%03d.ppm\n' % (outdir.encode(), t))
    time.sleep(1)
    s.sendall(b'quit\n')
    p.wait(10)


if __name__ == '__main__':
    main()
