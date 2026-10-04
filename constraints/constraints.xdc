# Primary 100 MHz clock definition (10 ns period)
create_clock -period 10.000 -name aclk -waveform {0.000 5.000} [get_ports aclk]

# Out-of-Context interface budget (2.0 ns max setup budget, 1.2 ns min hold budget)
set all_inputs [get_ports -filter {DIRECTION == IN && NAME !~ "*aclk*"}]
set_input_delay -clock aclk -max 2.000 $all_inputs
set_input_delay -clock aclk -min 1.200 $all_inputs

set all_outputs [get_ports -filter {DIRECTION == OUT}]
set_output_delay -clock aclk -max 2.000 $all_outputs
set_output_delay -clock aclk -min 0.500 $all_outputs