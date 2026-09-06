# Pinout required before Quartus compile

Do not invent pin assignments.

Populate the `.qsf` from the official Terasic DE2-115 reference/pin assignment file
or the board's existing Quartus template. The RTL top-level intentionally exposes
generic board-facing ports; exact Cyclone IV package pin numbers are not included here.
