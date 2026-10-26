`ifndef INTERFACES_SV
`define INTERFACES_SV

interface xgmii_if(
    input wire tx_clk, 
    input wire tx_rst,
    input wire rx_clk,
    input wire rx_rst
);
    reg  [63:0] txd;
    reg  [7:0]  txc;
    reg         tx_valid;

    wire [63:0] rxd;
    wire [7:0]  rxc;
    wire        rx_valid;
    
    // Pines de estatus del DUT para verificar cuando mandamos cosas erroneas
    wire        tx_bad_block;
    wire        rx_bad_block;
    wire [6:0]  rx_error_count;
    wire        rx_block_lock;
endinterface

// Tipos de errores que podemos forzar en XGMII para probar el DUT
typedef enum {
    ERR_NONE,           // Trama XGMII perfecta
    ERR_NO_START,       // Enviar datos sin poner el byte /S/ (0xFB) al principio
    ERR_BAD_START_LANE, // Poner el /S/ en el byte 2 en vez del byte 0 o 4 (Ilegal en 802.3)
    ERR_MID_TERMINATE,  // Meter un /T/ (0xFD) a mitad de los datos y seguir mandando datos
    ERR_NO_TERMINATE    // Terminar el paquete de golpe sin mandar /T/ (0xFD)
} xgmii_err_t;

//clase eth_packet: representa un paquete de datos con payload y tipo de error a inyectar (que definiremos nosotros al uso del driver)
//arma 
class eth_packet;
    reg [7:0]   payload []; //arreglo dinamico de bytes, cada posicion representa un byte del payload del paquete
    xgmii_err_t err_type; // Le dice al driver si debe romper la trama a proposito y que tipo de error inyectar
    
    function new(int size, xgmii_err_t err = ERR_NONE);
        payload  = new[size];
        err_type = err;
    endfunction
endclass

`endif
