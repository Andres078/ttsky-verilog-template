`default_nettype none
`timescale 1ns / 1ps


module tb;

    // Señales DUT
    reg         clk;
    reg         reset;
    wire        rs;
    wire        en;
    wire [3:0]  data;

    // DUT
    tt_um_lcd_controller_Andres078 dut (
        .clk   (clk),
        .reset (reset),
        .rs    (rs),
        .en    (en),
        .data  (data)
    );

    // Clock 50 MHz (Periodo 20 ns)
    initial clk = 1'b0;
    always #10 clk = ~clk;

    // Reset: activo por 200 ns
    initial begin
        reset = 1'b1;
        #(200);
        reset = 1'b0;
    end

    // Decodificador de bytes desde el bus 4-bit 
    // Capturar el flanco de bajada de EN.
    reg        have_high;
    reg [3:0] high_nib;
    reg        rs_latched;
    reg [7:0] byte;

    // Secuencia esperada:
    //  Init forzada: 0x30,0x30,0x30,0x20
    //  Normal:      0x28,0x08,0x01,0x06,0x0C
    //  Datos:       "HOLA MUNDO" o "THE GAME"
    localparam integer EXP_LEN = 19;
    reg [7:0] expected [0:EXP_LEN-1];
    initial begin
        expected[ 0]=8'h30; expected[ 1]=8'h30; expected[ 2]=8'h30; expected[ 3]=8'h20;
        expected[ 4]=8'h28; expected[ 5]=8'h08; expected[ 6]=8'h01; expected[ 7]=8'h06; expected[ 8]=8'h0C;
        // expected[ 9]="H";   expected[10]="O";   expected[11]="L";   expected[12]="A";   expected[13]=" ";
        // expected[14]="M";   expected[15]="U";   expected[16]="N";   expected[17]="D";   expected[18]="O";
        expected[ 9]="T";   expected[10]="H";   expected[11]="E";   expected[12]=" ";   expected[13]="G";
        expected[14]="A";   expected[15]="M";   expected[16]="E";   expected[17]=" ";   expected[18]=" ";
    end

    integer got_count = 0;
    integer errors    = 0;

    // VCD dump 
    initial begin
        $dumpfile("tb.vcd");
        $dumpvars(0, tb);
        $dumpvars(0, dut);
    end

    // Captura de nibbles y verificación
    always @(negedge en) begin
        if (reset) begin
            have_high  <= 1'b0;
        end else begin
            if (!have_high) begin
                high_nib   <= data;     // nibble alto
                rs_latched <= rs;       // RS para el byte completo
                have_high  <= 1'b1;
            end else begin
                // Completar el byte
                byte = {high_nib, data};
                have_high <= 1'b0;

                // Trazas por consola
                if (rs_latched)
                    $display("[%0t ns] DATA  0x%02h '%s'", $time, byte,
                             (byte>=8'h20 && byte<=8'h7E) ? {byte} : ".");
                else
                    $display("[%0t ns] CMD   0x%02h", $time, byte);

                // Comparar
                if (got_count < EXP_LEN) begin
                    if (byte !== expected[got_count]) begin
                        $display("  -> Mismatch en idx %0d: esperado 0x%02h, got 0x%02h",
                                 got_count, expected[got_count], byte);
                        errors = errors + 1;
                    end
                end else begin
                    $display("  -> Byte extra no esperado: 0x%02h", byte);
                    errors = errors + 1;
                end

                got_count = got_count + 1;

                // Listo, cerrar prueba con pequeño margen
                if (got_count == EXP_LEN) begin
                    $display("[%0t ns] Recibidos todos los %0d bytes esperados.", $time, EXP_LEN);
                    #(100_000); // 100 us extra
                    $display("Resumen: errores=%0d", errors);
                    if (errors==0) $display("TEST PASS");
                    else           $display("TEST FAIL");
                    $finish;
                end
            end
        end
    end

    // Timeout
    initial begin
        #(40_000_000); // 40 ms
        $display("TIMEOUT a %0t ns. Recibidos=%0d / %0d. Errores=%0d", $time, got_count, EXP_LEN, errors);
        $finish;
    end

endmodule
