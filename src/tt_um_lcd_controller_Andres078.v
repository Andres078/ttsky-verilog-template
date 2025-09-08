/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_lcd_controller_Andres078(
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    // Unused signals
    wire _unused = &{ena, ui_in, uio_in, uio_out, uio_oe, rst_n};

    // Map the dedicated outputs to the LCD control signals
    assign uo_out[0] = rs;         // rs pin (0=comando, 1=dato)
    assign uo_out[1] = en;         // en pin (enable)
    assign uo_out[7:4] = data;    // data pins D7..D4 del LCD
    assign uio_oe = 8'b00000000;  // No hay pines de salida adicionales, todos 0

    // Parámetros de timing (HD44780)
    localparam [31:0] CLK_FREQ        = 32'd50_000_000;      // Hz
    localparam [31:0] EN_PULSE_NS     = 32'd500;             // >=450 ns
    localparam [31:0] EN_PULSE_CYC    = (CLK_FREQ * EN_PULSE_NS) / 32'd1_000_000_000 + 32'd1;

    localparam [31:0] DELAY_15MS_CYC  = (CLK_FREQ * 32'd15)   / 32'd1000;      
    localparam [31:0] DELAY_4MS_CYC   = (CLK_FREQ * 32'd4100) / 32'd1_000_000; 
    localparam [31:0] DELAY_100US_CYC = (CLK_FREQ * 32'd100)  / 32'd1_000_000; 
    localparam [31:0] DELAY_40US_CYC  = (CLK_FREQ * 32'd40)   / 32'd1_000_000; 
    localparam [31:0] DELAY_1_6MS_CYC = (CLK_FREQ * 32'd1600) / 32'd1_000_000; 

    // Mensaje 
    localparam integer MSG_LEN   = 10;      // dimension del array
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

    // Estados
    localparam [4:0] 
        S_IDLE       = 5'd0,
        S_WAIT_15MS  = 5'd1,
        S_INIT_1     = 5'd2,
        S_INIT_2     = 5'd3,
        S_INIT_3     = 5'd4,
        S_SET_4BIT   = 5'd5,
        S_FUNC_SET   = 5'd6,
        S_DISP_OFF   = 5'd7,
        S_CLEAR      = 5'd8,
        S_ENTRY      = 5'd9,
        S_DISP_ON    = 5'd10,
        S_WRITE      = 5'd11,
        S_WAIT_BYTE  = 5'd12,
        S_DONE       = 5'd13;

    reg [4:0] state, next_state;

    // Envía un byte en modo 4 bits: nibble alto, pulso EN, pausa; nibble bajo, pulso EN, pausa.
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

    reg [2:0]  bstate;
    reg [31:0] en_cnt;
    reg [31:0] wait_cnt; // reservado para pausas adicionales

    // Contadores generales y auxiliares
    reg [31:0] delay_cnt;
    reg [3:0]  msg_idx;

    // Paso actual para S_WAIT_BYTE
    localparam [3:0]
        STEP_NONE  = 4'd0,
        STEP_INIT1 = 4'd1,
        STEP_INIT2 = 4'd2,
        STEP_INIT3 = 4'd3,
        STEP_SET4  = 4'd4,
        STEP_FSET  = 4'd5,
        STEP_DOFF  = 4'd6,
        STEP_CLEAR = 4'd7,
        STEP_ENTRY = 4'd8,
        STEP_DON   = 4'd9,
        STEP_WRITE = 4'd10;

    reg [3:0] step;

    // Flag de fase de espera en S_WAIT_BYTE
    reg wait_phase;  // 0: esperando byte_done; 1: contando delay

    always @(posedge clk or posedge rst_n) begin
        if (rst_n == 0) begin
            // Salidas
            rs        <= 1'b0;
            en        <= 1'b0;
            data      <= 4'd0;

            // FSM
            state     <= S_IDLE;
            next_state<= S_IDLE;

            // Motor
            bstate    <= B_IDLE;
            en_cnt    <= 32'd0;
            wait_cnt  <= 32'd0;
            byte_go   <= 1'b0;
            byte_is_data <= 1'b0;
            byte_val  <= 8'h00;
            byte_done <= 1'b0;

            // Contadores
            delay_cnt <= 32'd0;
            msg_idx   <= 4'd0;
            step      <= STEP_NONE;
            wait_phase<= 1'b0;

        end else begin
            // Avance de estado
            state <= next_state;

            // Motor de envío
            byte_done <= 1'b0; // pulso de un ciclo al terminar
            case (bstate)
                B_IDLE: begin
                    en <= 1'b0;
                    if (byte_go) begin
                        rs      <= byte_is_data;
                        data    <= byte_val[7:4];
                        en_cnt  <= 32'd0;
                        wait_cnt<= 32'd0;
                        bstate  <= B_SETUPH;
                    end
                end

                B_SETUPH: begin
                    bstate <= B_ENHH;
                    en     <= 1'b1;
                    en_cnt <= 32'd1;
                end

                B_ENHH: begin
                    if (en_cnt < EN_PULSE_CYC) begin
                        en_cnt <= en_cnt + 32'd1;
                    end else begin
                        en     <= 1'b0;
                        en_cnt <= 32'd0;
                        bstate <= B_ENHL;
                    end
                end

                B_ENHL: begin
                    if (en_cnt < EN_PULSE_CYC) begin
                        en_cnt <= en_cnt + 32'd1;
                    end else begin
                        data   <= byte_val[3:0];
                        en_cnt <= 32'd0;
                        bstate <= B_SETUPL;
                    end
                end

                B_SETUPL: begin
                    bstate <= B_ENLH;
                    en     <= 1'b1;
                    en_cnt <= 32'd1;
                end

                B_ENLH: begin
                    if (en_cnt < EN_PULSE_CYC) begin
                        en_cnt <= en_cnt + 32'd1;
                    end else begin
                        en     <= 1'b0;
                        en_cnt <= 32'd0;
                        bstate <= B_ENLL;
                    end
                end

                B_ENLL: begin
                    if (en_cnt < EN_PULSE_CYC) begin
                        en_cnt <= en_cnt + 32'd1;
                    end else begin
                        bstate    <= B_IDLE;
                        byte_done <= 1'b1;
                        byte_go   <= 1'b0; // consumir la orden
                    end
                end

                default: bstate <= B_IDLE;
            endcase

            //  Lógica de la FSM
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
                        // Enviar primer 0x30 (equivale a nibble alto 0x3)
                        byte_is_data <= 1'b0;
                        byte_val     <= 8'h30;
                        byte_go      <= 1'b1;
                        step         <= STEP_INIT1;
                        wait_phase   <= 1'b0;   // primero esperar byte_done
                        next_state   <= S_WAIT_BYTE;
                    end else begin
                        delay_cnt    <= delay_cnt + 32'd1;
                        next_state   <= S_WAIT_15MS;
                    end
                end

                // Estados de init “forzada” (disparo de cada byte y salto a WAIT)
                S_INIT_1: begin
                    next_state <= S_INIT_1; // no usado, flujo va por S_WAIT_BYTE
                end
                S_INIT_2: begin
                    byte_is_data <= 1'b0;
                    byte_val     <= 8'h30;
                    byte_go      <= 1'b1;
                    step         <= STEP_INIT2;
                    delay_cnt    <= 32'd0;
                    wait_phase   <= 1'b0;
                    next_state   <= S_WAIT_BYTE;
                end
                S_INIT_3: begin
                    byte_is_data <= 1'b0;
                    byte_val     <= 8'h30;
                    byte_go      <= 1'b1;
                    step         <= STEP_INIT3;
                    delay_cnt    <= 32'd0;
                    wait_phase   <= 1'b0;
                    next_state   <= S_WAIT_BYTE;
                end
                S_SET_4BIT: begin
                    byte_is_data <= 1'b0;
                    byte_val     <= 8'h20; // 4-bit mode
                    byte_go      <= 1'b1;
                    step         <= STEP_SET4;
                    delay_cnt    <= 32'd0;
                    wait_phase   <= 1'b0;
                    next_state   <= S_WAIT_BYTE;
                end
                S_FUNC_SET: begin
                    byte_is_data <= 1'b0;
                    byte_val     <= 8'h28; // 4-bit, 2 líneas, 5x8
                    byte_go      <= 1'b1;
                    step         <= STEP_FSET;
                    delay_cnt    <= 32'd0;
                    wait_phase   <= 1'b0;
                    next_state   <= S_WAIT_BYTE;
                end
                S_DISP_OFF: begin
                    byte_is_data <= 1'b0;
                    byte_val     <= 8'h08; // display off
                    byte_go      <= 1'b1;
                    step         <= STEP_DOFF;
                    delay_cnt    <= 32'd0;
                    wait_phase   <= 1'b0;
                    next_state   <= S_WAIT_BYTE;
                end
                S_CLEAR: begin
                    byte_is_data <= 1'b0;
                    byte_val     <= 8'h01; // clear
                    byte_go      <= 1'b1;
                    step         <= STEP_CLEAR;
                    delay_cnt    <= 32'd0;
                    wait_phase   <= 1'b0;
                    next_state   <= S_WAIT_BYTE;
                end
                S_ENTRY: begin
                    byte_is_data <= 1'b0;
                    byte_val     <= 8'h06; // entry mode I/D=1, S=0
                    byte_go      <= 1'b1;
                    step         <= STEP_ENTRY;
                    delay_cnt    <= 32'd0;
                    wait_phase   <= 1'b0;
                    next_state   <= S_WAIT_BYTE;
                end
                S_DISP_ON: begin
                    byte_is_data <= 1'b0;
                    byte_val     <= 8'h0C; // display on, cursor off, blink off
                    byte_go      <= 1'b1;
                    step         <= STEP_DON;
                    delay_cnt    <= 32'd0;
                    wait_phase   <= 1'b0;
                    next_state   <= S_WAIT_BYTE;
                end

                // Escritura del mensaje (un byte por vez)
                S_WRITE: begin
                    if (msg_idx < MSG_LEN_4) begin
                        byte_is_data <= 1'b1;
                        byte_val     <= message[msg_idx];
                        byte_go      <= 1'b1;
                        step         <= STEP_WRITE;
                        delay_cnt    <= 32'd0;
                        wait_phase   <= 1'b0;
                        next_state   <= S_WAIT_BYTE;
                    end else begin
                        next_state   <= S_DONE;
                    end
                end

                // Espera a que termine el motor y luego cuenta el delay post-escritura
                S_WAIT_BYTE: begin
                    if (wait_phase == 1'b0) begin
                        // Esperando el pulso byte_done
                        if (byte_done) begin
                            wait_phase <= 1'b1;     // contar el delay
                            delay_cnt  <= 32'd0;
                        end
                        next_state <= S_WAIT_BYTE;
                    end else begin
                        // Contando el delay post-escritura según el paso
                        case (step)
                            STEP_INIT1: begin
                                if (delay_cnt >= DELAY_4MS_CYC) begin
                                    delay_cnt  <= 32'd0;
                                    wait_phase <= 1'b0;
                                    next_state <= S_INIT_2;
                                end else begin
                                    delay_cnt  <= delay_cnt + 32'd1;
                                    next_state <= S_WAIT_BYTE;
                                end
                            end
                            STEP_INIT2: begin
                                if (delay_cnt >= DELAY_100US_CYC) begin
                                    delay_cnt  <= 32'd0;
                                    wait_phase <= 1'b0;
                                    next_state <= S_INIT_3;
                                end else begin
                                    delay_cnt  <= delay_cnt + 32'd1;
                                    next_state <= S_WAIT_BYTE;
                                end
                            end
                            STEP_INIT3: begin
                                if (delay_cnt >= DELAY_100US_CYC) begin
                                    delay_cnt  <= 32'd0;
                                    wait_phase <= 1'b0;
                                    next_state <= S_SET_4BIT;
                                end else begin
                                    delay_cnt  <= delay_cnt + 32'd1;
                                    next_state <= S_WAIT_BYTE;
                                end
                            end
                            STEP_SET4: begin
                                if (delay_cnt >= DELAY_100US_CYC) begin
                                    delay_cnt  <= 32'd0;
                                    wait_phase <= 1'b0;
                                    next_state <= S_FUNC_SET;
                                end else begin
                                    delay_cnt  <= delay_cnt + 32'd1;
                                    next_state <= S_WAIT_BYTE;
                                end
                            end
                            STEP_FSET: begin
                                if (delay_cnt >= DELAY_40US_CYC) begin
                                    delay_cnt  <= 32'd0;
                                    wait_phase <= 1'b0;
                                    next_state <= S_DISP_OFF;
                                end else begin
                                    delay_cnt  <= delay_cnt + 32'd1;
                                    next_state <= S_WAIT_BYTE;
                                end
                            end
                            STEP_DOFF: begin
                                if (delay_cnt >= DELAY_40US_CYC) begin
                                    delay_cnt  <= 32'd0;
                                    wait_phase <= 1'b0;
                                    next_state <= S_CLEAR;
                                end else begin
                                    delay_cnt  <= delay_cnt + 32'd1;
                                    next_state <= S_WAIT_BYTE;
                                end
                            end
                            STEP_CLEAR: begin
                                if (delay_cnt >= DELAY_1_6MS_CYC) begin
                                    delay_cnt  <= 32'd0;
                                    wait_phase <= 1'b0;
                                    next_state <= S_ENTRY;
                                end else begin
                                    delay_cnt  <= delay_cnt + 32'd1;
                                    next_state <= S_WAIT_BYTE;
                                end
                            end
                            STEP_ENTRY: begin
                                if (delay_cnt >= DELAY_40US_CYC) begin
                                    delay_cnt  <= 32'd0;
                                    wait_phase <= 1'b0;
                                    next_state <= S_DISP_ON;
                                end else begin
                                    delay_cnt  <= delay_cnt + 32'd1;
                                    next_state <= S_WAIT_BYTE;
                                end
                            end
                            STEP_DON: begin
                                if (delay_cnt >= DELAY_40US_CYC) begin
                                    delay_cnt  <= 32'd0;
                                    wait_phase <= 1'b0;
                                    msg_idx    <= 4'd0;
                                    next_state <= S_WRITE;
                                end else begin
                                    delay_cnt  <= delay_cnt + 32'd1;
                                    next_state <= S_WAIT_BYTE;
                                end
                            end
                            STEP_WRITE: begin
                                if (delay_cnt >= DELAY_40US_CYC) begin
                                    delay_cnt  <= 32'd0;
                                    wait_phase <= 1'b0;
                                    msg_idx    <= msg_idx + 4'd1;
                                    next_state <= S_WRITE;
                                end else begin
                                    delay_cnt  <= delay_cnt + 32'd1;
                                    next_state <= S_WAIT_BYTE;
                                end
                            end
                            default: begin
                                wait_phase <= 1'b0;
                                next_state <= S_DONE;
                            end
                        endcase
                    end
                end

                S_DONE: begin
                    // Mantener líneas en reposo
                    en        <= 1'b0;
                    rs        <= 1'b0;
                    data      <= 4'd0;
                    next_state<= S_DONE;
                end

                default: begin
                    next_state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
