#!/usr/bin/env python3
"""Generate the per-module SVG block diagrams referenced by section 6 of the MAS.

These replace the ASCII art that used to sit inline in docs/agriasic_digital_MAS.md.
Style follows the hand-drawn diagrams already in docs/diagrams/modules/: a
5000x3000 canvas, Arial, dark #212121 blocks with white text, pastel accents.

    python3 docs/diagrams/gen_module_diagrams.py

Regenerate after changing a module's ports, states or timing contract.
"""
import pathlib

OUT = pathlib.Path(__file__).resolve().parent / "modules"

INK, PANEL, GREY, LIGHT, WHITE = "#212121", "#F5F5F5", "#616161", "#BDBDBD", "#fff"
BLUE, BLUE_S = "#BBDEFB", "#1565C0"
GREEN, GREEN_S = "#C8E6C9", "#1B5E20"
ORANGE, ORANGE_S = "#FFE0B2", "#E65100"
PURPLE, PURPLE_S = "#E1BEE7", "#7B1FA2"
RED, RED_S = "#FFCDD2", "#B71C1C"
MARKERS = {BLUE_S: "mb", GREEN_S: "mg", ORANGE_S: "mo", PURPLE_S: "mp",
           RED_S: "mr", INK: "mk", GREY: "my"}


def esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class Canvas:
    def __init__(self, title, subtitle, desc, w=5000, h=3000, panel=True):
        self.w, self.h, self.parts = w, h, []
        self.title, self.subtitle, self.desc = title, subtitle, desc
        self.panel = panel

    def add(self, s):
        self.parts.append("  " + s)

    def text(self, x, y, s, size=20, fill=INK, weight=None, anchor="start"):
        w = ' font-weight="%s"' % weight if weight else ""
        a = ' text-anchor="%s"' % anchor if anchor != "start" else ""
        # xml:space="preserve" keeps the run of spaces that aligns columns inside a
        # label; without it SVG collapses them and the alignment is lost.
        self.add('<text x="%s" y="%s" font-family="Arial" font-size="%s"%s%s fill="%s" '
                 'xml:space="preserve">%s</text>' % (x, y, size, w, a, fill, esc(s)))

    def box(self, x, y, w, h, head=None, lines=(), fill=INK, stroke=None, tfill=None,
            head_size=28, line_size=19, rx=10, line_fill=None, lead=34):
        stroke = stroke or (fill if fill != WHITE else INK)
        tfill = tfill or (WHITE if fill == INK else INK)
        self.add('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="%s" stroke="%s" '
                 'stroke-width="2"/>' % (x, y, w, h, rx, fill, stroke))
        ty = y + 42
        if head:
            self.text(x + 26, ty, head, head_size, tfill, "700")
            ty += 40
        for ln in lines:
            self.text(x + 26, ty, ln, line_size, line_fill or tfill)
            ty += lead

    def bubble(self, x, y, w, h, head, note=None, fill=WHITE, stroke=INK, head_size=24):
        self.add('<rect x="%s" y="%s" width="%s" height="%s" rx="10" fill="%s" stroke="%s" '
                 'stroke-width="2.5"/>' % (x, y, w, h, fill, stroke))
        self.text(x + w / 2, y + h / 2 + 9, head, head_size, INK, "700", "middle")
        if note:
            self.text(x + w / 2, y + h + 32, note, 18, GREY, None, "middle")

    def arrow(self, x1, y1, x2, y2, color=BLUE_S, width=3):
        self.add('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="%s" '
                 'marker-end="url(#%s)"/>' % (x1, y1, x2, y2, color, width, MARKERS[color]))

    def path(self, pts, color=BLUE_S, width=3, arrow=True):
        d = "M" + " L".join("%s,%s" % (x, y) for x, y in pts)
        m = ' marker-end="url(#%s)"' % MARKERS[color] if arrow else ""
        self.add('<path d="%s" fill="none" stroke="%s" stroke-width="%s"%s/>' % (d, color, width, m))

    def line(self, x1, y1, x2, y2, color=INK, width=3):
        self.add('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="%s"/>'
                 % (x1, y1, x2, y2, color, width))

    def dot(self, x, y, r=9, fill=BLUE_S):
        self.add('<circle cx="%s" cy="%s" r="%s" fill="%s"/>' % (x, y, r, fill))

    def note(self, y, s):
        self.text(120, y, s, 22, GREY)

    def save(self, name):
        defs = "".join(
            '<marker id="%s" markerWidth="10" markerHeight="8" refX="9" refY="4" orient="auto">'
            '<path d="M0,0 L10,4 L0,8 z" fill="%s"/></marker>' % (mid, c)
            for c, mid in MARKERS.items())
        head = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<svg xmlns="http://www.w3.org/2000/svg" width="%s" height="%s" viewBox="0 0 %s %s" '
            'role="img" aria-labelledby="t d">' % (self.w, self.h, self.w, self.h),
            '  <title id="t">%s</title>' % esc(self.title),
            '  <desc id="d">%s</desc>' % esc(self.desc),
            '  <defs>%s</defs>' % defs,
            '  <rect width="%s" height="%s" fill="%s"/>' % (self.w, self.h, WHITE),
            '  <text x="120" y="95" font-family="Arial" font-size="38" font-weight="700" '
            'fill="%s">%s</text>' % (INK, esc(self.title)),
            '  <text x="120" y="140" font-family="Arial" font-size="22" fill="%s">%s</text>'
            % (GREY, esc(self.subtitle)),
        ]
        if self.panel:
            head.append('  <rect x="80" y="180" width="%s" height="%s" rx="12" fill="%s" '
                        'stroke="#444" stroke-width="2"/>' % (self.w - 160, self.h - 300, PANEL))
        (OUT / name).write_text("\n".join(head + self.parts + ["</svg>", ""]),
                                encoding="utf-8", newline="\n")
        print("  wrote", name)


# ------------------------------------------------------------------ 6.13 shell
def control_shell_block():
    c = Canvas("agriasic_rv32i_control_shell",
               "Section 6.13 - the control subsystem: Ibex, interconnect, memories, boot, debug",
               "Block diagram of agriasic_rv32i_control_shell. Chip pins enter on the left: clk, "
               "rst_n, gpio_start_i, gpio_boot_sel_i, five JTAG wires and four flash SPI wires. "
               "The shell contains the Ibex core, the four-master interconnect, IMEM, the MMIO "
               "bridge with DMEM, the boot loader, the golden boot ROM and the riscv-dbg debug "
               "module. Measurement-engine configuration and results leave on the right.", h=2620)
    c.box(190, 300, 760, 1060, "Chip pins (in)", [
        "clk", "rst_n", "gpio_start_i", "gpio_boot_sel_i", "",
        "gpio_jtag_tck_i", "gpio_jtag_tms_i", "gpio_jtag_trst_ni", "gpio_jtag_tdi_i", "",
        "gpio_flash_miso_i"], fill=INK, lead=36)
    c.box(190, 1450, 760, 560, "Chip pins (out)", [
        "gpio_jtag_tdo_o", "gpio_boot_fail_o", "", "gpio_flash_sck_o",
        "gpio_flash_cs_n_o", "gpio_flash_mosi_o"], fill=INK, lead=36)
    c.box(1120, 290, 2680, 1980, "control shell", fill=WHITE, stroke=INK, tfill=INK, head_size=30)
    c.box(1190, 390, 1180, 320, "ibex_top", [
        "RV32IMC + Zicsr, 3-stage", "RV32MFast multiplier", "latch regfile for ASIC"],
        fill=BLUE, tfill=INK)
    c.box(2500, 390, 1220, 320, "dmi_jtag  +  dm_top", [
        "TAP + DTM, IDCODE 0x14341001", "DM at 0x1A11_0000", "SBA is a full bus master"],
        fill=PURPLE, tfill=INK)
    c.box(1190, 800, 2530, 230, "agriasic_rv32i_bus   -   4 masters / 4 targets", [
        "priority   M1 core-data  >  M2 debug-SBA  >  M3 boot-loader  >  M0 core-fetch"],
        fill=GREEN, tfill=INK)
    c.box(1190, 1120, 780, 300, "agriasic_imem", [
        "1 KiB, 256 x 32", "writable: shadow-load target", "and JTAG patch target"],
        fill=ORANGE, tfill=INK, head_size=24)
    c.box(2030, 1120, 820, 300, "agriasic_rv32i_mmio", [
        "64 B peripheral window", "instantiates agriasic_dmem", "512 B, 128 x 32"],
        fill=ORANGE, tfill=INK, head_size=24)
    c.box(2910, 1120, 810, 300, "agriasic_spi_boot", [
        "golden ROM or SPI flash", "header + CRC-32 check", "then a firmware peripheral"],
        fill=ORANGE, tfill=INK, head_size=24)
    c.box(2910, 1470, 810, 200, "agriasic_boot_rom", ["148 words, constant table"],
        fill=RED, tfill=INK, head_size=24)
    c.box(1190, 1730, 2530, 430, "Three reset domains", [
        "rst_n_sync   ->  dm_top, dmi_jtag            debug survives everything",
        "sys_rst_n    ->  MMIO bridge, result latches  adds  && !ndmreset",
        "core_rst_n   ->  ibex_top only                adds  && !core_rst",
        "see control_shell_reset_domains.svg"],
        fill=WHITE, stroke=GREY, tfill=INK, head_size=24, line_size=18, line_fill=GREY, lead=30)
    c.box(3970, 300, 850, 900, "To measurement engine", [
        "start_pulse_o", "clear_errors_o", "cfg_pair_log2_o", "cfg_settle_cycles_o",
        "cfg_exc_divider_o", "cfg_conv_cycles_o", "cfg_mux_settle_o", "cfg_amplitude_o"],
        fill=INK, lead=36)
    c.box(3970, 1260, 850, 420, "From measurement engine", [
        "measurement_done_i", "measurement_result_dv_i/q_i", "measurement_result_cur_i/q_i"],
        fill=INK, head_size=24, lead=36)
    c.box(3970, 1740, 850, 300, "To analog front end", [
        "afe_pga_gain_o[1:0]", "afe_tia_rf_o[1:0]"], fill=ORANGE, tfill=INK, head_size=24)
    c.arrow(950, 700, 1120, 700, INK)
    c.arrow(950, 1650, 1120, 1650, INK)
    c.arrow(3800, 700, 3970, 700, BLUE_S)
    c.arrow(3970, 1430, 3800, 1430, GREEN_S)
    c.arrow(3800, 1880, 3970, 1880, ORANGE_S)
    c.note(2480, "Every port on the left edge is a bond pad. The cfg_* and result_* ports on the "
                 "right are die-internal wiring to the measurement engine - not pads, which is why "
                 "they carry no gpio_ prefix.")
    c.note(2530, "The core always fetches from IMEM SRAM, never from the boot ROM: both boot "
                 "sources shadow-load into the same writable array.")
    c.save("control_shell_block_diagram.svg")


def control_shell_reset_domains():
    c = Canvas("Reset domains inside the control shell",
               "Section 6.13 - three distinct resets; confusing them is the classic integration bug",
               "Reset tree. The chip pin rst_n passes through rst_sync to rst_n_sync, which resets "
               "the debug module and TAP and is removed by nothing else. sys_rst_n adds NOT "
               "ndmreset and resets the MMIO bridge and the result latches. core_rst_n adds NOT "
               "core_rst and resets only the Ibex core; core_rst is the registered inverse of "
               "gpio_start_i AND fw_valid.", h=2200)
    c.box(200, 430, 540, 180, "rst_n", ["chip pin, asynchronous"], fill=INK, head_size=26, line_size=18)
    c.arrow(740, 520, 900, 520, INK)
    c.box(900, 430, 540, 180, "rst_sync", ["2FF, synchronous release"], fill=BLUE, tfill=INK,
          head_size=26, line_size=18)
    c.line(1440, 520, 1700, 520, BLUE_S)
    c.line(1700, 520, 1700, 1660, BLUE_S)
    rows = [(520, "rst_n_sync", "", "dm_top,  dmi_jtag", PURPLE,
             "Debug survives everything. If ndmreset reset the DM, the debugger would"),
            (1090, "sys_rst_n", "&& !ndmreset", "MMIO bridge,  result latches", GREEN,
             "The debugger's \"reset the system\": config and sticky flags clear; the"),
            (1660, "core_rst_n", "&& !core_rst", "ibex_top   (and nothing else)", ORANGE,
             "core_rst = !(gpio_start_i && fw_valid), registered, so the release edge is")]
    tails = ["disconnect itself the moment it asked for a reset.",
             "memories are untouched, so a debugger can load and then ndmreset.",
             "glitch-free. Holding the core in reset is also the power-saving state."]
    for (y, name, extra, who, col, note), tail in zip(rows, tails):
        c.arrow(1700, y, 2020, y, BLUE_S)
        c.box(2020, y - 95, 660, 190, name, [extra] if extra else [], fill=col, tfill=INK,
              head_size=26, line_size=19)
        c.arrow(2680, y, 2980, y, BLUE_S)
        c.box(2980, y - 95, 1800, 190, who, [note, tail], fill=WHITE, stroke=INK, tfill=INK,
              head_size=24, line_size=17, line_fill=GREY, lead=26)
    c.note(1960, "Read top to bottom as widening scope: each domain resets its own block plus "
                 "everything below it. Nothing above a line is ever reset by something below it.")
    c.save("control_shell_reset_domains.svg")


# -------------------------------------------------------------- 6.14 Ibex core
def ibex_boot_image_map():
    c = Canvas("Firmware image layout in IMEM",
               "Section 6.14 - Ibex fetches boot_addr_i + 0x80; the vector table occupies 0x000-0x07F",
               "Memory map of the 592-byte firmware image in instruction memory. 0x000 to 0x07F is "
               "the 32-entry trap vector table, 128 bytes: entry 0 is exceptions, entry i is "
               "interrupt i, entry 31 is the NMI. 0x080 is _start, which sets the stack pointer, "
               "enables mie fast interrupt 0 and calls main. The image ends at 0x250. The rest of "
               "the 1 KiB IMEM is unused and filled with NOPs.", h=2400)
    rows = [(0x000, 0x080, ".vectors    32 x  j trap", 300, PURPLE,
             "128 B - entry 0 = exceptions, entry i = interrupt i, entry 31 = NMI"),
            (0x080, 0x0C0, "_start", 260, BLUE,
             "li sp, 0x0001_0800   csrw mie, 1<<16 (fast0)   call main"),
            (0x0C0, 0x250, "main,  run_sweep_point,  store_point", 300, GREEN,
             "the three-frequency sweep; ends parked in wfi after writing CTRL.FW_DONE"),
            (0x250, 0x400, "unused IMEM", 360, WHITE,
             "filled with 0x0000_0013 (NOP) - 1 KiB instantiated, 592 B used")]
    y = 330
    for lo, hi, name, h, col, note in rows:
        c.box(780, y, 2880, h, name, [note], fill=col, tfill=INK,
              stroke=INK if col == WHITE else col, head_size=26, line_size=18, line_fill=GREY)
        c.text(740, y + 46, "0x%03X" % lo, 26, INK, "700", "end")
        c.text(3700, y + 46, "%d B" % (hi - lo), 22, GREY)
        y += h + 40
    c.text(740, y + 10, "0x400", 26, INK, "700", "end")
    c.box(3900, 330, 900, 700, "Why 0x80", [
        "Ibex sets mtvec from", "boot_addr_i and begins", "execution at",
        "boot_addr_i + 0x80.", "", "boot_addr_i = 0, so the", "vector table lands at 0",
        "and _start at 0x80 -", "no linker trickery."], fill=INK, line_size=19, lead=32)
    c.box(3900, 1080, 900, 420, "Asserted at link time", [
        "_vectors == 0x0", "_start   == 0x80", "rodata/data/bss empty", "",
        "a layout mistake fails", "the build, not the die"], fill=RED, tfill=INK,
        head_size=22, line_size=18, lead=30)
    c.note(2180, "The whole image is 592 B with no heap, no malloc and no libc; measured stack "
                 "use is 28 B. That is what makes a synthesized golden ROM viable at all.")
    c.save("ibex_boot_image_map.svg")


# --------------------------------------------------------------- 6.15 the bus
def rv32i_bus_block():
    c = Canvas("agriasic_rv32i_bus",
               "Section 6.15 - four masters, four targets, fixed priority, per-master permissions",
               "Interconnect block diagram. Masters in priority order: M1 the core data port, M2 "
               "the debug system-bus-access master, M3 the boot loader, M0 the core fetch port. "
               "Targets: IMEM at 0x0000_0000, DMEM and MMIO at 0x0001_0000 and 0x8000_0000, the "
               "debug module at 0x1A11_0000, and an error responder for everything else. Each "
               "master reaches only the targets its permissions allow.")
    masters = [("M1", "core data port", "IMEM  -  DMEM/MMIO  -  DM", BLUE),
               ("M2", "debug SBA", "IMEM  -  DMEM/MMIO          (DM -> error)", PURPLE),
               ("M3", "boot loader", "IMEM only                   (else -> error)", ORANGE),
               ("M0", "core fetch", "IMEM  -  DM                 (else -> error)", GREEN)]
    y = 440
    for tag, name, perm, col in masters:
        c.box(220, y, 1200, 230, "%s   %s" % (tag, name), [perm], fill=col, tfill=INK,
              head_size=26, line_size=18, line_fill=GREY)
        c.arrow(1420, y + 115, 1780, y + 115, INK)
        y += 300
    c.box(1780, 440, 980, 1330, "decode  +  arbitrate", [
        "", "fixed priority, highest first:", "", "    M1   core data", "    M2   debug SBA",
        "    M3   boot loader", "    M0   core fetch", "",
        "permissions are enforced in", "the decode, not merely", "documented: a master that",
        "reaches outside its own set", "gets a bus error, never a", "silent wrong access"],
        fill=INK, head_size=28, line_size=19, lead=30)
    targets = [("IMEM", "0x0000_0000", "1 KiB", ORANGE),
               ("DMEM  +  MMIO", "0x0001_0000  /  0x8000_0000", "512 B  +  64 B", ORANGE),
               ("Debug module", "0x1A11_0000", "4 KiB", PURPLE),
               ("error   (no target)", "anything else", "bus error -> precise trap", RED)]
    y = 440
    for name, addr, size, col in targets:
        c.arrow(2760, y + 115, 3120, y + 115, INK)
        c.box(3120, y, 1640, 230, name, ["%s          %s" % (addr, size)], fill=col, tfill=INK,
              head_size=26, line_size=18, line_fill=GREY)
        y += 300
    c.note(1930, "A bus error is not a segmentation fault - there is no OS and no MMU here. The "
                 "target returns err, Ibex takes it as a precise load/store access fault, and the")
    c.note(1980, "trap handler sets CTRL.TRAP_SEEN. The regression asserts that bit never fires, "
                 "and the instrumented memory audit records zero accesses outside the map.")
    c.save("rv32i_bus_block_diagram.svg")


def rv32i_bus_handshake():
    c = Canvas("Bus handshake timing",
               "Section 6.15 - OBI-style req/gnt/rvalid; the target select is registered, not re-decoded",
               "Two-cycle handshake. In cycle 0 a master asserts req with an address, the decode "
               "grants it combinationally if it wins arbitration, and the selected target is "
               "registered. In cycle 1 rvalid and rdata return, muxed by that registered target "
               "select, together with err if the target was none or the bridge reported an error. "
               "No latency is added.", h=2000)
    c.box(280, 400, 1860, 190, "cycle 0", ["master asserts   req + addr + we + be + wdata"],
          fill=BLUE, tfill=INK, head_size=26, line_size=18, line_fill=GREY)
    c.arrow(2140, 495, 2520, 495, BLUE_S)
    c.box(2520, 400, 1320, 190, "decode", ["combinational: who wins, and which target"],
          fill=INK, head_size=26, line_size=18)
    c.arrow(3840, 495, 4260, 495, GREEN_S)
    c.box(4260, 400, 480, 190, "gnt", fill=GREEN, tfill=INK, head_size=26)
    c.path([(3180, 590), (3180, 820)], ORANGE_S)
    c.box(2520, 820, 1320, 210, "register the target", ["one 2-bit select per master"],
          fill=ORANGE, tfill=INK, head_size=24, line_size=18, line_fill=GREY)
    c.path([(3180, 1030), (3180, 1200)], ORANGE_S)
    c.box(280, 1200, 1860, 190, "cycle 1", ["the selected target drives read data"],
          fill=BLUE, tfill=INK, head_size=26, line_size=18, line_fill=GREY)
    c.arrow(2140, 1295, 2520, 1295, BLUE_S)
    c.box(2520, 1200, 1320, 190, "mux by registered select", fill=INK, head_size=23)
    c.arrow(3840, 1295, 4260, 1295, GREEN_S)
    c.box(4260, 1200, 480, 190, "rvalid", ["rdata"], fill=GREEN, tfill=INK,
          head_size=24, line_size=18)
    c.path([(3180, 1390), (3180, 1500)], RED_S)
    c.box(2520, 1500, 2220, 180, "err", [
        "if the registered target was \"none\", or the bridge itself reported an error"],
        fill=RED, tfill=INK, head_size=24, line_size=18, line_fill=GREY)
    c.note(1810, "Cost: three registered target-selects plus three rvalid flops. No latency is "
                 "added to any access - what is registered is the select, not the data path.")
    c.save("rv32i_bus_handshake.svg")


# ------------------------------------------------------- 6.16 memory wrappers
def imem_dmem_timing():
    c = Canvas("agriasic_imem / agriasic_dmem timing contract",
               "Section 6.16 - one-cycle synchronous SRAM with a no-change output policy",
               "Timing contract for the memory wrappers. The address is captured on the rising "
               "clock edge while ce_i is high. On a write cycle the addressed byte lanes are "
               "written and dout_o holds its previous value. On a read cycle dout_o is valid the "
               "following cycle. dout_o also holds whenever ce_i is low. This is the no-change "
               "output policy a foundry SRAM compiler macro provides.", h=2400)
    c.box(260, 380, 1080, 840, "Inputs", [
        "clk", "ce_i            chip enable", "addr_i          word address",
        "we_i[3:0]       byte write enables", "din_i[31:0]     write data"],
        fill=INK, lead=42)
    c.arrow(1340, 800, 1700, 800, INK)
    c.box(1700, 380, 1720, 840, "1-cycle synchronous SRAM", [
        "address captured on the rising", "clock edge while ce_i is high", "",
        "deliberately shaped so a foundry", "compiler macro can be dropped in",
        "without touching anything around it"], fill=BLUE, tfill=INK, head_size=28, lead=38)
    c.arrow(3420, 800, 3780, 800, BLUE_S)
    c.box(3780, 380, 960, 840, "dout_o[31:0]", [
        "read:    valid the", "            FOLLOWING cycle", "", "write:   HOLDS", "",
        "ce_i=0:  HOLDS"], fill=GREEN, tfill=INK, lead=40)
    c.box(260, 1380, 4480, 700, "Cycle behaviour", fill=WHITE, stroke=INK, tfill=INK, head_size=26)
    xs = [320, 760, 1300, 3100]
    for x, h in zip(xs, ["ce_i", "we_i", "this cycle", "dout_o on the next cycle"]):
        c.text(x, 1520, h, 21, INK, "700")
    c.line(300, 1550, 4700, 1550, LIGHT, 2)
    for i, r in enumerate([("1", "0000", "read addr_i", "memory[addr_i]"),
                           ("1", "non-zero", "write the enabled byte lanes of addr_i",
                            "HOLDS - no read-during-write data"),
                           ("0", "x", "idle", "HOLDS")]):
        for x, v in zip(xs, r):
            c.text(x, 1620 + i * 130, v, 20, GREY)
    c.box(260, 2130, 4480, 190, "Instantiated vs used", [
        "IMEM  1 KiB (256 x 32), writable     592 B used        DMEM  512 B (128 x 32)     "
        "100 B used"], fill=ORANGE, tfill=INK, head_size=24, line_size=19)
    c.note(2350, "No SRAM compiler is available, so these are standard-cell flop arrays: "
                 "both the flops and the NUM_WORDS:1 read mux scale with depth, and that mux "
                 "sits in the fetch path.")
    c.save("imem_dmem_timing_contract.svg")


# ---------------------------------------------------------------- 6.17 MMIO
def mmio_register_map():
    c = Canvas("agriasic_rv32i_mmio register map",
               "Section 6.17 - the complete 64-byte peripheral window at 0x8000_0000",
               "Register map of the peripheral window. CTRL, PAIR_LOG2, SETTLE, DIVIDER and CONV "
               "configure and start a measurement; STATUS and the four RESULT registers read it "
               "back; AFE_CTRL carries the analog gain and mux settling controls; BOOT_STATUS and "
               "BOOT_CTRL control the boot loader; SPI_CTRL, SPI_DATA and SPI_STATUS are the boot "
               "SPI engine handed to firmware after boot.", h=2800)
    groups = [("measurement", GREEN, [
        ("0x8000_0000", "CTRL", "W", "start, clear_err, FW_DONE, TRAP_SEEN"),
        ("0x8000_0004", "PAIR_LOG2", "RW", "M = 2^n sample pairs, clamped to 64"),
        ("0x8000_0008", "SETTLE", "RW", "excitation PERIODS to wait after start"),
        ("0x8000_000C", "DIVIDER", "RW", "raw N;  f_exc = f_clk / (16 N)"),
        ("0x8000_0010", "CONV", "RW", "SAR comparator regeneration, per bit trial"),
        ("0x8000_0014", "STATUS", "R", "busy, done, overrange, trap_seen, fw_done")]),
        ("results  (host computes Z(f) = dV(f) / I(f))", BLUE, [
            ("0x8000_0018", "RESULT_I", "R", "dV in-phase"),
            ("0x8000_001C", "RESULT_Q", "R", "dV quadrature"),
            ("0x8000_0034", "RESULT_CUR_I", "R", "current in-phase"),
            ("0x8000_0038", "RESULT_CUR_Q", "R", "current quadrature")]),
        ("analog front end", ORANGE, [
            ("0x8000_003C", "AFE_CTRL", "RW", "pga_gain, tia_rf, amplitude, mux_settle")]),
        ("boot", RED, [
            ("0x8000_0020", "BOOT_STATUS", "R", "state, error, fw_valid, strap, source, version"),
            ("0x8000_0024", "BOOT_CTRL", "W", "release / re-boot from flash / re-boot from ROM")]),
        ("boot SPI engine, handed to firmware after boot (self-reflash)", PURPLE, [
            ("0x8000_0028", "SPI_CTRL", "RW", "cs_n, clock divider"),
            ("0x8000_002C", "SPI_DATA", "RW", "tx byte / rx byte"),
            ("0x8000_0030", "SPI_STATUS", "R", "busy, fw_owned")])]
    y = 300
    for label, col, regs in groups:
        h = 60 + len(regs) * 92
        c.box(220, y, 4560, h, label, fill=col, tfill=INK, head_size=24, rx=8)
        ry = y + 92
        for addr, name, acc, desc in regs:
            c.text(280, ry + 26, addr, 23, INK)
            c.text(1000, ry + 26, name, 23, INK, "700")
            c.text(1720, ry + 26, acc, 23, GREY)
            c.text(1900, ry + 26, desc, 21, GREY)
            ry += 92
        y += h + 40
    c.note(y + 60, "Pulse generation: a store to CTRL asserts we for exactly one cycle, so "
                   "start_pulse_o is a single-cycle pulse no matter how long the bus access takes.")
    c.note(y + 110, "A repeated write therefore cannot restart a run already in progress. "
                    "Section 7.1 has the bit fields.")
    c.save("mmio_register_map.svg")


# ------------------------------------------------------------ 6.18 boot loader
def spi_boot_source_select():
    c = Canvas("Boot source selection",
               "Section 6.18 - the BOOT_SEL strap is latched once, on the first cycle out of reset",
               "Boot source selection. BOOT_SEL is latched on the first cycle out of reset because "
               "it is a strap, not a runtime control: a glitch after reset must not redirect a "
               "boot. Strap 0, the default, shadow-loads the golden ROM in about 150 cycles with "
               "no CRC needed because it is gates. Strap 1 loads from SPI flash in about 80,000 "
               "cycles with a header and CRC-32 check. Both write the same IMEM SRAM, and "
               "fw_valid then tells the shell to release the core.", h=2400)
    c.box(900, 300, 3200, 260, "gpio_boot_sel_i   latched on the FIRST cycle out of reset", [
        "a strap, not a runtime control - a glitch after reset must not redirect a boot"],
        fill=INK, head_size=26, line_size=19)
    c.path([(2500, 560), (2500, 700)], INK)
    c.path([(2500, 700), (1500, 700), (1500, 800)], INK)
    c.path([(2500, 700), (3500, 700), (3500, 800)], INK)
    c.text(1500, 770, "strap = 0   (default)", 22, INK, "700", "middle")
    c.text(3500, 770, "strap = 1", 22, INK, "700", "middle")
    c.box(830, 800, 1340, 520, "GOLDEN ROM shadow", [
        "", "~150 cycles  (0.9 us)", "", "no CRC needed -", "it is gates, it cannot rot", "",
        "a bare die with no flash", "and no host runs on its own"],
        fill=GREEN, tfill=INK, head_size=26, line_size=19, lead=32)
    c.box(2830, 800, 1340, 520, "SPI FLASH load", [
        "", "~80k cycles  (0.5 ms)", "", "16-byte header + CRC-32", "checked BEFORE release", "",
        "the patchable path:", "build, program, strap high"],
        fill=ORANGE, tfill=INK, head_size=26, line_size=19, lead=32)
    c.arrow(1500, 1320, 1500, 1500, GREEN_S)
    c.arrow(3500, 1320, 3500, 1500, ORANGE_S)
    c.box(1700, 1500, 1600, 230, "IMEM SRAM", ["one writable array - both sources land here"],
          fill=BLUE, tfill=INK, head_size=28, line_size=19)
    c.path([(1500, 1500), (1500, 1615), (1700, 1615)], GREEN_S)
    c.path([(3500, 1500), (3500, 1615), (3300, 1615)], ORANGE_S)
    c.arrow(2500, 1730, 2500, 1900, BLUE_S)
    c.box(1700, 1900, 1600, 200, "fw_valid", ["the shell releases the core"],
          fill=PURPLE, tfill=INK, head_size=28, line_size=19)
    c.note(2200, "BOOT_CTRL overrides the strap in both directions: bit 1 re-boots from flash, "
                 "bit 2 from the golden ROM, bit 0 releases the core without either.")
    c.note(2250, "Because this is a shadow-load and not a fetch-path mux, IMEM stays writable "
                 "afterwards - a debugger can patch a constant over JTAG with no rebuild or reflash.")
    c.save("spi_boot_source_select.svg")


def spi_boot_state_machine():
    c = Canvas("agriasic_spi_boot state machine",
               "Section 6.18 - the ROM path and the flash path converge on S_VERIFY",
               "Boot loader state machine. From S_DELAY the latched strap chooses: strap 0 goes "
               "straight to S_ROM, which copies USED_WORDS from the constant table to the bus; "
               "strap 1 waits out the flash power-up delay then runs S_CMD, S_HDR, S_CHECK, "
               "S_DATA and S_WRITE. Both paths converge on S_VERIFY, which ends in S_DONE, "
               "S_FAIL or S_SKIP. BOOT_CTRL retry and boot_rom return to S_DELAY.", h=2950)
    c.bubble(1560, 330, 780, 170, "S_DELAY", "the strap is sampled here")
    c.path([(1950, 500), (1950, 600), (1000, 600), (1000, 720)], GREEN_S)
    c.text(1180, 570, "strap = 0   (golden ROM)", 21, GREEN_S, "700", "middle")
    c.path([(1950, 600), (3300, 600), (3300, 720)], ORANGE_S)
    c.text(2950, 570, "strap = 1:  wait BOOT_DELAY_CYCLES for flash power-up",
           21, ORANGE_S, "700", "middle")
    c.bubble(620, 720, 760, 180, "S_ROM", "word -> bus, repeated USED_WORDS times", GREEN)
    flash = [("S_CMD", 720, "READ 0x03 + 24-bit address"),
             ("S_HDR", 990, "16 header bytes"),
             ("S_CHECK", 1260, "magic?  length?  alignment?"),
             ("S_DATA", 1530, "byte -> CRC, word staging"),
             ("S_WRITE", 1800, "word -> bus")]
    for name, y, note in flash:
        c.bubble(2920, y, 760, 180, name, note, ORANGE)
    for _, y, _ in flash[:-1]:
        c.path([(3300, y + 180), (3300, y + 270)], ORANGE_S)
    # S_WRITE loops back to S_DATA for the next word
    c.path([(3680, 1890), (3920, 1890), (3920, 1620), (3680, 1620)], ORANGE_S)
    c.text(3950, 1770, "more", 20, ORANGE_S, "700")
    # S_CHECK failure exits right, then down the far lane into S_FAIL
    c.path([(3680, 1350), (4300, 1350), (4300, 2505), (3980, 2505)], RED_S)
    c.text(4330, 1320, "bad magic / length", 20, RED_S, "700")
    # both paths converge on S_VERIFY
    c.path([(1000, 900), (1000, 2170), (1560, 2170)], GREEN_S)
    c.path([(3300, 1980), (3300, 2170), (2340, 2170)], ORANGE_S)
    c.bubble(1560, 2080, 780, 180, "S_VERIFY", "CRC match?   bus error?", BLUE)
    c.text(700, 1500, "ROM path", 22, GREEN_S, "700")
    c.text(3760, 1060, "flash path", 22, ORANGE_S, "700")
    terms = [(500, "S_DONE", GREEN, "fw_valid = 1, core released"),
             (1600, "S_SKIP", LIGHT, "IMEM_PRELOADED, or the debugger loaded IMEM"),
             (3280, "S_FAIL", RED, "core held in reset, BOOT_FAIL high")]
    for x, name, col, note in terms:
        c.bubble(x, 2420, 700, 170, name, note, col)
    c.path([(1950, 2260), (1950, 2350)], BLUE_S, arrow=False)
    c.path([(1950, 2350), (850, 2350), (850, 2420)], BLUE_S)
    c.path([(1950, 2350), (1950, 2420)], BLUE_S)
    c.path([(1950, 2350), (3630, 2350), (3630, 2420)], BLUE_S)
    # BOOT_CTRL re-boot returns to S_DELAY down the far-left lane
    c.path([(850, 2590), (850, 2700), (400, 2700), (400, 415), (1560, 415)], GREY, 2.5)
    c.text(420, 2670, "BOOT_CTRL.retry  /  BOOT_CTRL.boot_rom", 20, GREY, "700")
    c.note(2800, "A ROM copy can only ever report error 4 (bus error): there is no CRC to fail "
                 "and no magic to mismatch, because the source is gates.")
    c.save("spi_boot_state_machine.svg")


def flash_image_format():
    c = Canvas("Flash image format",
               "Section 6.18 - 16-byte header at flash address 0, then the linker output verbatim",
               "Flash image format. Offset 0 is the magic 0x41475241, the ASCII AGRA, which proves "
               "this is our firmware and catches a blank part that reads all ones. Offset 4 is the "
               "payload length in bytes. Offset 8 is a version reported in BOOT_STATUS bits 31 to "
               "16. Offset 12 is a CRC-32, zlib or IEEE 802.3, over the payload only. Offset 16 "
               "onward is the linker output word for word.", h=2000)
    fields = [(0, "magic", "0x41475241   \"AGRA\"", RED,
               "proves this is our firmware, and catches a blank part (reads 0xFF..)"),
              (4, "length", "payload bytes", ORANGE,
               "checked against IMEM_BYTES and for 4-byte alignment BEFORE any write"),
              (8, "version", "reported in BOOT_STATUS[31:16]", PURPLE,
               "0 for a ROM boot, since a ROM image carries no header"),
              (12, "crc32", "zlib / IEEE 802.3", GREEN,
               "over the PAYLOAD only - checked before the core is ever released"),
              (16, "payload", "the linker output, word for word", BLUE,
               "written straight into IMEM through the bus, as master M3")]
    y = 330
    for off, name, val, col, note in fields:
        h = 260 if off == 16 else 220
        c.text(700, y + 60, "offset %2d" % off, 26, INK, "700", "end")
        c.box(760, y, 3980, h, "%-10s %s" % (name, val), [note], fill=col, tfill=INK,
              head_size=26, line_size=19, line_fill=GREY)
        y += h + 30
    c.note(1720, "The CRC is over the payload only, so a corrupt header fails earlier and more "
                 "specifically (error 1 or 2) than a corrupt payload (error 3).")
    c.note(1770, "Verified by tb_agriasic_flash_boot scenarios B (corrupted payload byte) and C "
                 "(blank flash), which must both leave the core in reset.")
    c.save("flash_image_format.svg")


# -------------------------------------------------------------- 6.19 boot ROM
def boot_rom_generation():
    c = Canvas("agriasic_boot_rom - how the golden image gets into gates",
               "Section 6.19 - promotion is explicit and never a side effect of a build",
               "Generation flow for the golden boot ROM. The firmware build produces a hex image. "
               "Running gen_boot_rom.py with promote copies that image to fw/golden and records "
               "date, word count and SHA-256 in GOLDEN.md, then regenerates "
               "rtl/rv32i/agriasic_boot_rom.sv as a constant case table. Ordinary synthesis maps "
               "that table into about 1,000 gates. build.sh deliberately does not regenerate it.",
               h=2400)
    c.box(260, 340, 1120, 300, "fw/build.sh", [
        "riscv32 gcc -Os", "-march=rv32imc_zicsr", "-> agriasic_fw.hex"], fill=BLUE, tfill=INK)
    c.arrow(1380, 490, 1720, 490, BLUE_S)
    c.box(1720, 340, 1500, 300, "gen_boot_rom.py --promote", [
        "an explicit, deliberate act -", "never run by build.sh"], fill=RED, tfill=INK,
        head_size=24, line_size=19)
    c.arrow(3220, 490, 3560, 490, RED_S)
    c.box(3560, 340, 1180, 300, "fw/golden/", [
        "agriasic_fw_golden.hex", "GOLDEN.md: date, words,", "SHA-256"], fill=GREEN, tfill=INK)
    c.path([(4150, 640), (4150, 800), (2600, 800), (2600, 940)], GREEN_S)
    c.box(1720, 940, 1760, 280, "gen_boot_rom.py", [
        "regenerates the RTL from fw/golden/ only"], fill=RED, tfill=INK,
        head_size=24, line_size=19, line_fill=GREY)
    c.arrow(2600, 1220, 2600, 1380, RED_S)
    c.box(1400, 1380, 2400, 320, "rtl/rv32i/agriasic_boot_rom.sv   (GENERATED)", [
        "256-word case table, 148 used",
        "default: 32'h0000_0013  (NOP)"], fill=ORANGE, tfill=INK, head_size=24, line_size=19)
    c.arrow(2600, 1700, 2600, 1860, ORANGE_S)
    c.box(1400, 1860, 2400, 300, "synthesis", [
        "a constant table maps to gates, not storage:",
        "+1,027 combinational primitives,  +6 flops"], fill=PURPLE, tfill=INK,
        head_size=26, line_size=19)
    c.box(4000, 940, 740, 1220, "Why no ROM compiler", [
        "148 words is small", "enough that ordinary", "synthesis beats a", "foundry ROM macro.",
        "", "A writable array of", "the same depth would", "need 4,736 storage", "bits.", "",
        "Past roughly 1 KiB", "this trade inverts", "and a ROM macro", "becomes the right", "call."],
        fill=INK, head_size=22, line_size=19, lead=30)
    c.note(2230, "Only promote an image that has passed the full regression: GOLDEN.md is what "
                 "makes the thing in silicon reviewable in version control.")
    c.save("boot_rom_generation_flow.svg")


# ------------------------------------------------------- 6.20 debug module
def debug_module_integration():
    c = Canvas("Debug module integration (riscv-dbg)",
               "Section 6.20 - the DM is a slave on BOTH core ports, and a master in its own right",
               "Debug module integration. The five JTAG pins drive dmi_jtag, the TAP and debug "
               "transport module, which crosses to the core clock domain and talks DMI to dm_top. "
               "dm_top raises debug_req to ibex_top and ndmreset to the system reset, and is a "
               "slave on both core ports: the instruction side reaches the debug ROM and program "
               "buffer, the data side reaches data0/1 and the halted and resume flags. Its system "
               "bus access port is a bus master alongside the core.", h=2550)
    c.box(240, 420, 800, 420, "JTAG pins", [
        "gpio_jtag_tck_i", "gpio_jtag_tms_i", "gpio_jtag_trst_ni", "gpio_jtag_tdi_i",
        "gpio_jtag_tdo_o"], fill=INK, head_size=26, line_size=19, lead=36)
    c.arrow(1040, 630, 1360, 630, INK)
    c.box(1360, 420, 900, 420, "dmi_jtag", [
        "TAP + DTM", "IDCODE 0x14341001", "IR length 5", "", "TCK -> clk CDC:", "2-phase handshake"],
        fill=PURPLE, tfill=INK, head_size=28, line_size=19, lead=30)
    c.arrow(2260, 630, 2620, 630, PURPLE_S)
    c.text(2440, 600, "DMI", 20, PURPLE_S, "700", "middle")
    c.box(2620, 420, 1000, 420, "dm_top", [
        "Debug Spec 0.13", "DM at 0x1A11_0000", "", "halt +0x800", "resume +0x808",
        "exception +0x810"], fill=PURPLE, tfill=INK, head_size=28, line_size=19, lead=30)
    c.arrow(3620, 520, 4180, 520, RED_S)
    c.box(4180, 440, 620, 160, "ibex_top", ["debug_req"], fill=BLUE, tfill=INK,
          head_size=24, line_size=18)
    c.arrow(3620, 740, 4180, 740, RED_S)
    c.box(4180, 660, 620, 160, "sys_rst_n", ["ndmreset"], fill=ORANGE, tfill=INK,
          head_size=24, line_size=18)
    c.arrow(3120, 840, 3120, 1080, GREEN_S)
    c.text(3160, 990, "SBA - a bus master, like the core data port", 21, GREEN_S, "700")
    c.box(2300, 1080, 1640, 200, "agriasic_rv32i_bus", ["master M2"], fill=GREEN, tfill=INK,
          head_size=28, line_size=19)
    c.box(240, 1420, 4560, 500, "The DM is also a SLAVE on both core ports", [
        "instruction side  ->  debug ROM + program buffer      the core fetches its debug "
        "handler from the DM",
        "data side         ->  data0/1, halted and resume flags  the core reports status back "
        "through the DM", "",
        "That is why the bus lets M0 (core fetch) and M1 (core data) target 0x1A11_0000 at all."],
        fill=WHITE, stroke=INK, tfill=INK, head_size=26, line_size=20, line_fill=GREY, lead=38)
    c.box(240, 1990, 4560, 260, "Note: exception address", [
        "riscv-dbg places the exception entry 16 bytes past halt (+0x810), NOT the +0x808 that "
        "Ibex defaults to.",
        "DmExceptionAddr is set explicitly in the shell - getting this wrong makes abstract "
        "commands fail in ways that look like core bugs."],
        fill=RED, tfill=INK, head_size=24, line_size=19, lead=32)
    c.note(2420, "ndmreset resets the core and the peripheral bridge only. The DM, the TAP and "
                 "every memory survive it, so a debugger can load an image and then reset the system.")
    c.save("debug_module_integration.svg")


# -------------------------------------------------- 6.21 measurement_fsm Rev 5
def measurement_fsm_rev5_states():
    c = Canvas("measurement_fsm - Rev 5 two-channel sequencing",
               "Section 6.21 - one S/H strobe per phase point, then two conversions",
               "Rev 5 measurement FSM. S_IDLE waits for start. S_SETTLE counts settle_cycles_i "
               "excitation periods. S_WAIT watches phase_index for a match and issues one "
               "sample-and-hold strobe that freezes both channels. S_CONV_DV converts the voltage "
               "channel with mux 0 and S_CONV_CUR the current channel with mux 1, with no new "
               "strobe between them. S_ACCUM adds the terms, S_LOOP advances the phase point or "
               "the pair, and S_DONE snapshots all four accumulators into their shadows on the "
               "single cycle busy drops.", h=3100)
    c.bubble(300, 400, 640, 180, "S_IDLE")
    c.arrow(940, 490, 1180, 490, BLUE_S)
    c.text(1060, 460, "start", 21, BLUE_S, "700", "middle")
    c.bubble(1180, 400, 760, 180, "S_SETTLE", "counts settle_cycles_i EXCITATION PERIODS", BLUE)
    c.arrow(1940, 490, 2200, 490, BLUE_S)
    c.bubble(2200, 400, 800, 180, "S_WAIT", "watch phase_index for the target phase point", BLUE)
    c.path([(2600, 580), (2600, 760)], ORANGE_S)
    c.text(2680, 690, "phase match  +  ONE S/H strobe  (freezes BOTH channels)", 21, ORANGE_S, "700")
    c.bubble(2200, 760, 800, 180, "S_CONV_DV", "mux_sel = 0 (PGA),  8 bit trials", ORANGE)
    c.path([(2600, 940), (2600, 1120)], ORANGE_S)
    c.bubble(2200, 1120, 800, 180, "S_CONV_CUR",
             "mux_sel = 1 (TIA),  8 bit trials, NO new strobe", ORANGE)
    c.path([(2600, 1300), (2600, 1480)], GREEN_S)
    c.bubble(2200, 1480, 800, 180, "S_ACCUM",
             "add this phase point into the four accumulators", GREEN)
    c.path([(2600, 1660), (2600, 1840)], GREEN_S)
    c.bubble(2200, 1840, 800, 180, "S_LOOP", None, GREEN)
    # loop back to S_WAIT up a clear right-hand lane, clear of every block
    c.path([(3000, 1930), (3450, 1930), (3450, 490), (3000, 490)], GREEN_S)
    c.text(3520, 1170, "PT_0 / PT_180 / PT_90  ->  next phase point", 20, GREEN_S)
    c.text(3520, 1215, "pairs remaining       ->  back to S_WAIT", 20, GREEN_S)
    c.path([(2200, 1930), (1500, 1930)], PURPLE_S)
    c.text(1560, 1900, "all pairs done", 21, PURPLE_S, "700")
    c.bubble(700, 1840, 800, 180, "S_DONE", None, PURPLE)
    c.path([(1100, 1840), (1100, 640), (620, 640), (620, 580)], GREY, 2.5)
    c.box(300, 2160, 4500, 290, "S_DONE snapshots all four accumulators into their shadows", [
        "on the SINGLE cycle busy_o drops - so a read that lands mid-run returns the previous "
        "COMPLETE result, never",
        "a partial sum, and dV and I always come from the same run. That matters because they "
        "are divided against each other."],
        fill=PURPLE, tfill=INK, head_size=26, line_size=20, lead=36)
    c.box(300, 2500, 4500, 400, "Four accumulators, eight conversions per accumulation pair", [
        "dv_i  = sum( dV(0deg) - dV(180deg) )            cur_i = sum( I(0deg) - I(180deg) )",
        "dv_q  = sum( dV(90deg) - dV(270deg) )           cur_q = sum( I(90deg) - I(270deg) )",
        "Z(f) = (dv_i + j dv_q) / (cur_i + j cur_q)          <-  computed HOST-side, never on die"],
        fill=INK, head_size=26, line_size=21, lead=42)
    c.note(2970, "point_q walks PT_0 -> PT_180 -> PT_90 -> PT_270; 4 phase points x 2 channels "
                 "= 8 conversions per accumulation pair.")
    c.save("measurement_fsm_rev5_states.svg")


def simultaneous_sample_hold():
    c = Canvas("Simultaneous sample-and-hold",
               "Section 6.21 - ONE strobe freezes both channels; the conversions may then be skewed",
               "Simultaneous sample-and-hold. A single strobe at the target phase point freezes "
               "both the voltage and the current sample-and-hold. The analog mux then presents "
               "each held value to the one SAR ADC in turn. The voltage/current phase relationship "
               "is set by that single instant, not by the order or the spacing of the two "
               "conversions, so skew between them costs nothing.", h=2200)
    c.box(260, 330, 1100, 180, "phase point reached", fill=BLUE, tfill=INK, head_size=26)
    c.arrow(810, 510, 810, 680, ORANGE_S, 4)
    c.text(860, 620, "ONE strobe  (afe_sample_o)", 24, ORANGE_S, "700")
    c.box(260, 680, 1100, 220, "S/H   dV", ["differential PGA on E2/E3"], fill=ORANGE, tfill=INK,
          head_size=28, line_size=19)
    c.box(260, 960, 1100, 220, "S/H   I", ["TIA on E4"], fill=ORANGE, tfill=INK,
          head_size=28, line_size=19)
    c.path([(1360, 790), (1700, 790), (1700, 930)], ORANGE_S, arrow=False)
    c.path([(1360, 1070), (1700, 1070), (1700, 930)], ORANGE_S, arrow=False)
    c.arrow(1700, 930, 2100, 930, ORANGE_S)
    c.text(1450, 900, "afe_mux_sel_o", 20, GREY)
    c.box(2100, 810, 1000, 240, "SAR ADC", ["8-bit differential", "one converter, two channels"],
          fill=GREEN, tfill=INK, head_size=28, line_size=19)
    c.arrow(3100, 930, 3500, 930, GREEN_S)
    c.box(3500, 810, 1240, 240, "two conversions", ["mux = 0 then mux = 1", "no new strobe between"],
          fill=BLUE, tfill=INK, head_size=26, line_size=19)
    c.box(260, 1320, 4480, 460, "Why this is the whole point", [
        "The voltage/current phase relationship is set by THAT INSTANT, not by the order the two",
        "conversions happen to run in. A skew between the conversions therefore costs nothing.", "",
        "The alternative considered - measure dV on one excitation period and I on the next - "
        "would have made",
        "the phase difference depend on cycle-to-cycle excitation stability, which is exactly the "
        "quantity being measured."],
        fill=WHITE, stroke=INK, tfill=INK, head_size=26, line_size=20, line_fill=GREY, lead=36)
    c.note(1880, "Budget: the hold must survive both conversions - roughly 425 ns of droop budget "
                 "at conv_cycles = 1.")
    c.save("simultaneous_sample_hold.svg")


# --------------------------------------------------- 6.22 excitation Rev 5 DAC
def excitation_cosine_table():
    codes = [255, 245, 218, 177, 128, 79, 38, 11, 1, 11, 38, 79, 128, 177, 218, 245]
    c = Canvas("The excitation table is a COSINE, and that is load-bearing",
               "Section 6.22 - sample points 0/4/8/12 must land on the drive peaks and the zero crossings",
               "Plot of the 16-point cosine table driving the sine DAC. Code equals 128 plus "
               "round of 127 times cos of 2 pi k over 16. Index 0 is the positive peak at code "
               "255 and is the I positive term; index 4 is mid-code 128 and is the Q positive "
               "term; index 8 is the negative peak at code 1 and is the I negative term; index 12 "
               "is mid-code again and is the Q negative term. A sine table would put a zero "
               "crossing at index 0 and the I channel would measure nothing.", h=2800)
    x0, y0, w, h = 700, 360, 3400, 1200
    c.add('<rect x="%s" y="%s" width="%s" height="%s" fill="%s" stroke="%s" stroke-width="2"/>'
          % (x0, y0, w, h, WHITE, INK))
    for code in (255, 192, 128, 64, 1):
        yy = y0 + h - (code - 1) * h / 254.0
        c.line(x0, yy, x0 + w, yy, "#E0E0E0", 2)
        c.text(x0 - 25, yy + 9, str(code), 22, GREY, None, "end")
    c.text(x0 - 25, y0 - 30, "code", 22, INK, "700", "end")
    pts = []
    for k, code in enumerate(codes):
        px = x0 + 90 + k * (w - 180) / 15.0
        py = y0 + h - (code - 1) * h / 254.0
        pts.append((round(px), round(py)))
    c.add('<polyline points="%s" fill="none" stroke="%s" stroke-width="3" '
          'stroke-dasharray="10 8"/>' % (" ".join("%s,%s" % p for p in pts), LIGHT))
    marks = {0: ("I+", RED_S), 4: ("Q+", PURPLE_S), 8: ("I-", RED_S), 12: ("Q-", PURPLE_S)}
    for k, (px, py) in enumerate(pts):
        col, r = (marks[k][1], 16) if k in marks else (BLUE_S, 10)
        c.dot(px, py, r, col)
        c.text(px, y0 + h + 40, str(k), 22, INK if k in marks else GREY,
               "700" if k in marks else None, "middle")
        if k in marks:
            c.text(px, y0 + h + 80, marks[k][0], 26, col, "700", "middle")
            c.line(px, py, px, y0 + h, col, 2)
    c.text(x0 + w / 2, y0 + h + 130, "phase_index", 24, INK, "700", "middle")
    c.box(4250, 360, 560, 1200, "Sample points", [
        "k = 0", "  peak", "  -> I positive", "", "k = 4", "  mid-code", "  -> Q positive", "",
        "k = 8", "  trough", "  -> I negative", "", "k = 12", "  mid-code", "  -> Q negative"],
        fill=INK, head_size=24, line_size=19, lead=30)
    c.box(700, 1760, 4110, 300, "Half-period symmetry - the +/- chop contract", [
        "code[k] + code[k+8] == 256 for every k, exactly, by construction:   255+1   245+11   "
        "218+38   177+79   128+128",
        "This is what makes (D(0deg) - D(180deg)) cancel offset and drift - the two samples sit "
        "on equal and opposite excursions about VCM."],
        fill=GREEN, tfill=INK, head_size=26, line_size=20, lead=38)
    c.box(700, 2120, 4110, 300, "Why not a sine table", [
        "A sine table would put a ZERO CROSSING at index 0. The FSM samples at 0/4/8/12, so the "
        "I channel would sit on",
        "the crossings and measure nothing at all. Cosine is not a cosmetic choice - it is what "
        "makes synchronous I/Q demodulation work."],
        fill=RED, tfill=INK, head_size=26, line_size=20, lead=38)
    c.note(2530, "f_exc = f_clk / (16 N). At 160 MHz, N = 1 / 100 / 10000 gives 10 MHz / 100 kHz "
                 "/ 1 kHz - and the DAC update rate is 16 x f_exc, so 160 MSa/s at the top point.")
    c.note(2580, "amplitude_i attenuates the EXCURSION only (an arithmetic shift of the delta), "
                 "so mid-code stays at VCM and the symmetry above is preserved at every amplitude.")
    c.save("excitation_cosine_table.svg")


# ------------------------------------------------------- 6.23 sar_controller
def sar_controller_rev5_states():
    c = Canvas("sar_controller - Rev 5 channel multiplexing",
               "Section 6.23 - S_MUX_WAIT is new; acquisition is separated from conversion",
               "Rev 5 SAR controller state machine. S_IDLE accepts a request and drives "
               "afe_mux_sel_o from channel_i and afe_sample_o from take_sample_i. S_MUX_WAIT is "
               "new: it waits mux_settle_cycles_i so the analog mux and the selected "
               "sample-and-hold settle onto the comparator input before the first trial. "
               "S_TRIAL_SET, S_TRIAL_WAIT and S_TRIAL_EVAL then run eight bit trials MSB first, "
               "and the converged code is returned on code_o.", h=2200)
    xs = [280, 1180, 2180, 3100, 4020]
    names = ["S_IDLE", "S_MUX_WAIT", "S_TRIAL_SET", "S_TRIAL_WAIT", "S_TRIAL_EVAL"]
    cols = [WHITE, ORANGE, BLUE, BLUE, BLUE]
    notes = [None, "NEW in Rev 5", "drive the trial code", "comparator regenerates", "keep or drop the bit"]
    for x, n, col, note in zip(xs, names, cols, notes):
        c.bubble(x, 480, 800, 190, n, note, col)
    for a, b in zip(xs[:-1], xs[1:]):
        c.arrow(a + 800, 575, b, 575, BLUE_S)
    c.text(1130, 545, "accept", 20, BLUE_S, "700", "middle")
    c.path([(4420, 670), (4420, 900), (2580, 900), (2580, 670)], GREEN_S)
    c.text(3500, 870, "8 trials, MSB first", 22, GREEN_S, "700", "middle")
    c.path([(4820, 575), (4900, 575), (4900, 1060), (700, 1060), (700, 670)], GREY, 2.5)
    c.text(4300, 1030, "done  ->  code_o", 22, GREY, "700", "end")
    c.box(280, 1200, 2280, 480, "On acceptance, in S_IDLE", [
        "afe_mux_sel_o   <=  channel_i", "afe_sample_o    <=  take_sample_i", "",
        "Separating acquisition from conversion is what lets the FSM",
        "strobe ONE sample-and-hold for a phase point and then run",
        "two conversions off the held values."],
        fill=INK, head_size=26, line_size=19, lead=32)
    c.box(2680, 1200, 2040, 480, "S_MUX_WAIT", [
        "mux_settle_cycles_i lets the analog mux and the", "selected S/H settle onto the "
        "comparator input", "BEFORE trial 1.", "",
        "It is a runtime register (AFE_CTRL[15:8]), not a", "parameter - the settling time is an "
        "analog number", "nobody knows yet."],
        fill=ORANGE, tfill=INK, head_size=26, line_size=19, lead=32)
    c.box(280, 1780, 4440, 300, "Conversion time", [
        "8 x (3 + conv_cycles_i) clock cycles.   Verified empirically: 24 cycles at "
        "conv_cycles_i = 0, 40 at conv_cycles_i = 2.",
        "At 160 MHz with conv_cycles_i = 1 that is 200 ns per conversion, so afe_adc_dac_o must "
        "settle within 25 ns per trial."],
        fill=GREEN, tfill=INK, head_size=26, line_size=20, lead=38)
    c.note(2010, "The converged code is returned on code_o; the Rev 4.3 d_plus_o / d_minus_o pair "
                 "is gone, because the two channels are now sequenced by the FSM rather than held here.")
    c.note(2060, "afe_adc_comp_i is a timed, UNSYNCHRONIZED path. Do not add a synchronizer: "
                 "conv_cycles_i is what must cover comparator regeneration at the worst corner.")
    c.save("sar_controller_rev5_states.svg")


# ------------------------------------------------------------ 6.12 rst_sync
def rst_sync_timing():
    c = Canvas("rst_sync - asynchronous assert, synchronous release",
               "Section 6.12 - one instance per chip-boundary top; everything internal runs off rst_n_sync",
               "Reset synchronizer. The asynchronous chip pin rst_n clears both flops of a "
               "two-flop chain immediately, so assertion is visible within nanoseconds "
               "regardless of clock phase. Release is synchronous: a 1 walks through the two "
               "flops, so rst_n_sync deasserts exactly two clock edges later and always on a "
               "rising edge. This gives every internal flop a clean release edge no matter when "
               "the external pin actually released.", h=2400)
    c.box(240, 380, 620, 200, "rst_n", ["chip pin,", "asynchronous"], fill=INK,
          head_size=28, line_size=19)
    c.box(1120, 380, 700, 200, "FF1", ["D = 1"], fill=BLUE, tfill=INK, head_size=28, line_size=19)
    c.box(2080, 380, 700, 200, "FF2", ["D = FF1"], fill=BLUE, tfill=INK, head_size=28, line_size=19)
    c.box(3040, 380, 800, 200, "rst_n_sync", ["to every internal block"], fill=GREEN, tfill=INK,
          head_size=28, line_size=19)
    c.arrow(860, 480, 1120, 480, INK)
    c.arrow(1820, 480, 2080, 480, BLUE_S)
    c.arrow(2780, 480, 3040, 480, BLUE_S)
    c.path([(550, 580), (550, 720), (1470, 720), (1470, 580)], RED_S)
    c.path([(550, 720), (2430, 720), (2430, 580)], RED_S)
    c.text(1200, 780, "asynchronous clear reaches BOTH flops directly", 21, RED_S, "700")
    c.box(240, 880, 4520, 420, "The two halves behave differently on purpose", [
        "ASSERT    asynchronous - visible within 1 ns regardless of clock phase, so a reset "
        "works even with no clock running.",
        "RELEASE   synchronous  - a 1 walks the chain, so rst_n_sync rises exactly 2 clk edges "
        "later and always on a posedge.",
        "That asymmetry is the whole point: you can always stop the chip, but it only ever "
        "starts on a clean edge."],
        fill=WHITE, stroke=INK, tfill=INK, head_size=26, line_size=20, line_fill=GREY, lead=38)
    c.box(240, 1380, 2180, 420, "Instantiated once per chip top", [
        "agriasic_digital_rv32i_top", "agriasic_digital_spi_top",
        "agriasic_digital_programming_top", "",
        "NOT inside agriasic_digital_top, which always", "receives an already-synchronized reset."],
        fill=ORANGE, tfill=INK, head_size=26, line_size=19, lead=30)
    c.box(2580, 1380, 2180, 420, "Verified by tb_rst_sync.sv (stage 6)", [
        "Four clk-unaligned assert/deassert phase offsets:", "",
        "- assertion visible within 1 ns at every phase", "- deassertion always exactly 2 clk edges",
        "- deassertion always lands on a posedge", "",
        "which proves it is not working by lucky alignment."],
        fill=PURPLE, tfill=INK, head_size=26, line_size=19, lead=30)
    c.note(1930, "In the RV32I design rst_n_sync is only the first of three domains: sys_rst_n "
                 "adds && !ndmreset, and core_rst_n adds && !core_rst.")
    c.note(1980, "See control_shell_reset_domains.svg (section 6.13) for how the three relate.")
    c.save("rst_sync_timing.svg")


# -------------------------------------------------------- 6.24 host SPI port
def spi_host_block():
    c = Canvas("agriasic_spi_host - the host SPI port (bus master M4)",
               "Section 6.24 - an external host reads results out of DMEM while the core sleeps",
               "Host SPI port. Four pads carry a mode-0 SPI slave: the host drives SCK, CS_N and "
               "MOSI and reads MISO. spi_slave oversamples them into the core clock and hands up "
               "bytes; a framing state machine turns command plus address plus data into bus "
               "transactions on master port M4. Permissions are enforced in the interconnect: M4 "
               "reaches DMEM and the peripheral window only, never IMEM and never the debug "
               "module.", h=2700)
    c.box(200, 320, 820, 420, "Host SPI pads", [
        "gpio_spi_sclk_i     in", "gpio_spi_cs_n_i     in", "gpio_spi_mosi_i     in",
        "gpio_spi_miso_o     out", "gpio_spi_miso_oe_o  out"], fill=INK, lead=38)
    c.text(220, 790, "Chip is the SLAVE here.", 20, GREY)
    c.text(220, 825, "Every wire runs the OPPOSITE", 20, GREY)
    c.text(220, 860, "direction on the flash port,", 20, GREY)
    c.text(220, 895, "which is why the pads cannot", 20, GREY)
    c.text(220, 930, "be shared.", 20, GREY)
    c.arrow(1020, 530, 1320, 530, INK)
    c.box(1320, 320, 980, 420, "spi_slave", [
        "2FF oversampling into clk -", "not a second clock domain", "",
        "max SCK = f_clk / 16", "", "byte in / byte out"], fill=BLUE, tfill=INK, lead=36)
    c.arrow(2300, 530, 2600, 530, BLUE_S)
    c.box(2600, 320, 1060, 420, "framing FSM", [
        "S_CMD   -> S_ADDR", "S_ADDR  -> S_READ / S_WRITE", "S_STATUS", "",
        "CS_N release resets framing,", "so a lost host just retries"], fill=GREEN, tfill=INK, lead=36)
    c.arrow(3660, 530, 3960, 530, GREEN_S)
    c.box(3960, 320, 840, 420, "bus master M4", [
        "req / gnt / rvalid", "whole 32-bit words", "", "sticky error bit on", "any refusal"],
        fill=PURPLE, tfill=INK, lead=38)
    c.path([(4380, 740), (4380, 900), (2500, 900), (2500, 1040)], PURPLE_S)
    c.box(1500, 1040, 2000, 200, "agriasic_rv32i_bus", ["priority  M1 > M2 > M4 > M3 > M0"],
          fill=GREEN, tfill=INK, head_size=28, line_size=20)
    c.path([(2000, 1240), (2000, 1380)], GREEN_S)
    c.path([(3000, 1240), (3000, 1380)], RED_S)
    c.box(1200, 1380, 1600, 230, "DMEM  +  peripheral window", ["ALLOWED"],
          fill=ORANGE, tfill=INK, head_size=24, line_size=20)
    c.box(2900, 1380, 1900, 230, "IMEM  and  debug module", ["REFUSED -> bus error"],
          fill=RED, tfill=INK, head_size=24, line_size=20)
    c.box(200, 1720, 4600, 340, "Why the permissions are in the decode, not in this block", [
        "Not IMEM: a field host cannot overwrite firmware - that stays JTAG's job.   "
        "Not the DM: a field host cannot take debug control.",
        "Enforcing it in the interconnect means a bug in this block, or a host that sends a bad "
        "address, still cannot reach either."],
        fill=WHITE, stroke=INK, tfill=INK, head_size=26, line_size=20, line_fill=GREY, lead=38)
    c.box(200, 2110, 4600, 380, "Wire protocol (one transaction per CS_N assertion)", [
        "byte 0       command    0x03 READ   0x02 WRITE   0x05 RDSR (status)",
        "bytes 1..4   32-bit address, BIG endian, as SPI NOR does it",
        "then         data bytes, LITTLE endian within each word, address auto-incrementing by 4",
        "status byte  [0] busy   [1] sticky error, cleared at the END of the status read"],
        fill=INK, head_size=26, line_size=20, lead=36)
    c.note(2600, "A byte is at least 128 core clocks and a bus access is 2, so the access always "
                 "finishes inside the inter-byte gap - no flow control is needed on the wire.")
    c.save("spi_host_block_diagram.svg")


ALL = [control_shell_block, control_shell_reset_domains, ibex_boot_image_map,
       rv32i_bus_block, rv32i_bus_handshake, imem_dmem_timing, mmio_register_map,
       spi_boot_source_select, spi_boot_state_machine, flash_image_format,
       boot_rom_generation, debug_module_integration, measurement_fsm_rev5_states,
       simultaneous_sample_hold, excitation_cosine_table, sar_controller_rev5_states,
       rst_sync_timing, spi_host_block]

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    print("generating %d module diagrams into %s" % (len(ALL), OUT))
    for fn in ALL:
        fn()
    print("done")
