# Test Plan: PHY 10G (`taxi_eth_phy_10g`)

## Entorno de Pruebas (Setup)
* Instanciar el DUT `taxi_eth_phy_10g`.
* Conectar la interfaz `xgmii_if` a los pines XGMII del DUT (`xgmii_txd`, `xgmii_rxd`, etc.).
* Hacer un **loopback a nivel SERDES**: conectar de forma directa las salidas `serdes_tx_data` y `serdes_tx_hdr` a las entradas `serdes_rx_data` y `serdes_rx_hdr` del propio módulo.
* Utilizar las clases `xgmii_agent` y `prbs_agent` conectadas a la interfaz para estimular y verificar.

## Casos de Prueba

1. **Sanity Check (Loopback corto sin errores)**
   * Usar la tarea `run_generation` con 32 bytes.
   * Comprobamos que el camino de datos básico funciona de punta a punta. Lo que entra por el XGMII TX sale por el SERDES, vuelve a entrar, y se lee limpio en el XGMII RX.

2. **Extremos de longitud de trama (Frame Size)**
   * Enviar frames con `run_generation(64)` y `run_generation(1518)`.
   * Para ver que la PHY maneja bien los tamaños mínimos y máximos estándar de Ethernet antes de fragmentarse.

3. **Alineación de Terminate (Bytes impares)**
   * Enviar un payload que no sea múltiplo de 8 (ej. 123 bytes o 35 bytes).
   * Obligamos al `xgmii_agent` a colocar el byte de `Terminate` (0xFD) en un lane intermedio. Sirve para confirmar que el módulo PCS procesa bien los finales de trama desalineados.

4. **Inyección de errores en Payload**
   * Activar `inject_error = 1` en el `xgmii_agent` y elegir un `error_byte_idx`.
   * Alteramos un byte del payload. La PHY debería dejar pasar este dato (es transparente al contenido). El test pasa si el `check_rx` del `prbs_agent` falla indicando exactamente ese error detectado.

5. **Tráfico en ráfaga**
   * Llamar a `run_generation` repetidas veces dentro de un loop o un `fork/join`, dejando el mínimo espacio de Idles.
   * Con esto estresamos la máquina de estados del bloque PCS. Para ver si el módulo se ahoga o si mantiene la sincronización cuando la red está al 100% de capacidad.

6. **Test de PRBS31 Interno del módulo**
   * Poner a 1 las señales `cfg_tx_prbs31_enable` y `cfg_rx_prbs31_enable` del DUT. No mandar paquetes por el `xgmii_agent`.
   * Prueba el generador de secuencias pseudoaleatorias integrado en la propia PHY. Se monitorea que los pines de estado (`rx_status`, `rx_block_lock`) den OK sin contabilizar errores.

7. **Reset asincrónico bajo tráfico**
   * Comenzar el envío de un paquete grande (ej. 1500 bytes) y a la mitad afirmar `tx_rst` y `rx_rst` por unos ciclos.
   * Verifica que el sistema aborte la transmisión correctamente, regrese a su estado inicial de Idles (`0x0707...`) y vuelva a linkear sin quedarse colgado.

8. **Máquina de estados de sincronización de bloques**
   * Inyectar headers inválidos en el SERDES (`00` o `11` en `serdes_rx_hdr`) durante más de 16 bloques consecutivos en una ventana de 64 bloques.
   * Según la norma 802.3, esto debe tirar abajo el estado de sincronización. Comprobamos que la bandera `rx_block_lock` pase a 0 y que no se reciban datos válidos en el XGMII.

9. **Detección de Errores de Secuencia XGMII**
   * Forzar al `xgmii_agent` a enviar violaciones de protocolo (ej. un `Start` 0xFB inmediatamente después de otro `Start` sin un `Terminate` en el medio, o datos durante un periodo de Idles).
   * El módulo PCS deberia detectar la violación, levantar el flag `rx_sequence_error` y propagar bytes de error (`0xFE`) hacia el bus RX.

10. **Verificación del Scrambler (Balance DC)**
    * Con el parámetro `SCRAMBLER_DISABLE = 0`, enviar desde el XGMII una carga útil de puros ceros (`0x00...00`).
    * El estándar usa un polinomio (x^58 + x^39 + 1) para evitar patrones fijos. Chequeamos que la salida `serdes_tx_data` sea pseudoaleatoria, evitando problemas de balance DC en la fibra/cobre.

11. **Corrupción del Block Type Field (Códigos de Control Inválidos)**
    * Interceptar en el loopback un bloque de control válido de 66b (ej. Idles `0x1E`) y modificar los primeros 8 bits del payload para que sea un Block Type inexistente en la tabla de la norma.
    * El decoder debe marcarlo como bloque erróneo (`rx_bad_block` = 1) y reemplazar la salida en el bus `xgmii_rxd` por caracteres de error (`0xFE`).

12. **Codificación de Ordered Sets (Local / Remote Faults)**
    * Modificar temporalmente el testbench para enviar por el XGMII un Sequence Ordered Set (Lane 0 = `0x9C`, Lanes 1-3 = `0x00 0x00 0x01` para Local Fault).
    * Garantiza que el PCS mapee correctamente los códigos de falla de capa física a un bloque de control tipo `0x4B` en el TX, y que el RX lo decodifique a la perfección.

13. **Generación de Sync Headers (Datos vs. Control)**
    * Enviar tráfico de payload continuo por XGMII y, tras finalizar la trama, dejar el bus en reposo transmitiendo Idles (`0x07`).
    * Chequear en la salida del módulo (`serdes_tx_hdr`) que para los bytes de datos el header codificado sea estrictamente `01` y para los Idles (bloques de control) sea estrictamente `10`. Esto verifica la regla fundamental de multiplexación del encoding 64b/66b.

14. **Decodificación de Sync Headers inválidos**
    * Interceptar la conexión del loopback e inyectar forzadamente un header `00` y, en un ciclo posterior, un `11` en la entrada `serdes_rx_hdr`.
    * La norma prohíbe explícitamente estos headers para mantener el balanceo y sincronización. El decodificador RX debe detectar la violación, levantar la bandera de error (`rx_bad_block = 1`) y reemplazar los 8 bytes de salida en el bus `xgmii_rxd` con el carácter de error estándar `0xFE`.

15. **Mapeo del Block Type para Start (0xFB) y Terminate (0xFD)**
    * Enviar un paquete por XGMII. Asegurar que el byte de inicio (`0xFB`) caiga en el lane 0 y ajustar el tamaño del payload para forzar que el byte de fin (`0xFD`) caiga en un lane intermedio (ej. lane 3).
    * Verifica que el codificador TX asigne los *Block Types* correctos definidos por la norma. Los primeros 8 bits del bloque codificado de Start deben ser `0x78`, y para el bloque de Terminate en el lane 3 deben ser `0xB4`.

16. **Rechazo de Códigos de Control Desconocidos (Invalid Block Type)**
    * Forzar mediante el testbench un bloque de control válido en el header (`serdes_rx_hdr = 10`), pero inyectar en `serdes_rx_data` un *Block Type* de 8 bits que no exista en la tabla de codificación de la cláusula 49 (por ejemplo, `0x15`).
    * Al no reconocer el tipo de bloque, el módulo PCS no debe intentar interpretarlo y debe invalidar la palabra completa. Todo el bus `xgmii_rxc` debe ir a `0xFF` y `xgmii_rxd` llenarse de errores (`0xFE`).

17. **Codificación de Ordered Sets (Local / Remote Faults)**
    * Enviar a través del `xgmii_agent` el código de control `0x9C` (Sequence) en el lane 0, seguido de los bytes de notificación de falla (ej. `0x00 0x00 0x01` para Local Fault).
    * Garantiza que el codificador identifique el *Ordered Set* de señalización de estado y lo empaquete utilizando el *Block Type* específico `0x4B` en `serdes_tx_data`. Es crítico para confirmar que la PHY puede propagar correctamente el estado del enlace físico.
