/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_lcd_controller_Andres078(
    input  wire [7:0] ui_in,    // Dedicated inputs (no usados)
    output reg  [7:0] uo_out,   // [0]=RS, [1]=EN, [5:2]=DATA, [7:6]=0
    input  wire [7:0] uio_in,   // IOs: Input path (no usados)
    output wire [7:0] uio_out,  // IOs: Output path (no usados -> 0)
    output wire [7:0] uio_oe,   // IOs: Enable path (0=input, 1=output) (no usados -> 0)
    input  wire       clk,      // clock
    input  wire       rst_n,    // reset_n - activo en bajo
    input  wire       ena       // no usado
);

    // Entradas no usadas (clk y rst_n sí se usan)
    wire _unused = &{ena, ui_in, uio_in, 1'b0};

    // ------------------ Parámetros de timing (HD44780) ------------------
    localparam [31:0] CLK_FREQ        = 32'd50_000_000;      // Hz
    localparam [31:0] EN_PULSE_NS     = 32'd500;             // >=450 ns
    localparam [31:0] EN_PULSE_CYC    = (CLK_FREQ * EN_PULSE_NS) / 32'd1_000_000_000 + 32'd1;

    localparam [31:0] DELAY_15MS_CYC  = (CLK_FREQ * 32'd15)   / 32'd1000;      
    localparam [31:0] DELAY_4MS_CYC   = (CLK_FREQ * 32'd4100) / 32'd1_000_000; 
    localparam [31:0] DELAY_100US_CYC = (CLK_FREQ * 32'd100)  / 32'd1_000_000; 
    localparam [31:0] DELAY_40US_CYC  = (CLK_FREQ * 32'd40)   / 32'd1_000_000; 
    localparam [31:0] DELAY_1_6MS_CYC = (CLK_FREQ * 32'd1600) / 32'd1_000_000; 

    localparam [31:0] SETUP_NS   = 32'd100;  // setup RS/DATA antes de EN
    localparam [31:0] SETUP_CYC  = (CLK_FREQ * SETUP_NS) / 32'd1_000_000_000 + 32'd1;
    // ------------------ Mensaje fijo ------------------
    localparam integer MSG_LEN   = 10;
    localparam [3:0]   MSG_LEN_4 = 4'd10;

    reg [7:0] message [0:MSG_LEN-1];
    initial begin
        message[0] = "T";
        message[1] = "H";
        message[2] = "E";
        message[3] = " ";
        message[4] = "G";
        message[5] = "A";
        message[6] = "M";
        message[7] = "E";
        message[8] = " ";
        message[9] = " ";
    end

    // ------------------ Estados ------------------
    localparam [4:0] 
        S_IDLE        = 5'd0,
        S_WAIT_15MS   = 5'd1,
        S_INIT_1      = 5'd2,
        S_INIT_2      = 5'd3,
        S_INIT_3      = 5'd4,
        S_SET_4BIT    = 5'd5,
        S_FUNC_SET    = 5'd6,
        S_DISP_OFF    = 5'd7,
        S_CLEAR       = 5'd8,
        S_ENTRY       = 5'd9,
        S_DISP_ON     = 5'd10,
        S_SET_DDRAM0  = 5'd11,   
        S_WRITE       = 5'd12,
        S_WAIT_BYTE   = 5'd13,
        S_DONE        = 5'd14;

    reg [4:0] state, next_state;

    // ------------------ Motor de envío (4 bits) ------------------
    reg        byte_go;
    reg        byte_is_data;   // 1=dato (RS=1), 0=comando (RS=0)
    reg [7:0]  byte_val;
    reg        byte_done;

    localparam [2:0]
        B_IDLE   = 3'd0,
        B_SETUPH = 3'd1,
        B_ENHH   = 3'd2,
        B_ENHL   = 3'd3,
        B_SETUPL = 3'd4,
        B_ENLH   = 3'd5,
        B_ENLL   = 3'd6;

    reg [31:0] setup_cnt;
    
    reg [2:0]  bstate;
    reg [31:0] en_cnt;

    // Contadores y auxiliares
    reg [31:0] delay_cnt;
    reg [3:0]  msg_idx;

    localparam [3:0]
        STEP_NONE    = 4'd0,
        STEP_INIT1   = 4'd1,
        STEP_INIT2   = 4'd2,
        STEP_INIT3   = 4'd3,
        STEP_SET4    = 4'd4,
        STEP_FSET    = 4'd5,
        STEP_DOFF    = 4'd6,
        STEP_CLEAR   = 4'd7,
        STEP_ENTRY   = 4'd8,
        STEP_DON     = 4'd9,
        STEP_DDRAM0  = 4'd10,   // << añadido
        STEP_WRITE   = 4'd11;

    reg [3:0] step;
    reg       wait_phase;  // 0: esperando byte_done; 1: delay post-escritura

    // ------------------ IOs no usados ------------------
    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;

    // ------------------ Reset asíncrono activo-bajo ------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uo_out      <= 8'h00; // RS=0, EN=0, DATA=0, [7:6]=0
            byte_done   <= 1'b0;

            state       <= S_IDLE;
            next_state  <= S_IDLE;

            bstate      <= B_IDLE;
            en_cnt      <= 32'd0;
            byte_go     <= 1'b0;
            byte_is_data<= 1'b0;
            byte_val    <= 8'h00;

            delay_cnt   <= 32'd0;
            msg_idx     <= 4'd0;
            step        <= STEP_NONE;
            wait_phase  <= 1'b0;

        end else begin
            state <= next_state;

            // ---------------- Motor de envío ----------------
            byte_done <= 1'b0; // pulso de 1 ciclo
            case (bstate)
                B_IDLE: begin
                    uo_out[1] <= 1'b0;                // EN=0
                    if (byte_go) begin
                    uo_out[0]   <= byte_is_data;    // RS
                    uo_out[5:2] <= byte_val[7:4];   // nibble alto
                    uo_out[7:6] <= 2'b00;
                    setup_cnt   <= 32'd0;
                    en_cnt      <= 32'd0;
                    bstate      <= B_SETUPH;
                    end
                end

                // Espera de setup antes del primer pulso EN
                B_SETUPH: begin
                    if (setup_cnt < SETUP_CYC) setup_cnt <= setup_cnt + 32'd1;
                    else begin
                    uo_out[1] <= 1'b1;              // EN=1
                    en_cnt    <= 32'd1;
                    bstate    <= B_ENHH;
                    end
                end

                B_ENHH: begin
                    if (en_cnt < EN_PULSE_CYC) en_cnt <= en_cnt + 32'd1;
                    else begin
                    uo_out[1] <= 1'b0;              // EN=0
                    en_cnt    <= 32'd0;
                    bstate    <= B_ENHL;
                    end
                end

                B_ENHL: begin
                    if (en_cnt < EN_PULSE_CYC) en_cnt <= en_cnt + 32'd1;
                    else begin
                    uo_out[5:2] <= byte_val[3:0];   // nibble bajo
                    uo_out[7:6] <= 2'b00;
                    setup_cnt   <= 32'd0;
                    en_cnt      <= 32'd0;
                    bstate      <= B_SETUPL;
                    end
                end

                // Espera de setup antes del segundo pulso EN
                B_SETUPL: begin
                    if (setup_cnt < SETUP_CYC) setup_cnt <= setup_cnt + 32'd1;
                    else begin
                    uo_out[1] <= 1'b1;              // EN=1
                    en_cnt    <= 32'd1;
                    bstate    <= B_ENLH;
                    end
                end

                B_ENLH: begin
                    if (en_cnt < EN_PULSE_CYC) en_cnt <= en_cnt + 32'd1;
                    else begin
                    uo_out[1] <= 1'b0;              // EN=0
                    en_cnt    <= 32'd0;
                    bstate    <= B_ENLL;
                    end
                end

                B_ENLL: begin
                    if (en_cnt < EN_PULSE_CYC) en_cnt <= en_cnt + 32'd1;
                    else begin
                    bstate    <= B_IDLE;
                    byte_done <= 1'b1;
                    byte_go   <= 1'b0;
                    end
                end
                default: bstate <= B_IDLE;
            endcase

            // ---------------- FSM principal ----------------
            case (state)
                S_IDLE: begin
                    delay_cnt  <= 32'd0;
                    msg_idx    <= 4'd0;
                    step       <= STEP_NONE;
                    wait_phase <= 1'b0;
                    next_state <= S_WAIT_15MS;
                end

                // Espera inicial >15 ms
                S_WAIT_15MS: begin
                    if (delay_cnt >= DELAY_15MS_CYC) begin
                        delay_cnt    <= 32'd0;
                        byte_is_data <= 1'b0;
                        byte_val     <= 8'h30;
                        byte_go      <= 1'b1;
                        step         <= STEP_INIT1;
                        wait_phase   <= 1'b0;
                        next_state   <= S_WAIT_BYTE;
                    end else begin
                        delay_cnt    <= delay_cnt + 32'd1;
                        next_state   <= S_WAIT_15MS;
                    end
                end

                // Flujo real pasa por S_WAIT_BYTE
                S_INIT_1: begin next_state <= S_INIT_1; end
                S_INIT_2: begin
                    byte_is_data <= 1'b0; byte_val <= 8'h30; byte_go <= 1'b1;
                    step <= STEP_INIT2; delay_cnt <= 0; wait_phase <= 1'b0;
                    next_state <= S_WAIT_BYTE;
                end
                S_INIT_3: begin
                    byte_is_data <= 1'b0; byte_val <= 8'h30; byte_go <= 1'b1;
                    step <= STEP_INIT3; delay_cnt <= 0; wait_phase <= 1'b0;
                    next_state <= S_WAIT_BYTE;
                end
                S_SET_4BIT: begin
                    byte_is_data <= 1'b0; byte_val <= 8'h20; byte_go <= 1'b1;
                    step <= STEP_SET4; delay_cnt <= 0; wait_phase <= 1'b0;
                    next_state <= S_WAIT_BYTE;
                end
                S_FUNC_SET: begin
                    byte_is_data <= 1'b0; byte_val <= 8'h28; byte_go <= 1'b1;
                    step <= STEP_FSET; delay_cnt <= 0; wait_phase <= 1'b0;
                    next_state <= S_WAIT_BYTE;
                end
                S_DISP_OFF: begin
                    byte_is_data <= 1'b0; byte_val <= 8'h08; byte_go <= 1'b1;
                    step <= STEP_DOFF; delay_cnt <= 0; wait_phase <= 1'b0;
                    next_state <= S_WAIT_BYTE;
                end
                S_CLEAR: begin
                    byte_is_data <= 1'b0; byte_val <= 8'h01; byte_go <= 1'b1;
                    step <= STEP_CLEAR; delay_cnt <= 0; wait_phase <= 1'b0;
                    next_state <= S_WAIT_BYTE;
                end
                S_ENTRY: begin
                    byte_is_data <= 1'b0; byte_val <= 8'h06; byte_go <= 1'b1;
                    step <= STEP_ENTRY; delay_cnt <= 0; wait_phase <= 1'b0;
                    next_state <= S_WAIT_BYTE;
                end
                S_DISP_ON: begin
                    byte_is_data <= 1'b0; byte_val <= 8'h0C; byte_go <= 1'b1;
                    step <= STEP_DON; delay_cnt <= 0; wait_phase <= 1'b0;
                    next_state <= S_WAIT_BYTE;
                end
                S_SET_DDRAM0: begin
                    byte_is_data <= 1'b0; byte_val <= 8'h80; byte_go <= 1'b1; // DDRAM=0x00
                    step <= STEP_DDRAM0; delay_cnt <= 0; wait_phase <= 1'b0;
                    next_state <= S_WAIT_BYTE;
                end
                S_WRITE: begin
                    if (msg_idx < MSG_LEN_4) begin
                        byte_is_data <= 1'b1; byte_val <= message[msg_idx]; byte_go <= 1'b1;
                        step <= STEP_WRITE; delay_cnt <= 0; wait_phase <= 1'b0;
                        next_state <= S_WAIT_BYTE;
                    end else begin
                        next_state <= S_DONE;
                    end
                end

                // Espera a byte_done y aplica delays
                S_WAIT_BYTE: begin
                    if (!wait_phase) begin
                        if (byte_done) begin
                            wait_phase <= 1'b1;
                            delay_cnt  <= 32'd0;
                        end
                        next_state <= S_WAIT_BYTE;
                    end else begin
                        case (step)
                            STEP_INIT1  : if (delay_cnt >= DELAY_4MS_CYC)   begin delay_cnt<=0; wait_phase<=0; next_state<=S_INIT_2;   end else begin delay_cnt<=delay_cnt+1; next_state<=S_WAIT_BYTE; end
                            STEP_INIT2  : if (delay_cnt >= DELAY_100US_CYC) begin delay_cnt<=0; wait_phase<=0; next_state<=S_INIT_3;   end else begin delay_cnt<=delay_cnt+1; next_state<=S_WAIT_BYTE; end
                            STEP_INIT3  : if (delay_cnt >= DELAY_100US_CYC) begin delay_cnt<=0; wait_phase<=0; next_state<=S_SET_4BIT; end else begin delay_cnt<=delay_cnt+1; next_state<=S_WAIT_BYTE; end
                            STEP_SET4   : if (delay_cnt >= DELAY_100US_CYC) begin delay_cnt<=0; wait_phase<=0; next_state<=S_FUNC_SET; end else begin delay_cnt<=delay_cnt+1; next_state<=S_WAIT_BYTE; end
                            STEP_FSET   : if (delay_cnt >= DELAY_40US_CYC)  begin delay_cnt<=0; wait_phase<=0; next_state<=S_DISP_OFF; end else begin delay_cnt<=delay_cnt+1; next_state<=S_WAIT_BYTE; end
                            STEP_DOFF   : if (delay_cnt >= DELAY_40US_CYC)  begin delay_cnt<=0; wait_phase<=0; next_state<=S_CLEAR;    end else begin delay_cnt<=delay_cnt+1; next_state<=S_WAIT_BYTE; end
                            STEP_CLEAR  : if (delay_cnt >= DELAY_1_6MS_CYC) begin delay_cnt<=0; wait_phase<=0; next_state<=S_ENTRY;    end else begin delay_cnt<=delay_cnt+1; next_state<=S_WAIT_BYTE; end
                            STEP_ENTRY  : if (delay_cnt >= DELAY_40US_CYC)  begin delay_cnt<=0; wait_phase<=0; next_state<=S_DISP_ON;  end else begin delay_cnt<=delay_cnt+1; next_state<=S_WAIT_BYTE; end
                            STEP_DON    : if (delay_cnt >= DELAY_40US_CYC)  begin delay_cnt<=0; wait_phase<=0; next_state<=S_SET_DDRAM0; end else begin delay_cnt<=delay_cnt+1; next_state<=S_WAIT_BYTE; end
                            STEP_DDRAM0 : if (delay_cnt >= DELAY_40US_CYC)  begin delay_cnt<=0; wait_phase<=0; msg_idx<=0; next_state<=S_WRITE; end else begin delay_cnt<=delay_cnt+1; next_state<=S_WAIT_BYTE; end
                            STEP_WRITE  : if (delay_cnt >= DELAY_40US_CYC)  begin delay_cnt<=0; wait_phase<=0; msg_idx<=msg_idx+1; next_state<=S_WRITE; end else begin delay_cnt<=delay_cnt+1; next_state<=S_WAIT_BYTE; end
                            default     : begin wait_phase<=1'b0; next_state<=S_DONE; end
                        endcase
                    end
                end

                S_DONE: begin
                    // Reposo: EN=0, RS=0, DATA=0, [7:6]=0
                    uo_out[1]   <= 1'b0;
                    uo_out[0]   <= 1'b0;
                    uo_out[5:2] <= 4'd0;
                    uo_out[7:6] <= 2'b00;
                    next_state  <= S_DONE;
                end

                default: next_state <= S_IDLE;
            endcase
        end
    end

endmodule
