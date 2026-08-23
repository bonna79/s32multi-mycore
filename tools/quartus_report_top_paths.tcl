# Hand-reconstructed placeholder for the original (never-committed) custom
# TimeQuest report script referenced by Arcade-SegaSystem32Multi.qsf via:
#   set_global_assignment -name TIMEQUEST_REPORT_SCRIPT tools/quartus_report_top_paths.tcl
#
# See PROFILE_CONTRACT.md, 2026-08-23 "TimeQuest report script placeholder"
# entry. Like rtl/pll/synthesis/, this file was never committed to the repo,
# so the CI build failed with "File not found" during the TimeQuest Timing
# Analyzer stage even after Analysis & Synthesis, Fitter and Assembler (i.e.
# the .rbf itself) had already completed successfully.
#
# This is a placeholder, not a byte-for-byte recovery of the original: its
# exact custom reporting logic was lost. This version just writes out the
# top setup/hold failing paths for every clock, which is the generic
# equivalent of what a script with this name is normally used for. It does
# not change synthesis, fitting, or timing results in any way — it only
# generates extra .rpt files after the standard TimeQuest analysis, so it is
# safe with respect to the actual .rbf that gets produced.

foreach_in_collection clk [get_clocks] {
    catch {
        set clk_name [get_clock_info -name $clk]
        post_message -type info "quartus_report_top_paths.tcl: reporting top paths for clock $clk_name"
        report_timing -setup -npaths 5 -detail full_path -less_than_slack 100000 \
            -clock_name $clk_name -file "top_paths_setup_${clk_name}.rpt" -panel_name "Top Setup Paths - $clk_name"
        report_timing -hold -npaths 5 -detail full_path -less_than_slack 100000 \
            -clock_name $clk_name -file "top_paths_hold_${clk_name}.rpt" -panel_name "Top Hold Paths - $clk_name"
    }
}
