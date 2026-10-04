`timescale 1ns / 1ps

module twiddle_rom #(
    parameter int N_POINTS      = 256,
    parameter int TWIDDLE_WIDTH = 16,
    parameter     INIT_FILE     = "twiddles_256.mem"
)(
    input  logic                                clk,
    input  logic [$clog2(N_POINTS/2)-1:0]       addr,
    output logic signed [TWIDDLE_WIDTH-1:0]     w_re,
    output logic signed [TWIDDLE_WIDTH-1:0]     w_im
);

    logic [31:0] rom [0:(N_POINTS/2)-1];

    initial begin
        $readmemh(INIT_FILE, rom);
    end

    logic [31:0] dout;

    always_ff @(posedge clk) begin
        dout <= rom[addr];
    end

    assign w_re = dout[31:16];
    assign w_im = dout[15:0];

endmodule