`ifndef PRBS31_SV
`define PRBS31_SV

`include "interfaces.sv"

// --- GENERADOR PRBS31 ---

#define SEED 31'h7FFFFFFF

class prbs31_generator;
    reg [30:0] state;

    function new(reg [30:0] seed = SEED);
        this.state = (seed == 0) ? SEED : seed;
    endfunction

    //generamos prbs31 segun estandard
    task automatic get_next_prbs31;
        input      [30:0] state_in;
        output reg [30:0] lfsr_out;
        output reg        out_bit;
        reg feedback;
        begin
            feedback = state_in[30] ^ state_in[27];
            out_bit  = ~feedback;
            lfsr_out = {state_in[29:0], feedback};
        end
    endtask

    //crea un paquete de datos de num_bytes bytes, llenando el payload con bits de prbs31
    //ya llama a get_next_prbs31 para ir generando los bits de prbs31
    task automatic create_packet(input int num_bytes, output eth_packet pkt, input xgmii_err_t err = ERR_NONE);
        reg [30:0] next_state;
        reg        bit_out;
        reg [7:0]  byte_temp;

        pkt = new(num_bytes, err);
        for (int b = 0; b < num_bytes; b++) begin
            for (int i = 0; i < 8; i++) begin
                get_next_prbs31(this.state, next_state, bit_out);
                this.state   = next_state;
                byte_temp[i] = bit_out;
            end
            pkt.payload[b] = byte_temp;
        end
    endtask
endclass


// --- CHECKER PRBS31 CON estados (ST_UNLOCK / ST_LOCK) ---
class prbs31_checker;
    typedef enum bit { ST_UNLOCK = 1'b0, ST_LOCK = 1'b1 } state_t;
    
    state_t    curr_state;
    reg [30:0] lfsr;
    
    // Thresholds configurables
    int lock_threshold;   // Cantidad de bits correctos seguidos para pasar a ST_LOCK
    int unlock_threshold; // Cantidad de fallos en ST_LOCK para volver a ST_UNLOCK
    
    // Contadores internos
    int good_streak; //Cantidad de matches consecutivos en ST_UNLOCK para pasar a ST_LOCK
    int fail_count; //cantidad de fallos consecutivos en ST_LOCK para volver a ST_UNLOCK
    int total_errors; //erores totales acumulados (para reportar al final del paquete)

    //constructor de la clase prbs31_checker
    function new(int lock_th = 64, int unlock_th = 8);
        this.curr_state       = ST_UNLOCK;
        this.lfsr             = 31'h0;
        this.lock_threshold   = lock_th;
        this.unlock_threshold = unlock_th;
        this.good_streak      = 0;
        this.fail_count       = 0;
        this.total_errors     = 0;
    endfunction

    // Procesa 1 bit recibido aplicando la maquina de estados
    //recibe el bit recibido (rx_bit) y compara con lo que predice el LFSR interno
    task automatic check_bit(input reg rx_bit);
        reg internal_feedback;
        reg expected_bit;
        reg rx_bit_uninv;

        // Calculamos lo que predice nuestro LFSR actual
        internal_feedback = lfsr[30] ^ lfsr[27];
        expected_bit      = ~internal_feedback; // Invertido segun 802.3
        
        // El bit recibido des-invertido (para alimentar el registro en ST_UNLOCK)
        rx_bit_uninv      = ~rx_bit;

        case (curr_state)
            // -----------------------------------------------------
            ST_UNLOCK: begin
                // Verificamos si el bit que llega ya coincide con la prediccion
                if (rx_bit === expected_bit) begin
                    good_streak++;
                    if (good_streak >= lock_threshold) begin
                        curr_state = ST_LOCK;
                        fail_count = 0;
                        $display("[PRBS CHECKER] -> Pasa a ST_LOCK (Sincronizado!)");
                    end
                end else begin
                    good_streak = 0; // Se rompio la racha, reiniciamos contador
                end

                // En ST_UNLOCK, usamos LO QUE LLEGA para calcular el proximo estado
                lfsr = {lfsr[29:0], rx_bit_uninv};
            end

            // -----------------------------------------------------
            ST_LOCK: begin
                if (rx_bit !== expected_bit) begin
                    fail_count++;
                    total_errors++;
                    $display("[PRBS ERROR en ST_LOCK] Esperado: %b | Recibido: %b (Fallo %0d/%0d)", 
                              expected_bit, rx_bit, fail_count, unlock_threshold);
                    
                    if (fail_count >= unlock_threshold) begin
                        curr_state  = ST_UNLOCK;
                        good_streak = 0;
                        $display("[PRBS CHECKER] -> Demasiados fallos! Vuelve a ST_UNLOCK");
                    end
                end

                // En ST_LOCK, usamosinternal_feedback = lfsr[30] ^ lfsr[27]; la LOGICA INTERNA para calcular el proximo estado
                // (No contaminamos el LFSR interno con el bit malo que vino de afuera)
                lfsr = {lfsr[29:0], internal_feedback};
            end
        endcase
    endtask

    // Recorre todo el paquete que le entrega el Monitor XGMII
    //llama internamente a check_bit() para cada bit del payload|
    task automatic check_packet(input eth_packet pkt);
        for (int b = 0; b < pkt.payload.size(); b++) begin
            for (int i = 0; i < 8; i++) begin
                check_bit(pkt.payload[b][i]);
            end
        end
        $display("[RESUMEN PAQUETE] Estado actual: %s | Errores totales acumulados: %0d", 
                  curr_state.name(), total_errors);
    endtask
endclass

`endif
