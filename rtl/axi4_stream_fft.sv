`timescale 1ns / 1ps

module axi4_stream_fft #(
    parameter int N_POINTS      = 256,
    parameter int DATA_WIDTH    = 16,
    parameter int TWIDDLE_WIDTH = 16,
    parameter     TWIDDLE_FILE  = "twiddles_256.mem"
)(
    input  logic                          aclk,
    input  logic                          aresetn,

    // AXI4-Stream Slave (Input)
    input  logic [31:0]                   s_axis_tdata,
    input  logic                          s_axis_tvalid,
    output logic                          s_axis_tready,
    input  logic                          s_axis_tlast,

    // AXI4-Stream Master (Output)
    output logic [31:0]                   m_axis_tdata,
    output logic                          m_axis_tvalid,
    input  logic                          m_axis_tready,
    output logic                          m_axis_tlast
);

    localparam int ADDR_W = $clog2(N_POINTS);

    logic                          core_start;
    logic                          core_busy;
    logic                          core_done;
    logic                          core_load_en;
    logic signed [DATA_WIDTH-1:0]  core_load_re;
    logic signed [DATA_WIDTH-1:0]  core_load_im;
    logic                          core_unload_en;
    logic signed [DATA_WIDTH-1:0]  core_unload_re;
    logic signed [DATA_WIDTH-1:0]  core_unload_im;
    logic                          core_unload_valid;
    logic                          core_ready_to_unload;

    typedef enum logic [2:0] {
        ST_AXI_IDLE_WAIT = 3'd0,
        ST_AXI_PULSE     = 3'd1,
        ST_AXI_INGEST    = 3'd2,
        ST_AXI_COMPUTE   = 3'd3,
        ST_AXI_EMIT      = 3'd4
    } axi_state_t;

    axi_state_t state;
    logic [ADDR_W:0] ingest_cnt;
    logic [ADDR_W:0] emit_cnt;

    // Registered AXI Stream Output Stage
    logic [31:0] m_data_reg;
    logic        m_valid_reg;
    logic        m_last_reg;
    logic        s_ready_reg;

    fft_core #(
        .N_POINTS(N_POINTS),
        .DATA_WIDTH(DATA_WIDTH),
        .TWIDDLE_WIDTH(TWIDDLE_WIDTH),
        .TWIDDLE_FILE(TWIDDLE_FILE)
    ) u_core (
        .clk(aclk),
        .rst_n(aresetn),
        .start(core_start),
        .busy(core_busy),
        .done(core_done),
        .load_en(core_load_en),
        .load_re(core_load_re),
        .load_im(core_load_im),
        .unload_en(core_unload_en),
        .unload_re(core_unload_re),
        .unload_im(core_unload_im),
        .unload_valid(core_unload_valid),
        .ready_to_unload(core_ready_to_unload)
    );

    // Ingestion
    assign s_axis_tready = s_ready_reg;
    assign core_load_en  = (state == ST_AXI_INGEST) && s_axis_tvalid && s_ready_reg;
    assign core_load_re  = s_axis_tdata[31:16];
    assign core_load_im  = s_axis_tdata[15:0];

    // Core unload enabled when emitting and downstream can accept or register is empty
    assign core_unload_en = (state == ST_AXI_EMIT) && (m_axis_tready || !m_valid_reg);

    // Master Output Registers
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            m_valid_reg <= 1'b0;
            m_data_reg  <= '0;
            m_last_reg  <= 1'b0;
        end else begin
            if (m_axis_tready || !m_valid_reg) begin
                m_valid_reg <= core_unload_valid;
                m_data_reg  <= {core_unload_re, core_unload_im};
                m_last_reg  <= (emit_cnt == N_POINTS - 1) && core_unload_valid;
            end
        end
    end

    assign m_axis_tvalid = m_valid_reg;
    assign m_axis_tdata  = m_data_reg;
    assign m_axis_tlast  = m_last_reg;

    // FSM and Registered Ready Control
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state       <= ST_AXI_IDLE_WAIT;
            core_start  <= 1'b0;
            ingest_cnt  <= '0;
            emit_cnt    <= '0;
            s_ready_reg <= 1'b0;
        end else begin
            case (state)
                ST_AXI_IDLE_WAIT: begin
                    s_ready_reg <= 1'b0;
                    if (!core_busy) begin
                        core_start <= 1'b1;
                        state      <= ST_AXI_PULSE;
                    end
                end

                ST_AXI_PULSE: begin
                    core_start  <= 1'b0;
                    ingest_cnt  <= '0;
                    emit_cnt    <= '0;
                    s_ready_reg <= 1'b1; // Arm ready ahead of ingestion
                    state       <= ST_AXI_INGEST;
                end

                ST_AXI_INGEST: begin
                    if (s_axis_tvalid && s_ready_reg) begin
                        ingest_cnt <= ingest_cnt + 1;
                        if (ingest_cnt == N_POINTS - 1) begin
                            s_ready_reg <= 1'b0; // Deassert ready as buffer is full
                            state       <= ST_AXI_COMPUTE;
                        end
                    end
                end

                ST_AXI_COMPUTE: begin
                    s_ready_reg <= 1'b0;
                    if (core_ready_to_unload) begin
                        state <= ST_AXI_EMIT;
                    end
                end

                ST_AXI_EMIT: begin
                    s_ready_reg <= 1'b0;
                    if (core_unload_valid && (m_axis_tready || !m_valid_reg)) begin
                        emit_cnt <= emit_cnt + 1;
                        if (emit_cnt == N_POINTS - 1) begin
                            state <= ST_AXI_IDLE_WAIT;
                        end
                    end
                end

                default: begin
                    state       <= ST_AXI_IDLE_WAIT;
                    s_ready_reg <= 1'b0;
                end
            endcase
        end
    end

endmodule