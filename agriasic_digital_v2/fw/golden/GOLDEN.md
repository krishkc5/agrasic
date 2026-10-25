# Golden firmware image

This is the image synthesized into the boot ROM (`rtl/rv32i/agriasic_boot_rom.sv`)
and shadow-loaded into IMEM when the BOOT_SEL strap is low. It is frozen at
tapeout: promote a new build only when it has passed the full regression.

- Promoted: 2026-10-25
- Words: 148 (592 bytes)
- SHA-256 of the hex file: `81cffa2c0fc85ca32f1c50db801f3d6a57f59fe6737293b8dbcdf74df31aac52`

Regenerate the ROM RTL from this image with `python3 gen_boot_rom.py`.
