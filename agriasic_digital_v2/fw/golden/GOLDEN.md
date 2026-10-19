# Golden firmware image

This is the image synthesized into the boot ROM (`rtl/rv32i/agriasic_boot_rom.sv`)
and shadow-loaded into IMEM when the BOOT_SEL strap is low. It is frozen at
tapeout: promote a new build only when it has passed the full regression.

- Promoted: 2026-10-18
- Words: 136 (544 bytes)
- SHA-256 of the hex file: `43a36ec0a7397455c04fa1c8360ab02e1d32bad5ba9202cca1234ed4fd0a27b0`

Regenerate the ROM RTL from this image with `python3 gen_boot_rom.py`.
