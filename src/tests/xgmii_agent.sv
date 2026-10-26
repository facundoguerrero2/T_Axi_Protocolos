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

//xgmii receptor
class xgmii_monitor;
    virtual xgmii_if vif;

    function new(virtual xgmii_if vif);
        this.vif = vif;
    endfunction

    task receive_packet(output eth_packet pkt);
        reg [7:0] q_bytes [$]; //arreglo dinámico para almacenar los bytes capturados
        bit capturing = 0; //bandera para indicar si estamos capturando bytes del paquete

        forever begin
            @(posedge vif.rx_clk);
            if (vif.rx_valid) begin
                if (vif.rxc[0] == 1'b1 && vif.rxd[7:0] == 8'hFB) begin //si encontramos el Start of Frame (0xFB) en lane 0
                    capturing = 1;
                    q_bytes.delete();
                end
                else if (capturing && vif.rxc == 8'h00) begin //si estamos capturando y no hay control, agregamos los bytes al arreglo
                    for (int b = 0; b < 8; b++) begin
                        q_bytes.push_back(vif.rxd[b*8 +: 8]);
                    end
                end
                else if (capturing && vif.rxc != 8'h00) begin //si estamos capturando y encontramos un control, verificamos si es Terminate (0xFD) o Error (0xFE)
                    // Termino la trama (por un 0xFD normal o por un caracter de error 0xFE)
                    capturing = 0;
                    break;
                end
            end
        end

        pkt = new(q_bytes.size()); //creamos un nuevo eth_packet con el tamaño del arreglo dinámico
        foreach (q_bytes[i]) pkt.payload[i] = q_bytes[i]; //para cada byte capturado, lo copiamos al payload del paquete
        //nos queda finalmente el paquete reconstruido en pkt en formato eth_packet 
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
