`timescale 1ns / 1ps

module tb_fft_core;

    localparam int N_POINTS    = 256;
    localparam int DATA_WIDTH  = 16;
    localparam real CLK_PERIOD = 10.0;

    logic                          clk;
    logic                          rst_n;
    logic                          start;
    logic                          busy;
    logic                          done;
    logic                          load_en;
    logic signed [DATA_WIDTH-1:0]  load_re, load_im;
    logic                          unload_en;
    logic signed [DATA_WIDTH-1:0]  unload_re, unload_im;
    logic                          unload_valid;
    logic                          ready_to_unload;

    fft_core #(
        .N_POINTS(N_POINTS),
        .DATA_WIDTH(DATA_WIDTH),
        .TWIDDLE_WIDTH(16),
        .TWIDDLE_FILE("twiddles_256.mem")
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(busy),
        .done(done),
        .load_en(load_en),
        .load_re(load_re),
        .load_im(load_im),
        .unload_en(unload_en),
        .unload_re(unload_re),
        .unload_im(unload_im),
        .unload_valid(unload_valid),
        .ready_to_unload(ready_to_unload)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    logic [31:0] stim_mem [0:N_POINTS-1];
    logic [31:0] gold_mem [0:N_POINTS-1];
    logic [31:0] hw_out   [0:N_POINTS-1];

    task automatic run_test_vector(input string stim_file, input string gold_file, input string test_name);
        int errors = 0;
        int out_cnt = 0;

        $readmemh(stim_file, stim_mem);
        $readmemh(gold_file, gold_mem);

        // 1. Wait until core is fully IDLE
        wait (!busy);
        @(posedge clk);
        unload_en <= 1'b0;

        // 2. Pulse Start
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        // 3. Feed Stimulus
        for (int i = 0; i < N_POINTS; i++) begin
            load_en <= 1'b1;
            load_re <= stim_mem[i][31:16];
            load_im <= stim_mem[i][15:0];
            @(posedge clk);
        end
        load_en <= 1'b0;

        // 4. Wait until calculation completes (ready_to_unload goes high)
        wait (ready_to_unload);
        @(posedge clk);

        // 5. Stream out 256 samples
        while (out_cnt < N_POINTS) begin
            unload_en <= 1'b1;
            @(posedge clk);
            if (unload_valid) begin
                hw_out[out_cnt] = {unload_re, unload_im};
                out_cnt++;
            end
        end
        unload_en <= 1'b0;

        // 6. Wait for core to finish ST_DONE and return to IDLE
        wait (done || !busy);
        repeat(5) @(posedge clk);

        // 7. Verify bit-exact
        for (int i = 0; i < N_POINTS; i++) begin
            logic signed [15:0] exp_r = gold_mem[i][31:16];
            logic signed [15:0] exp_i = gold_mem[i][15:0];
            logic signed [15:0] act_r = hw_out[i][31:16];
            logic signed [15:0] act_i = hw_out[i][15:0];

            if (act_r !== exp_r || act_i !== exp_i) begin
                if (errors < 5) begin
                    $display("[MISMATCH] %s Bin %0d: Expected (%0d, %0d), Got (%0d, %0d)",
                             test_name, i, exp_r, exp_i, act_r, act_i);
                end
                errors++;
            end
        end

        if (errors == 0)
            $display("[PASS] %s matches golden reference bit-for-bit.", test_name);
        else
            $display("[FAIL] %s had %0d mismatches out of %0d.", test_name, errors, N_POINTS);
    endtask

    initial begin
        rst_n     = 1'b0;
        start     = 1'b0;
        load_en   = 1'b0;
        unload_en = 1'b0;
        load_re   = '0;
        load_im   = '0;

        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(10) @(posedge clk);

        $display("----------------------------------------------------------------");
        $display("Running FFT Core Bit-Exact Verification...");
        $display("----------------------------------------------------------------");

        run_test_vector("stim_impulse.mem", "gold_impulse.mem", "Impulse Test");
        run_test_vector("stim_dc.mem", "gold_dc.mem", "DC Test");
        run_test_vector("stim_single_tone.mem", "gold_single_tone.mem", "Single Tone Test");

        $display("----------------------------------------------------------------");
        $finish;
    end

endmodule