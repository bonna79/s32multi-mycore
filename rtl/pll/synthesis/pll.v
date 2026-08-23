// Hand-reconstructed replacement for the original (never-committed) Qsys/
// MegaWizard output that rtl/pll/pll.qip expects at synthesis/pll.qip +
// synthesis/pll.v + synthesis/pll_0002.v. See PROFILE_CONTRACT.md, the
// 2026-08-23 "PLL hand-reconstruction" entry, for the derivation and the
// explicit caveat that this has NOT been verified on real hardware.
`timescale 1 ps / 1 ps
module pll (
		input  wire        refclk_clk,
		input  wire        reset_reset,
		output wire        outclk0_clk,   // ~96.634615 MHz (clk_ram)
		output wire        outclk1_clk,   // ~48.317307 MHz (clk_sys)
		output wire        outclk2_clk,   // ~96.634615 MHz, ~180 deg (SDRAM_CLK)
		output wire        outclk3_clk,   // ~24.158653 MHz (clk_v25)
		output wire        locked_export
	);

	pll_0002 pll_inst (
		.refclk   (refclk_clk),
		.rst      (reset_reset),
		.outclk_0 (outclk0_clk),
		.outclk_1 (outclk1_clk),
		.outclk_2 (outclk2_clk),
		.outclk_3 (outclk3_clk),
		.locked   (locked_export)
	);

endmodule
