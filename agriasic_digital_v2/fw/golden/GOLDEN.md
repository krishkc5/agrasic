# Golden firmware image

This is the image synthesized into the boot ROM (`rtl/rv32i/agriasic_boot_rom.sv`)
and shadow-loaded into IMEM when the BOOT_SEL strap is low. It is frozen at
tapeout: promote a new build only when it has passed the full regression.

- Promoted: 2026-09-22
- Words: 148 (592 bytes)
- SHA-256 of the hex file: `cc5208d52509a0880d346a4c1fafa1c9788f21f3605ad46c2ea3887135e86ab3`

Regenerate the ROM RTL from this image with `python3 gen_boot_rom.py`.
