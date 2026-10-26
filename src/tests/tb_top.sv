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
        .serdes_rx_hdr          (serdes_hdr_loop),
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

            // Lanzamos el envio y en paralelo vigilamos los flags de error del DUT
            fork
                begin
                    $display("[%0t ns] [TB] Enviando trama con Start (0xFB) en lane 2...", $time);
                    agent.driver.send_packet(tx_pkt);
                    repeat(25) @(posedge clk); // Damos tiempo a que cruce la tuberia del DUT
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

            `ifdef loopback_btw_agents
                $display("[RESULTADO TEST 3] En modo loopback_btw_agents no hay DUT que verifique protocolo.");
            `else
                $display("[RESULTADO TEST 3 - ESTATUS DEL DUT]:");
                $display("  -> tx_bad_block detectado : %b (Esperado: 1)", vio_tx_bad_block);
                $display("  -> rx_bad_block detectado : %b", vio_rx_bad_block);
                $display("  -> rx_error_count         : Antes=%0d | Ahora=%0d", err_cnt_antes, vif.rx_error_count);
                
                if (vio_tx_bad_block || vio_rx_bad_block || (vif.rx_error_count > err_cnt_antes))
                    $display("  => [TEST 3 OK] El DUT detecto correctamente el error de protocolo XGMII!");
                else
                    $display("  => [TEST 3 ERROR] El DUT NO reporto el bloque invalido.");
            `endif
        end

        repeat(20) @(posedge clk);
        $display("\n==========================================================");
        $display(" FIN DE LA SIMULACION");
        $display("==========================================================\n");
        $finish;
    end

endmodule
