`default_nettype none

module tt_um_lcd_controller_Andres078(
    input  wire [7:0] ui_in,    // Dedicated inputs
    output reg [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       clk,       // clock
    input  wire       rst_n,     // reset_n - low to reset
    input  wire       ena        // unused pin (no utilizar)
);


    wire _unused = &{ena, 1'b0, ui_in, uio_in};  // Signal to handle unused inputs

    wire rst = ~rst_n;  // Active high reset
    
    // Par&aacute;metros de timing (HD44780)
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
    reg [31:0] wait_cnt; // reservado para pausass adicionales

    reg [31:0] delay_cnt;
    reg [3:0]  msg_idx;

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

    reg wait_phase;

    always @(posedge clk or posedge rst_n) begin
        if (rst_n) begin
            // Salidas
            uo_out[0]  <= 1'b0; // rs = 0 al iniciar (comando)
            uo_out[1]  <= 1'b0; // en = 0 al iniciar
            uo_out[7:2] <= 6'b0; // Otros bits no utilizados
            byte_done   <= 1'b0;

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

            // Contadores
            delay_cnt <= 32'd0;
            msg_idx   <= 4'd0;
            step      <= STEP_NONE;
            wait_phase<= 1'b0;

        end else begin
            // Avance de estado
            state <= next_state;

            // Motor de envío
            byte_done <= 1'b0;
            case (bstate)
                B_IDLE: begin
                    uo_out[1] <= 1'b0;  // En está desactivado en B_IDLE
                    if (byte_go) begin
                        uo_out[0] <= byte_is_data;  // rs controlado por el bit 0 de uo_out
                        uo_out[7:2] <= byte_val[7:2];  // Resto de datos
                        en_cnt  <= 32'd0;
                        wait_cnt<= 32'd0;
                        bstate  <= B_SETUPH;
                    end
                end

                B_SETUPH: begin
                    bstate <= B_ENHH;
                    uo_out[1] <= 1'b1;  // Activamos EN
                    en_cnt <= 32'd1;
                end

                B_ENHH: begin
                    if (en_cnt < EN_PULSE_CYC) begin
                        en_cnt <= en_cnt + 32'd1;
                    end else begin
                        uo_out[1] <= 1'b0; // Desactivamos EN
                        en_cnt <= 32'd0;
                        bstate <= B_ENHL;
                    end
                end

                B_ENHL: begin
                    if (en_cnt < EN_PULSE_CYC) begin
                        en_cnt <= en_cnt + 32'd1;
                    end else begin
                        uo_out[7:2] <= byte_val[3:0]; // Actualizamos la salida de datos
                        en_cnt <= 32'd0;
                        bstate <= B_SETUPL;
                    end
                end

                B_SETUPL: begin
                    bstate <= B_ENLH;
                    uo_out[1] <= 1'b1;  // Activamos EN
                    en_cnt <= 32'd1;
                end

                B_ENLH: begin
                    if (en_cnt < EN_PULSE_CYC) begin
                        en_cnt <= en_cnt + 32'd1;
                    end else begin
                        uo_out[1] <= 1'b0; // Desactivamos EN
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
                        byte_go   <= 1'b0;
                    end
                end

                default: bstate <= B_IDLE;
            endcase

            // Lógica de la FSM
            case (state)
                S_IDLE: begin
                    delay_cnt  <= 32'd0;
                    msg_idx    <= 4'd0;
                    step       <= STEP_NONE;
                    wait_phase <= 1'b0;
                    next_state <= S_WAIT_15MS;
                end

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

                // Otros estados siguen igual...

                default: begin
                    next_state <= S_IDLE;
                end
            endcase
        end
    end

    // Asignación de salidas no utilizadas a 0
    assign uio_out = 8'b0;   // IOs: Salida a 0
    assign uio_oe = 8'b0;    // IOs: Enable a 0

endmodule
