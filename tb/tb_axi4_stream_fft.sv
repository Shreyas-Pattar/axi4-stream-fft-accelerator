`timescale 1ns / 1ps

module tb_axi4_stream_fft;

    localparam int N_POINTS    = 256;
    localparam real CLK_PERIOD = 10.0;

    logic        aclk;
    logic        aresetn;

    logic [31:0] s_axis_tdata;
    logic        s_axis_tvalid;
    logic        s_axis_tready;
    logic        s_axis_tlast;

    logic [31:0] m_axis_tdata;
    logic        m_axis_tvalid;
    logic        m_axis_tready;
    logic        m_axis_tlast;

    axi4_stream_fft #(
        .N_POINTS(N_POINTS),
        .DATA_WIDTH(16),
        .TWIDDLE_WIDTH(16),
        .TWIDDLE_FILE("twiddles_256.mem")
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast)
    );

    initial begin
        aclk = 1'b0;
        forever #(CLK_PERIOD / 2.0) aclk = ~aclk;
    end

    // Watchdog to kill simulation if hardware hangs
    initial begin
        #1000000; // 1000 us maximum
        $display("[ERROR] Watchdog timer expired! Simulation hung.");
        $finish;
    end

    logic [31:0] stim_mem [0:N_POINTS-1];
    logic [31:0] gold_mem [0:N_POINTS-1];
    logic [31:0] hw_out   [0:N_POINTS-1];

    task automatic run_stream_test(input string stim_file, input string gold_file, input string name);
        int errors = 0;
        int out_cnt = 0;

        $readmemh(stim_file, stim_mem);
        $readmemh(gold_file, gold_mem);

        // Feed AXI4-Stream
        for (int i = 0; i < N_POINTS; i++) begin
            @(posedge aclk);
            while (!s_axis_tready) @(posedge aclk);
            s_axis_tvalid <= 1'b1;
            s_axis_tdata  <= stim_mem[i];
            s_axis_tlast  <= (i == N_POINTS - 1);
        end
        @(posedge aclk);
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;

        // Drain AXI4-Stream
        m_axis_tready <= 1'b1;
        while (out_cnt < N_POINTS) begin
            @(posedge aclk);
            if (m_axis_tvalid) begin
                hw_out[out_cnt] = m_axis_tdata;
                out_cnt++;
            end
        end
        m_axis_tready <= 1'b0;

        // Verify Output
        for (int i = 0; i < N_POINTS; i++) begin
            logic signed [15:0] exp_r = gold_mem[i][31:16];
            logic signed [15:0] exp_i = gold_mem[i][15:0];
            logic signed [15:0] act_r = hw_out[i][31:16];
            logic signed [15:0] act_i = hw_out[i][15:0];

            if (act_r !== exp_r || act_i !== exp_i) begin
                if (errors < 5)
                    $display("[STREAM MISMATCH] %s Bin %0d: Exp (%0d, %0d), Got (%0d, %0d)", name, i, exp_r, exp_i, act_r, act_i);
                errors++;
            end
        end

        if (errors == 0)
            $display("[AXI-STREAM PASS] %s streamed bit-exact with valid/ready handshake.", name);
        else
            $display("[AXI-STREAM FAIL] %s had %0d mismatches.", name, errors);
    endtask

    initial begin
        aresetn       = 1'b0;
        s_axis_tdata  = '0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        m_axis_tready = 1'b0;

        repeat(10) @(posedge aclk);
        aresetn = 1'b1;
        repeat(10) @(posedge aclk);

        $display("----------------------------------------------------------------");
        $display("Running Full AXI4-Stream FFT Accelerator Verification...");
        $display("----------------------------------------------------------------");

        run_stream_test("stim_impulse.mem", "gold_impulse.mem", "Impulse Vector");
        repeat(10) @(posedge aclk);

        run_stream_test("stim_dc.mem", "gold_dc.mem", "DC Vector");
        repeat(10) @(posedge aclk);

        run_stream_test("stim_single_tone.mem", "gold_single_tone.mem", "Single Tone Vector");

        $display("----------------------------------------------------------------");
        $finish;
    end

endmodule