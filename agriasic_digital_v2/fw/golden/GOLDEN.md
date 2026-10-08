# Golden firmware image

This is the image synthesized into the boot ROM (`rtl/rv32i/agriasic_boot_rom.sv`)
and shadow-loaded into IMEM when the BOOT_SEL strap is low. It is frozen at
tapeout: promote a new build only when it has passed the full regression.

- Promoted: 2026-10-07
- Words: 148 (592 bytes)
- SHA-256 of the hex file: `47c0ce42d1cc4e1314c514d3a4ff24fbba89b3769fa146e1db755b3cfc56de64`

Regenerate the ROM RTL from this image with `python3 gen_boot_rom.py`.
