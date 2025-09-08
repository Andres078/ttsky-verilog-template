`default_nettype none
`timescale 1ns / 1ps


`timescale 1ns / 1ps

module tb;

    // Señales DUT
    reg [7:0] ui_in;    // Entradas dedicadas
    wire [7:0] uo_out;  // Salidas dedicadas
    reg [7:0] uio_in;   // IOs: Entrada
    wire [7:0] uio_out; // IOs: Salida
    wire [7:0] uio_oe;  // IOs: Enable (activo alto: 0=entrada, 1=salida)
    reg clk;             // Clock
    reg rst_n;           // Reset

    reg ena;

    `ifdef GL_TEST
    wire VPWR = 1'b1;
    wire VGND = 1'b0;
    `endif
    // DUT
    tt_um_lcd_controller_Andres078 dut (
        `ifdef GL_TEST
        .VPWR(VPWR),
        .VGND(VGND),
        `endif

        .ena    (ena),
        
        .ui_in   (ui_in),
        .uo_out  (uo_out),
        .uio_in  (uio_in),
        .uio_out (uio_out),
        .uio_oe  (uio_oe),
        .clk     (clk),
        .rst_n   (rst_n)
    );

    // Clock 50 MHz (Periodo 20 ns)
    initial clk = 1'b0;
    always #10 clk = ~clk;

    // Reset: activo por 200 ns
    initial begin
        rst_n = 1'b1;
        #(200);
        rst_n = 1'b0;
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
    always @(negedge uio_oe) begin  // En vez de 'en', se utiliza 'uio_oe'
        if (rst_n) begin
            have_high  <= 1'b0;
        end else begin
            if (!have_high) begin
                high_nib   <= uo_out;     // nibble alto
                rs_latched <= uio_out[0]; // RS para el byte completo (considera uio_out como RS)
                have_high  <= 1'b1;
            end else begin
                // Completar el byte
                byte = {high_nib, uo_out};
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

