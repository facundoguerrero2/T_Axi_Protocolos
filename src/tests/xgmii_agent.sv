`ifndef XGMII_AGENT_SV
`define XGMII_AGENT_SV

`include "interfaces.sv"

//xgmii envia 
class xgmii_driver;
    virtual xgmii_if vif;

    //constructor de la clase xgmii_driver
    function new(virtual xgmii_if vif);
        this.vif = vif;
    endfunction

    //resetamos TXD = Idles y TXC = 0xFF (todo control)
    task reset_bus();
        vif.txd      <= 64'h07070707_07070707;
        vif.txc      <= 8'hFF;
        vif.tx_valid <= 1'b1;
    endtask

    //envia un paquete eth_packet por el bus XGMII
    //recibe un eth_packet que contiene el payload y el tipo de error a inyectar (si corresponde)
    task send_packet(input eth_packet pkt);
        int num_words;
        reg [63:0] word_data;
        
        // --- 1. INICIO DE TRAMA (Con o sin errores inyectados) ---
        @(posedge vif.tx_clk);

        if (pkt.err_type == ERR_NO_START) begin
            // ERROR A PROPOSITO: No mandamos el 0xFB, mandamos preambulo directo como si fuera dato
            vif.txd <= 64'hD5555555_55555555;
            vif.txc <= 8'b0000_0000;
        end 
        else if (pkt.err_type == ERR_BAD_START_LANE) begin
            // ERROR A PROPOSITO: Ponemos el Start (0xFB) en el lane 2 (En 10G solo es legal en lane 0 o 4)
            vif.txd <= 64'hD5555555_55FB0707;
            vif.txc <= 8'b0000_0111;
        end 
        else begin
            // NORMAL: Start (0xFB) en lane 0
            vif.txd <= 64'hD5555555_555555FB; 
            vif.txc <= 8'b0000_0001;
        end

        // --- 2. ENVIO DE PAYLOAD ---
        num_words = pkt.payload.size() / 8;
        for (int w = 0; w < num_words; w++) begin
            @(posedge vif.tx_clk);
            for (int b = 0; b < 8; b++) begin
                word_data[b*8 +: 8] = pkt.payload[w*8 + b];
            end

            // ERROR A PROPOSITO: A mitad del paquete metemos un Terminate (0xFD) donde no va
            if (pkt.err_type == ERR_MID_TERMINATE && w == (num_words/2)) begin
                word_data[7:0] = 8'hFD; // Pisamos el byte 0 con un Terminate
                vif.txd <= word_data;
                vif.txc <= 8'b0000_0001; // Marcamos ese byte como control
            end else begin
                // NORMAL: 64 bits de datos puros
                vif.txd <= word_data;
                vif.txc <= 8'h00;
            end
        end

        // --- 3. FIN DE TRAMA (Terminate) ---
        @(posedge vif.tx_clk);
        if (pkt.err_type == ERR_NO_TERMINATE) begin
            // ERROR A PROPOSITO: Pasamos directo a Idles sin mandar 0xFD
            vif.txd <= 64'h07070707_07070707;
            vif.txc <= 8'hFF;
        end else begin
            // NORMAL: Terminate (0xFD) en lane 0
            vif.txd <= 64'h07070707_070707FD;
            vif.txc <= 8'hFF;
        end

        // Volvemos a mandar Idles
        @(posedge vif.tx_clk);
        reset_bus();
    endtask
endclass

//xgmii receptor y verificador de protocolo IEEE 802.3 (10G)
class xgmii_monitor;
    virtual xgmii_if vif;

    function new(virtual xgmii_if vif);
        this.vif = vif;
    endfunction

    task receive_packet(output eth_packet pkt);
        reg [7:0]   q_bytes [$];
        bit         capturing = 0;
        xgmii_err_t err = ERR_NONE;

        forever begin
            @(posedge vif.rx_clk);
            if (!vif.rx_valid) continue;

            // 1 FUERA DE TRAMA : Esperando Idle o Start (0xFB en lane 0 o 4) 
            if (!capturing) begin
                if (vif.rxc == 8'hFF && vif.rxd == 64'h07070707_07070707) begin
                    continue; // Idles validos (802.3)
                end
                else if (vif.rxc == 8'h01 && vif.rxd == 64'hD5555555_555555FB) begin //chequeamos si el start esta en lane 0 
                    // Start legal en lane 0 + Preambulo (6x 0x55) + SFD (0xD5)
                    capturing = 1;
                    q_bytes.delete();
                end
                else if (vif.rxc == 8'h1F && vif.rxd == 64'h555555FB_07070707) begin //chequeamos si el start esta en lane 4
                    // Start legal en lane 4 (lanes 0..3 Idles, lane 4 0xFB, lanes 5..7 Preambulo)
                    capturing = 1;
                    q_bytes.delete();
                end
                else begin
                    //si llegamos a este punto es porque el Start (0xFB) no esta en lane 0 o 4 (esta mal codificado))
                    err = (vif.rxc == 8'h00) ? ERR_NO_START : ERR_BAD_START_LANE;
                    $display("[%0t ns] [XGMII MON ERROR] Inicio/Idle invalido 802.3: rxd=0x%016h rxc=0x%02h (%s)",
                             $time, vif.rxd, vif.rxc, err.name());
                    capturing = 1;
                    q_bytes.delete();
                end
            end

            // 2. DENTRO DE TRAMA: Capturando datos o verificando Terminate (0xFD) ---
            else begin
                if (vif.rxc == 8'h00) begin
                    // Capturando datos
                    for (int b = 0; b < 8; b++)
                        q_bytes.push_back(vif.rxd[b*8 +: 8]); 
                end
                else begin
                    // Buscamos en que lane esta el Terminate (0xFD)
                    int t = -1;
                    for (int b = 0; b < 8; b++) begin 
                        if (vif.rxc[b] && vif.rxd[b*8 +: 8] == 8'hFD) begin
                            t = b; // Encontramos el lane con Terminate y se lo guardamos en t
                        end
                    end
                    if (t == -1) begin //si no encontramos ningun lane con 0xFD es porque la trama termino sin mandar Terminate (0xFD) (paso directo a Idles o llego 0xFE)
                        err = ERR_NO_TERMINATE;
                        $display("[%0t ns] [XGMII MON ERROR] Fin de trama sin Terminate (0xFD): rxd=0x%016h rxc=0x%02h",
                                 $time, vif.rxd, vif.rxc);
                    end
                    else begin
                        // Segun 802.3  lanes < t son datos (rxc=0), lane t es 0xFD, lanes > t son Idles 0x07 (rxc=1)
                        for (int b = 0; b < t; b++)
                            q_bytes.push_back(vif.rxd[b*8 +: 8]);

                        if (vif.rxc != (8'hFF << t) || (vif.rxd >> ((t+1)*8)) != (64'h07070707_07070707 >> ((t+1)*8))) begin //si no sigue esa regla es porque el Terminate (0xFD) esta mal codificado
                            err = ERR_MID_TERMINATE;
                            $display("[%0t ns] [XGMII MON ERROR] Terminate (0xFD) mal codificado en lane %0d: rxd=0x%016h rxc=0x%02h",
                                     $time, t, vif.rxd, vif.rxc);
                        end
                    end

                    capturing = 0;
                    break;
                end
            end
        end

        pkt = new(q_bytes.size(), err);
        foreach (q_bytes[i]) pkt.payload[i] = q_bytes[i];
    endtask
endclass

//xgmii agent que contiene driver y monitor
class xgmii_agent;
    xgmii_driver  driver;
    xgmii_monitor monitor;

    function new(virtual xgmii_if vif);
        driver  = new(vif);
        monitor = new(vif);
    endfunction
endclass

`endif
