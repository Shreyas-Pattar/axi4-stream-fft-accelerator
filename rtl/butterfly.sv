`timescale 1ns / 1ps

module butterfly #(
    parameter int DATA_WIDTH    = 16,
    parameter int TWIDDLE_WIDTH = 16
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          valid_in,

    input  logic signed [DATA_WIDTH-1:0]    a_re_in,
    input  logic signed [DATA_WIDTH-1:0]    a_im_in,

    input  logic signed [DATA_WIDTH-1:0]    b_re_in,
    input  logic signed [DATA_WIDTH-1:0]    b_im_in,

    input  logic signed [TWIDDLE_WIDTH-1:0] w_re_in,
    input  logic signed [TWIDDLE_WIDTH-1:0] w_im_in,

    output logic                          valid_out,

    output logic signed [DATA_WIDTH-1:0]    u_re_out,
    output logic signed [DATA_WIDTH-1:0]    u_im_out,

    output logic signed [DATA_WIDTH-1:0]    l_re_out,
    output logic signed [DATA_WIDTH-1:0]    l_im_out
);

    // Pipeline Stage 1: Input Registration
    logic signed [DATA_WIDTH-1:0]    a_re_pipe1, a_im_pipe1;
    logic signed [DATA_WIDTH-1:0]    b_re_pipe1, b_im_pipe1;
    logic signed [TWIDDLE_WIDTH-1:0] w_re_pipe1, w_im_pipe1;
    logic                            valid_pipe1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe1 <= 1'b0;
            a_re_pipe1  <= '0;
            a_im_pipe1  <= '0;
            b_re_pipe1  <= '0;
            b_im_pipe1  <= '0;
            w_re_pipe1  <= '0;
            w_im_pipe1  <= '0;
        end else begin
            valid_pipe1 <= valid_in;
            a_re_pipe1  <= a_re_in;
            a_im_pipe1  <= a_im_in;
            b_re_pipe1  <= b_re_in;
            b_im_pipe1  <= b_im_in;
            w_re_pipe1  <= w_re_in;
            w_im_pipe1  <= w_im_in;
        end
    end

    // Pipeline Stage 2: Complex Multiplication (B * W)
    localparam int PROD_WIDTH = DATA_WIDTH + TWIDDLE_WIDTH;

    (* use_dsp = "yes" *) logic signed [PROD_WIDTH-1:0] prod_rr;
    (* use_dsp = "yes" *) logic signed [PROD_WIDTH-1:0] prod_ii;
    (* use_dsp = "yes" *) logic signed [PROD_WIDTH-1:0] prod_ri;
    (* use_dsp = "yes" *) logic signed [PROD_WIDTH-1:0] prod_ir;

    assign prod_rr = b_re_pipe1 * w_re_pipe1;
    assign prod_ii = b_im_pipe1 * w_im_pipe1;
    assign prod_ri = b_re_pipe1 * w_im_pipe1;
    assign prod_ir = b_im_pipe1 * w_re_pipe1;

    logic signed [DATA_WIDTH-1:0] a_re_pipe2, a_im_pipe2;
    logic signed [DATA_WIDTH-1:0] bw_re_pipe2, bw_im_pipe2;
    logic                         valid_pipe2;

    function automatic logic signed [DATA_WIDTH-1:0] saturate16(input logic signed [DATA_WIDTH:0] val);
        if (val > 17'sd32767)
            return 16'sd32767;
        else if (val < -17'sd32768)
            return -16'sd32768;
        else
            return val[DATA_WIDTH-1:0];
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe2 <= 1'b0;
            a_re_pipe2  <= '0;
            a_im_pipe2  <= '0;
            bw_re_pipe2 <= '0;
            bw_im_pipe2 <= '0;
        end else begin
            valid_pipe2 <= valid_pipe1;
            a_re_pipe2  <= a_re_pipe1;
            a_im_pipe2  <= a_im_pipe1;
            bw_re_pipe2 <= saturate16((prod_rr >>> 15) - (prod_ii >>> 15));
            bw_im_pipe2 <= saturate16((prod_ri >>> 15) + (prod_ir >>> 15));
        end
    end

    // Pipeline Stage 3: 17-bit Extended Add/Sub with Divide-by-2
    logic signed [DATA_WIDTH:0] sum_re, sum_im;
    logic signed [DATA_WIDTH:0] diff_re, diff_im;

    assign sum_re  = {a_re_pipe2[DATA_WIDTH-1], a_re_pipe2} + {bw_re_pipe2[DATA_WIDTH-1], bw_re_pipe2};
    assign sum_im  = {a_im_pipe2[DATA_WIDTH-1], a_im_pipe2} + {bw_im_pipe2[DATA_WIDTH-1], bw_im_pipe2};
    assign diff_re = {a_re_pipe2[DATA_WIDTH-1], a_re_pipe2} - {bw_re_pipe2[DATA_WIDTH-1], bw_re_pipe2};
    assign diff_im = {a_im_pipe2[DATA_WIDTH-1], a_im_pipe2} - {bw_im_pipe2[DATA_WIDTH-1], bw_im_pipe2};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            u_re_out  <= '0;
            u_im_out  <= '0;
            l_re_out  <= '0;
            l_im_out  <= '0;
        end else begin
            valid_out <= valid_pipe2;
            u_re_out  <= sum_re >>> 1;
            u_im_out  <= sum_im >>> 1;
            l_re_out  <= diff_re >>> 1;
            l_im_out  <= diff_im >>> 1;
        end
    end

endmodule