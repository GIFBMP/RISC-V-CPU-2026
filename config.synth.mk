# Shared project synthesis profile, using the example in upstream 302f0cf.
# These guide ABC mapping only; OpenSTA still uses the course's fixed 5 fF load.
# Override on the command line to compare the upstream defaults:
#   ABC_DRIVING_CELL=INVx1_ASAP7_75t_R ABC_LOAD_FF=5.0
ABC_DRIVING_CELL ?= BUFx2_ASAP7_75t_R
ABC_LOAD_FF ?= 1.0
