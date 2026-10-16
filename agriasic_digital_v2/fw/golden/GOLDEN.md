# Golden firmware image

This is the image synthesized into the boot ROM (`rtl/rv32i/agriasic_boot_rom.sv`)
and shadow-loaded into IMEM when the BOOT_SEL strap is low. It is frozen at
tapeout: promote a new build only when it has passed the full regression.

- Promoted: 2026-10-15
- Words: 141 (564 bytes)
- SHA-256 of the hex file: `c604e1ec536d555af5821cdc3fc270c7a4e58c203850e3e7200f79ab1ac4fe65`

Regenerate the ROM RTL from this image with `python3 gen_boot_rom.py`.
