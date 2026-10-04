`timescale 1ns / 1ps

module fft_core #(
    parameter int N_POINTS      = 256,
    parameter int DATA_WIDTH    = 16,
    parameter int TWIDDLE_WIDTH = 16,
    parameter     TWIDDLE_FILE  = "twiddles_256.mem"
)(
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic                          start,
    output logic                          busy,
    output logic                          done,

    input  logic                          load_en,
    input  logic signed [DATA_WIDTH-1:0]  load_re,
    input  logic signed [DATA_WIDTH-1:0]  load_im,

    input  logic                          unload_en,
    output logic signed [DATA_WIDTH-1:0]  unload_re,
    output logic signed [DATA_WIDTH-1:0]  unload_im,
    output logic                          unload_valid,
    output logic                          ready_to_unload
);

    localparam int ADDR_W = $clog2(N_POINTS);
    localparam int STAGES = $clog2(N_POINTS);

    // Working Dual-Port BRAM
    logic [2*DATA_WIDTH-1:0] mem [0:N_POINTS-1];
    logic                    wea, web;
    logic [ADDR_W-1:0]       addra, addrb;
    logic [2*DATA_WIDTH-1:0] dina, dinb;
    logic [2*DATA_WIDTH-1:0] douta, doutb;

    always_ff @(posedge clk) begin
        if (wea) mem[addra] <= dina;
        douta <= mem[addra];
    end

    always_ff @(posedge clk) begin
        if (web) mem[addrb] <= dinb;
        doutb <= mem[addrb];
    end

    function automatic [ADDR_W-1:0] bit_rev(input [ADDR_W-1:0] in_addr);
        for (int i = 0; i < ADDR_W; i++) begin
            bit_rev[i] = in_addr[ADDR_W - 1 - i];
        end
    endfunction

    typedef enum logic [2:0] {
        ST_IDLE     = 3'd0,
        ST_LOAD     = 3'd1,
        ST_BF_READ  = 3'd2,
        ST_BF_LATCH = 3'd3,
        ST_BF_WAIT  = 3'd4,
        ST_BF_WRITE = 3'd5,
        ST_UNLOAD   = 3'd6,
        ST_DONE     = 3'd7
    } state_t;

    state_t state, state_next;

    logic [ADDR_W-1:0] load_cnt;
    logic [ADDR_W-1:0] unload_cnt;
    logic [ADDR_W:0]   unload_words_sent;
    logic [3:0]        stage;
    logic [ADDR_W-1:0] bf_idx;
    logic [1:0]        wait_cnt;

    // Butterfly connections
    logic                            bf_valid_in;
    logic signed [DATA_WIDTH-1:0]    bf_a_re, bf_a_im;
    logic signed [DATA_WIDTH-1:0]    bf_b_re, bf_b_im;
    logic signed [TWIDDLE_WIDTH-1:0] bf_w_re, bf_w_im;
    logic                            bf_valid_out;
    logic signed [DATA_WIDTH-1:0]    bf_u_re, bf_u_im;
    logic signed [DATA_WIDTH-1:0]    bf_l_re, bf_l_im;

    // Twiddle ROM
    logic [ADDR_W-2:0]               tw_addr;
    logic signed [TWIDDLE_WIDTH-1:0] rom_w_re, rom_w_im;

    twiddle_rom #(
        .N_POINTS(N_POINTS),
        .TWIDDLE_WIDTH(TWIDDLE_WIDTH),
        .INIT_FILE(TWIDDLE_FILE)
    ) u_twiddle_rom (
        .clk(clk),
        .addr(tw_addr),
        .w_re(rom_w_re),
        .w_im(rom_w_im)
    );

    butterfly #(
        .DATA_WIDTH(DATA_WIDTH),
        .TWIDDLE_WIDTH(TWIDDLE_WIDTH)
    ) u_butterfly (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(bf_valid_in),
        .a_re_in(bf_a_re),
        .a_im_in(bf_a_im),
        .b_re_in(bf_b_re),
        .b_im_in(bf_b_im),
        .w_re_in(bf_w_re),
        .w_im_in(bf_w_im),
        .valid_out(bf_valid_out),
        .u_re_out(bf_u_re),
        .u_im_out(bf_u_im),
        .l_re_out(bf_l_re),
        .l_im_out(bf_l_im)
    );

    // DIT Address Calculations
    logic [ADDR_W-1:0] span;
    assign span = 1 << stage;

    logic [ADDR_W-1:0] group;
    logic [ADDR_W-1:0] pair;
    logic [ADDR_W-1:0] cur_u, cur_l;

    assign group   = (bf_idx >> stage) << (stage + 1);
    assign pair    = bf_idx & (span - 1);
    assign cur_u   = group + pair;
    assign cur_l   = cur_u + span;
    assign tw_addr = pair << (STAGES - 1 - stage);

    // Pipeline registers for writeback addresses & twiddles
    logic [ADDR_W-1:0]               save_addr_u, save_addr_l;
    logic signed [TWIDDLE_WIDTH-1:0] latched_w_re, latched_w_im;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            save_addr_u  <= '0;
            save_addr_l  <= '0;
            latched_w_re <= '0;
            latched_w_im <= '0;
        end else begin
            if (state == ST_BF_READ) begin
                save_addr_u <= cur_u;
                save_addr_l <= cur_l;
            end
            if (state == ST_BF_READ) begin
                latched_w_re <= rom_w_re;
                latched_w_im <= rom_w_im;
            end
        end
    end

    // Butterfly inputs active during ST_BF_LATCH
    assign bf_valid_in = (state == ST_BF_LATCH);
    assign bf_a_re     = douta[31:16];
    assign bf_a_im     = douta[15:0];
    assign bf_b_re     = doutb[31:16];
    assign bf_b_im     = doutb[15:0];
    assign bf_w_re     = rom_w_re;
    assign bf_w_im     = rom_w_im;

    // FSM Control
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            load_cnt          <= '0;
            unload_cnt        <= '0;
            unload_words_sent <= '0;
            stage             <= '0;
            bf_idx            <= '0;
            wait_cnt          <= '0;
        end else begin
            state <= state_next;

            case (state)
                ST_IDLE: begin
                    load_cnt          <= '0;
                    unload_cnt        <= '0;
                    unload_words_sent <= '0;
                    stage             <= '0;
                    bf_idx            <= '0;
                    wait_cnt          <= '0;
                end

                ST_LOAD: begin
                    if (load_en) load_cnt <= load_cnt + 1;
                end

                ST_BF_READ: begin
                    wait_cnt <= '0;
                end

                ST_BF_LATCH: begin
                    wait_cnt <= '0;
                end

                ST_BF_WAIT: begin
                    wait_cnt <= wait_cnt + 1;
                end

                ST_BF_WRITE: begin
                    if (bf_idx == (N_POINTS/2) - 1) begin
                        bf_idx <= '0;
                        if (stage == STAGES - 1) begin
                            stage <= '0;
                        end else begin
                            stage <= stage + 1;
                        end
                    end else begin
                        bf_idx <= bf_idx + 1;
                    end
                end

                ST_UNLOAD: begin
                    if (unload_en && (unload_cnt < N_POINTS - 1)) begin
                        unload_cnt <= unload_cnt + 1;
                    end
                    if (unload_valid) begin
                        unload_words_sent <= unload_words_sent + 1;
                    end
                end

                ST_DONE: begin
                    unload_cnt        <= '0;
                    unload_words_sent <= '0;
                    load_cnt          <= '0;
                end
            endcase
        end
    end

    always_comb begin
        state_next = state;
        case (state)
            ST_IDLE: begin
                if (start) state_next = ST_LOAD;
            end
            ST_LOAD: begin
                if (load_en && (load_cnt == N_POINTS - 1))
                    state_next = ST_BF_READ;
            end
            ST_BF_READ: begin
                state_next = ST_BF_LATCH;
            end
            ST_BF_LATCH: begin
                state_next = ST_BF_WAIT;
            end
            ST_BF_WAIT: begin
                if (wait_cnt == 2'd1)
                    state_next = ST_BF_WRITE;
            end
            ST_BF_WRITE: begin
                if ((bf_idx == (N_POINTS/2) - 1) && (stage == STAGES - 1))
                    state_next = ST_UNLOAD;
                else
                    state_next = ST_BF_READ;
            end
            ST_UNLOAD: begin
                if (unload_words_sent >= N_POINTS)
                    state_next = ST_DONE;
            end
            ST_DONE: begin
                state_next = ST_IDLE;
            end
            default: state_next = ST_IDLE;
        endcase
    end

    // Memory Addressing
    always_comb begin
        wea   = 1'b0;
        web   = 1'b0;
        addra = '0;
        addrb = '0;
        dina  = '0;
        dinb  = '0;

        case (state)
            ST_LOAD: begin
                wea   = load_en;
                addra = bit_rev(load_cnt);
                dina  = {load_re, load_im};
            end

            ST_BF_READ, ST_BF_LATCH: begin
                addra = cur_u;
                addrb = cur_l;
            end

            ST_BF_WRITE: begin
                wea   = 1'b1;
                web   = 1'b1;
                addra = save_addr_u;
                addrb = save_addr_l;
                dina  = {bf_u_re, bf_u_im};
                dinb  = {bf_l_re, bf_l_im};
            end

            ST_UNLOAD: begin
                addra = unload_cnt;
            end

            default: ;
        endcase
    end

    assign busy            = (state != ST_IDLE);
    assign done            = (state == ST_DONE);
    assign ready_to_unload = (state == ST_UNLOAD);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            unload_valid <= 1'b0;
        end else begin
            unload_valid <= (state == ST_UNLOAD) && unload_en && (unload_words_sent < N_POINTS);
        end
    end

    assign unload_re = douta[31:16];
    assign unload_im = douta[15:0];

endmodule