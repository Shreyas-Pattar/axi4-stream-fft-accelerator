`timescale 1ns / 1ps

module tb_butterfly;

    localparam int DATA_WIDTH    = 16;
    localparam int TWIDDLE_WIDTH = 16;
    localparam real CLK_PERIOD   = 10.0;

    logic                          clk;
    logic                          rst_n;
    logic                          valid_in;
    logic signed [DATA_WIDTH-1:0]  a_re_in, a_im_in;
    logic signed [DATA_WIDTH-1:0]  b_re_in, b_im_in;
    logic signed [TWIDDLE_WIDTH-1:0] w_re_in, w_im_in;

    logic                          valid_out;
    logic signed [DATA_WIDTH-1:0]  u_re_out, u_im_out;
    logic signed [DATA_WIDTH-1:0]  l_re_out, l_im_out;

    butterfly #(
        .DATA_WIDTH(DATA_WIDTH),
        .TWIDDLE_WIDTH(TWIDDLE_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .a_re_in(a_re_in),
        .a_im_in(a_im_in),
        .b_re_in(b_re_in),
        .b_im_in(b_im_in),
        .w_re_in(w_re_in),
        .w_im_in(w_im_in),
        .valid_out(valid_out),
        .u_re_out(u_re_out),
        .u_im_out(u_im_out),
        .l_re_out(l_re_out),
        .l_im_out(l_im_out)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    int errors = 0;

    task automatic check_butterfly(
        input logic signed [15:0] a_r, a_i,
        input logic signed [15:0] b_r, b_i,
        input logic signed [15:0] w_r, w_i,
        input logic signed [15:0] exp_u_r, exp_u_i,
        input logic signed [15:0] exp_l_r, exp_l_i,
        input string test_name
    );
        @(posedge clk);
        valid_in <= 1'b1;
        a_re_in  <= a_r; a_im_in  <= a_i;
        b_re_in  <= b_r; b_im_in  <= b_i;
        w_re_in  <= w_r; w_im_in  <= w_i;

        @(posedge clk);
        valid_in <= 1'b0;

        repeat(2) @(posedge clk);
        @(negedge clk);

        if (!valid_out) begin
            $error("[FAIL] %s: valid_out not asserted on cycle 3", test_name);
            errors++;
        end else if (u_re_out !== exp_u_r || u_im_out !== exp_u_i ||
                     l_re_out !== exp_l_r || l_im_out !== exp_l_i) begin
            $error("[FAIL] %s: Mismatch!", test_name);
            $display("   Expected: U=(%0d, %0d), L=(%0d, %0d)", exp_u_r, exp_u_i, exp_l_r, exp_l_i);
            $display("   Actual:   U=(%0d, %0d), L=(%0d, %0d)", u_re_out, u_im_out, l_re_out, l_im_out);
            errors++;
        end else begin
            $display("[PASS] %s: U=(%0d, %0d) L=(%0d, %0d)", test_name, u_re_out, u_im_out, l_re_out, l_im_out);
        end
    endtask

    initial begin
        rst_n    = 1'b0;
        valid_in = 1'b0;
        a_re_in  = '0; a_im_in  = '0;
        b_re_in  = '0; b_im_in  = '0;
        w_re_in  = '0; w_im_in  = '0;

        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        $display("----------------------------------------------------------------");
        $display("Starting Butterfly Unit Bit-Exact Verification...");
        $display("----------------------------------------------------------------");

        // Test 1: W = (32767, 0). 4000 * 32767 >> 15 = 3999.
        // U = (10000 + 3999) >> 1 = 6999
        // L = (10000 - 3999) >> 1 = 3000
        check_butterfly(16'sd10000, 16'sd0, 16'sd4000, 16'sd0, 16'sd32767, 16'sd0,
                        16'sd6999,  16'sd0, 16'sd3000, 16'sd0, "Test 1: Identity Twiddle (Truncated)");

        // Test 2: W = (0, -32767).
        check_butterfly(16'sd0, 16'sd4000, 16'sd2000, 16'sd0, 16'sd0, -16'sd32767,
                        16'sd0, 16'sd1000, 16'sd0, 16'sd3000, "Test 2: Pure -90 Deg Rotation");

        // Test 3: Cancellation. 5000 * 32767 >> 15 = 4999.
        // U = (5000 + 4999) >> 1 = 4999
        // L = (5000 - 4999) >> 1 = 0
        check_butterfly(16'sd5000, 16'sd5000, 16'sd5000, 16'sd5000, 16'sd32767, 16'sd0,
                        16'sd4999, 16'sd4999, 16'sd0, 16'sd0, "Test 3: Equal Vectors (Truncated)");

        $display("----------------------------------------------------------------");
        if (errors == 0)
            $display("[ALL TESTS PASSED] Butterfly pipeline latency and arithmetic verified.");
        else
            $display("[TEST FAILED] Total errors: %0d", errors);
        $display("----------------------------------------------------------------");

        $finish;
    end

endmodule