# Date

`--date` · A/UX 3.1 · Any Mac

A/UX's `date` can't set a year after 1999 (`date 1029143026` sets 1970), and `date +%y`
shows 2026 as `<6`. With this patch:

- Two-digit years 00-69 mean 2000-2069; 70-99 still mean 1970-1999.
- Four-digit years work: `date 102914302026`.
- `%y` and `%D` print years after 1999 correctly.

A/UX still can't go past 2037. Tested in MAME on `AUX_3_1_1GB_Use_In_Shoebill.zip`.

## For developers

| File | What it is |
|---|---|
| `apply.sh DISK` | Applies the patch to a copy of a disk image |
| `src/date-y2k.txt` | Byte patch to `/bin/date`; its comments explain each change |
