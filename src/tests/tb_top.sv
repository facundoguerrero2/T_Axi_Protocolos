`timescale 1ns / 1ps
`default_nettype wire

// =========================================================================
//  MODO DE PRUEBA:
// - Descomentar la siguiente linea para probar SOLO los agentes (Loopback directo).
// - Comentarla para probar el DUT real (taxi_eth_phy_10g).
// =========================================================================

 //`define loopback_btw_agents

`include "interfaces.sv"
`include "prbs31.sv"
`include "xgmii_agent.sv"

module tb_top;

    // 1. Reloj (156.25 MHz -> periodo de 6.4ns) y Reset
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #3.2 clk = ~clk;

    // 2. Instancia de la interfaz XGMII
    xgmii_if vif(
        .tx_clk(clk), .tx_rst(rst),
        .rx_clk(clk), .rx_rst(rst)
    );

    // Señales para inyectar Sync Headers invalidos en SERDES RX (Tests 4 y 5)
    reg        force_rx_hdr_en  = 1'b0;
    reg  [1:0] force_rx_hdr_val = 2'b00;

    // =====================================================================
    // CONEXION DEL HARDWARE (Segun si esta definido loopback_btw_agents o no)
    // =====================================================================
`ifdef loopback_btw_agents

    // --- MODO A: LOOPBACK DIRECTO ENTRE AGENTES (Sin DUT) ---
    assign vif.rxd            = vif.txd;
    assign vif.rxc            = vif.txc;
    assign vif.rx_valid       = vif.tx_valid;
    
    // Forzamos estatus como si el enlace estuviera listo
    assign vif.rx_block_lock  = ~rst;
    assign vif.tx_bad_block   = 1'b0;
    assign vif.rx_bad_block   = 1'b0;
    assign vif.rx_error_count = 7'd0;

`else

    // --- MODO B: CONECTADO AL DUT REAL (Con Loopback en SERDES) ---
    wire [63:0] serdes_data_loop;
    wire        serdes_data_valid_loop;
    wire [1:0]  serdes_hdr_loop;
    wire        serdes_hdr_valid_loop;
    wire        serdes_gbx_sync_loop;

    // Mux para interceptar serdes_rx_hdr e inyectar headers 00 o 11
    wire [1:0]  serdes_rx_hdr_in = force_rx_hdr_en ? force_rx_hdr_val : serdes_hdr_loop;

    taxi_eth_phy_10g #(
        .DATA_W(64),
        .CTRL_W(8),
        .HDR_W(2),
        .PRBS31_EN(1'b0) // En 0 para que procese tramas XGMII normales
    ) dut (
        .rx_clk                 (vif.rx_clk),
        .rx_rst                 (vif.rx_rst),
        .tx_clk                 (vif.tx_clk),
        .tx_rst                 (vif.tx_rst),

        // Interfaz XGMII conectada a nuestro vif
        .xgmii_txd              (vif.txd),
        .xgmii_txc              (vif.txc),
        .xgmii_tx_valid         (vif.tx_valid),
        .xgmii_rxd              (vif.rxd),
        .xgmii_rxc              (vif.rxc),
        .xgmii_rx_valid         (vif.rx_valid),
        .tx_gbx_req_sync        (),
        .tx_gbx_req_stall       (),
        .tx_gbx_sync            (1'b0),
        .rx_gbx_sync            (),

        // Interfaz SERDES en Loopback (TX -> RX)
        .serdes_tx_data         (serdes_data_loop),
        .serdes_tx_data_valid   (serdes_data_valid_loop),
        .serdes_tx_hdr          (serdes_hdr_loop),
        .serdes_tx_hdr_valid    (serdes_hdr_valid_loop),
        .serdes_tx_gbx_req_sync (1'b0),
        .serdes_tx_gbx_req_stall(1'b0),
        .serdes_tx_gbx_sync     (serdes_gbx_sync_loop),

        .serdes_rx_data         (serdes_data_loop),
        .serdes_rx_data_valid   (serdes_data_valid_loop),
        .serdes_rx_hdr          (serdes_rx_hdr_in),
        .serdes_rx_hdr_valid    (serdes_hdr_valid_loop),
        .serdes_rx_gbx_sync     (serdes_gbx_sync_loop),
        .serdes_rx_bitslip      (),
        .serdes_rx_reset_req    (),

        // Señales de Estatus conectadas a nuestro vif
        .tx_bad_block           (vif.tx_bad_block),
        .rx_error_count         (vif.rx_error_count),
        .rx_bad_block           (vif.rx_bad_block),
        .rx_sequence_error      (),
        .rx_block_lock          (vif.rx_block_lock),
        .rx_high_ber            (),
        .rx_status              (),

        // Configuracion
        .cfg_tx_prbs31_enable   (1'b0),
        .cfg_rx_prbs31_enable   (1'b0)
    );

`endif

    // =====================================================================
    // SECUENCIA DE TESTS 
    // =====================================================================
    xgmii_agent      agent;
    prbs31_generator prbs_gen;
    prbs31_checker   prbs_chk;

    initial begin
        eth_packet tx_pkt, rx_pkt;

        // Instanciamos objetos
        // lock_th = 64 bits buenos para pasar a ST_LOCK
        // unlock_th = 8 bits malos para caer a ST_UNLOCK
        agent    = new(vif);
        prbs_gen = new(31'h7FFFFFFF);
        prbs_chk = new(.lock_th(64), .unlock_th(8));

        $display("\n==========================================================");
        `ifdef loopback_btw_agents
            $display(" INICIANDO SIMULACION: MODO LOOPBACK ENTRE AGENTES (SIN DUT)");
        `else
            $display(" INICIANDO SIMULACION: MODO TESTEO DE DUT (taxi_eth_phy_10g)");
        `endif
        $display("==========================================================\n");

        // 1. Inicializacion y Reset
        agent.driver.reset_bus();
        repeat(10) @(posedge clk);
        rst = 1'b0;
        $display("[%0t ns] Reset liberado. Esperando rx_block_lock...", $time);

        // Esperamos que el receptor logre Block Lock (64 headers validos en el DUT)
        wait(vif.rx_block_lock === 1'b1);
        repeat(10) @(posedge clk);
        $display("[%0t ns] rx_block_lock = 1! Enlace listo.\n", $time);


        // =====================================================================
        // TEST 1: HAPPY PATH (Sin errores - El Checker debe pasar a ST_LOCK)
        // =====================================================================
        $display("----------------------------------------------------------");
        $display(" TEST 1: HAPPY PATH (3 paquetes de 64 bytes con PRBS31 sano)");
        $display("----------------------------------------------------------");
        for (int p = 1; p <= 3; p++) begin
            $display("\n--- Enviando Paquete Sano #%0d ---", p);
            fork
                begin
                    prbs_gen.create_packet(64, tx_pkt, ERR_NONE);
                    agent.driver.send_packet(tx_pkt);
                end
                begin
                    agent.monitor.receive_packet(rx_pkt);
                    prbs_chk.check_packet(rx_pkt);
                end
            join
            repeat(5) @(posedge clk);
        end


        // =====================================================================
        // TEST 2: CORROMPER BYTES A PROPOSITO (Checker debe caer a ST_UNLOCK)
        // =====================================================================
        $display("\n----------------------------------------------------------");
        $display(" TEST 2: CORROMPER PAYLOAD PRBS (Forzar vuelta a ST_UNLOCK)");
        $display("----------------------------------------------------------");
        fork
            begin
                prbs_gen.create_packet(64, tx_pkt, ERR_NONE);
                // Invertimos dos bytes completos (16 bits de error > unlock_th de 8)
                tx_pkt.payload[10] = ~tx_pkt.payload[10];
                tx_pkt.payload[11] = ~tx_pkt.payload[11];
                $display("[%0t ns] [TB] Inyectando errores de bit en bytes 10 y 11...", $time);
                agent.driver.send_packet(tx_pkt);
            end
            begin
                agent.monitor.receive_packet(rx_pkt);
                prbs_chk.check_packet(rx_pkt);
            end
        join
        repeat(10) @(posedge clk);


        // =====================================================================
        // TEST 3: ERROR DE PROTOCOLO XGMII (Start 0xFB en carril ilegal)
        // =====================================================================
        $display("\n----------------------------------------------------------");
        $display(" TEST 3: ERROR DE PROTOCOLO XGMII (Start en carril ilegal)");
        $display("----------------------------------------------------------");
        begin
            bit vio_tx_bad_block = 0;
            bit vio_rx_bad_block = 0;
            bit [6:0] err_cnt_antes = vif.rx_error_count;

            prbs_gen.create_packet(64, tx_pkt, ERR_BAD_START_LANE);

            // Lanzamos el envio y en paralelo el monitor XGMII + vigilancia del DUT
            fork
                begin
                    $display("[%0t ns] [TB] Enviando trama con Start (0xFB) en lane 2...", $time);
                    agent.driver.send_packet(tx_pkt);
                    repeat(25) @(posedge clk); // Damos tiempo a que cruce la tuberia
                end
                begin
                    agent.monitor.receive_packet(rx_pkt);
                end
                begin
                    // Vigilamos durante 40 ciclos si el DUT levanta las banderas de error
                    repeat(40) begin
                        @(posedge clk);
                        if (vif.tx_bad_block) vio_tx_bad_block = 1;
                        if (vif.rx_bad_block) vio_rx_bad_block = 1;
                    end
                end
            join

            $display("[RESULTADO TEST 3 - MONITOR XGMII]:");
            $display("  -> Error detectado por monitor : %s", rx_pkt.err_type.name());
            if (rx_pkt.err_type != ERR_NONE)
                $display("  => [TEST 3 MONITOR OK] El monitor XGMII detecto el error de protocolo 802.3!");
            else
                $display("  => [TEST 3 MONITOR ERROR] El monitor XGMII NO detecto el error.");

            `ifndef loopback_btw_agents
                $display("[RESULTADO TEST 3 - ESTATUS DEL DUT]:");
                $display("  -> tx_bad_block detectado : %b (Esperado: 1)", vio_tx_bad_block);
                $display("  -> rx_bad_block detectado : %b", vio_rx_bad_block);
                $display("  -> rx_error_count         : Antes=%0d | Ahora=%0d", err_cnt_antes, vif.rx_error_count);
                
                if (vio_tx_bad_block || vio_rx_bad_block || (vif.rx_error_count > err_cnt_antes))
                    $display("  => [TEST 3 DUT OK] El DUT detecto correctamente el error de protocolo XGMII!");
                else
                    $display("  => [TEST 3 DUT ERROR] El DUT NO reporto el bloque invalido.");
            `endif
        end


        `ifndef loopback_btw_agents
        // =====================================================================
        // TEST 4: PERDIDA DE BLOCK LOCK (>16 Sync Headers invalidos en 64 bloques)
        // =====================================================================
        $display("\n----------------------------------------------------------");
        $display(" TEST 4: MAQUINA DE ESTADOS BLOCK SYNC (>16 headers invalidos)");
        $display("----------------------------------------------------------");
        begin
            bit cayo_block_lock = 0;
            bit vio_datos_validos = 0;

            $display("[%0t ns] [TB] Inyectando 40 Sync Headers invalidos (2'b00)...", $time);
            @(posedge clk);
            force_rx_hdr_en  <= 1'b1;
            force_rx_hdr_val <= 2'b00;

            repeat(40) begin
                @(posedge clk);
                if (!vif.rx_block_lock) cayo_block_lock = 1;
                if (vif.rxc == 8'h00)   vio_datos_validos = 1; // No deben salir datos por XGMII
            end

            force_rx_hdr_en <= 1'b0;
            $display("  -> rx_block_lock cayo a 0 : %b (Esperado: 1)", cayo_block_lock);
            $display("  -> Datos XGMII recibidos  : %b (Esperado: 0)", vio_datos_validos);

            if (cayo_block_lock && !vio_datos_validos)
                $display("  => [TEST 4 OK] El DUT perdio sincronismo (rx_block_lock=0) y bloqueo datos!");
            else
                $display("  => [TEST 4 ERROR] Fallo en maquina de estados de sincronizacion.");

            // Recuperamos el Block Lock (64 headers validos) antes de pasar al Test 5
            wait(vif.rx_block_lock === 1'b1);
            repeat(5) @(posedge clk);
            $display("[%0t ns] [TB] Enlace re-sincronizado (rx_block_lock = 1).", $time);
        end


        // =====================================================================
        // TEST 5: DECODIFICACION DE SYNC HEADERS INVALIDOS (2'b00 y 2'b11)
        // =====================================================================
        $display("\n----------------------------------------------------------");
        $display(" TEST 5: DECODIFICACION SYNC HEADERS INVALIDOS (00 y 11)");
        $display("----------------------------------------------------------");
        begin
            bit ok_hdr_00 = 0;
            bit ok_hdr_11 = 0;

            // 1) Inyectar header 2'b00 por 1 ciclo
            $display("[%0t ns] [TB] Inyectando Sync Header 2'b00...", $time);
            @(posedge clk);
            force_rx_hdr_en  <= 1'b1;
            force_rx_hdr_val <= 2'b00;
            @(posedge clk);
            force_rx_hdr_en  <= 1'b0;

            repeat(5) begin
                @(posedge clk);
                if (vif.rx_bad_block && vif.rxd == 64'hFEFEFEFE_FEFEFEFE && vif.rxc == 8'hFF)
                    ok_hdr_00 = 1;
            end

            // 2) Inyectar header 2'b11 por 1 ciclo
            $display("[%0t ns] [TB] Inyectando Sync Header 2'b11...", $time);
            @(posedge clk);
            force_rx_hdr_en  <= 1'b1;
            force_rx_hdr_val <= 2'b11;
            @(posedge clk);
            force_rx_hdr_en  <= 1'b0;

            repeat(5) begin
                @(posedge clk);
                if (vif.rx_bad_block && vif.rxd == 64'hFEFEFEFE_FEFEFEFE && vif.rxc == 8'hFF)
                    ok_hdr_11 = 1;
            end

            $display("  -> Header 2'b00 (rx_bad_block=1 y rxd=8x0xFE) : %b", ok_hdr_00);
            $display("  -> Header 2'b11 (rx_bad_block=1 y rxd=8x0xFE) : %b", ok_hdr_11);

            if (ok_hdr_00 && ok_hdr_11)
                $display("  => [TEST 5 OK] El decodificador RX rechazo 00 y 11 emitiendo 0xFE y rx_bad_block=1!");
            else
                $display("  => [TEST 5 ERROR] Fallo en deteccion de Sync Headers invalidos.");
        end
        `endif

        repeat(20) @(posedge clk);
        $display("\n==========================================================");
        $display(" FIN DE LA SIMULACION");
        $display("==========================================================\n");
        $finish;
    end

endmodule
