# Test Plan – `taxi_eth_phy_10g` (PCS 10GBASE-R, IEEE 802.3 Cl.49)

DUT: `taxi/src/eth/rtl/taxi_eth_phy_10g.sv`
Foco inicial: **camino TX** (XGMII → 64b/66b → scrambler → gearbox → SERDES). RX se agrega después.

## 1. Arquitectura del testbench

```
 top_LSFR (HW) -> prbs_agent -> xgmii_agent.drive_tx -> [ DUT ] -> serdes_tx_*
                                                                      |
                                                  serdes_monitor (decodifica 66b + descrambler)
                                                                      |
 prbs_agent.check_rx  <-  xgmii_agent.monitor_rx  <- (XGMII reconstruido)
```

| Componente | Archivo | Estado |
|---|---|---|
| Interfaces + `eth_packet` | `interfaces.sv` | Hecho |
| PRBS agent (genera/chequea payload) | `prbs_agent.sv` | Hecho (loopback validado) |
| XGMII agent (driver + monitor) | `xgmii_agent.sv` | Hecho (loopback validado) |
| SERDES monitor / modelo de referencia | `serdes_agent.sv` | **Pendiente** |
| Interfaz SERDES | `interfaces.sv` | **Pendiente** |
| Top con DUT | `tb_dut.sv` | **Pendiente** |

## 2. Fase 0 – Validación de agentes (loopback)  ✅
- [x] 32 bytes PRBS → XGMII → XGMII → check = PASSED.
- [ ] Inyección de error (`^ 8'h01` en el driver) → el checker debe dar FAILED (prueba que el checker no miente).
- [ ] Tamaños variados: 1, 7, 8, 9, 15, 16, 64, 1500 bytes (probar borde múltiplo de 8 y Terminate).
- [ ] Idles entre tramas y tramas back-to-back.

## 3. Fase 1 – Reset y estado inicial (DUT)
| ID | Test | Esperado |
|---|---|---|
| R1 | Reset en `tx_rst`/`rx_rst` | Salidas en estado conocido, sin X |
| R2 | Solo Idles por XGMII | `serdes_tx_hdr` = `2'b01` (control), bloque de Idle válido |
| R3 | `tx_bad_block` tras reset | 0 |

## 4. Fase 2 – ENCODE (64b/66b)
Se chequea en la salida SERDES (con scrambler deshabilitado: `SCRAMBLER_DISABLE=1`) para aislar el encoder.

| ID | Test | Esperado |
|---|---|---|
| E1 | **Sync header** con datos puros (`txc=0x00`) | `hdr = 2'b10` |
| E2 | **Sync header** con cualquier control (`txc≠0`) | `hdr = 2'b01` |
| E3 | Header nunca `00` ni `11` | Siempre 01 o 10 |
| E4 | Payload en bloque de datos | `serdes_tx_data` = bytes de `txd` sin cambios (lane0 = LSB) |
| E5 | **Block type** Start en Lane 0 (`0xFB`) | BT = `0x78` |
| E6 | Block type Terminate en cada lane (T0..T7) | BT = `0x87,0x99,0xAA,0xB4,0xCC,0xD2,0xE1,0xFF` |
| E7 | Block type Idle (`0x07` x8) | BT = `0x1E` |
| E8 | Start en Lane 4 (`0xFB` en lane 4) | BT = `0x33` |
| E9 | Control inválido (ej. `0xFB` en lane 3) | `tx_bad_block`=1, bloque de error |
| E10 | Trama completa Start→Data→Terminate | Secuencia de bloques correcta |

## 5. Fase 3 – SCRAMBLER (x^58 + x^39 + 1)
Los 2 bits de header **no** se scramblean, solo los 64 de payload.

| ID | Test | Esperado |
|---|---|---|
| S1 | Header sin scramblear | `hdr` igual con o sin scrambler |
| S2 | Payload scrambleado ≠ payload original | Salida distinta al dato plano |
| S3 | **Modelo de referencia en SV**: scramblear en el TB y comparar bit a bit | 100% coincidencia |
| S4 | **Descrambler en el TB** sobre `serdes_tx_data` | Recupera el payload original |
| S5 | Estado inicial / seed | Coincide con el modelo tras reset |
| S6 | Cadena larga (≥ 10k bloques) PRBS | Sin desincronización del modelo |
| S7 | `SCRAMBLER_DISABLE=1` | Datos salen sin modificar |
| S8 | Patrón todo ceros / todo unos | Salida no queda constante (scrambler funciona) |

## 6. Fase 4 – GEARBOX (66 → 64 bits)
Con `TX_GBX_IF_EN=1`. El gearbox convierte bloques de 66 bits en palabras de 64 bits; cada 32 palabras de 64 entran 31 bloques de 66 y hay que **pausar 1 ciclo** (`tx_gbx_req_stall`).

| ID | Test | Esperado |
|---|---|---|
| G1 | Frecuencia de stall | 1 stall cada 33 ciclos (patrón del gearbox) |
| G2 | `tx_gbx_req_sync` | Pulso de sincronía periódico |
| G3 | Reconstrucción en el TB | Rearmar bloques de 66b desde palabras de 64b == bloques esperados |
| G4 | `serdes_tx_hdr_valid` / `serdes_tx_data_valid` | Coherentes con el patrón |
| G5 | Gearbox deshabilitado (`TX_GBX_IF_EN=0`) | Un bloque de 66b por ciclo, `hdr` separado |
| G6 | Backpressure (`serdes_tx_gbx_req_stall`) | El DUT respeta el stall, no pierde datos |

## 7. Fase 5 – End to end TX
- [ ] PRBS → XGMII → DUT → serdes_monitor (descramble + decode) → XGMII reconstruido → `check_rx` = PASSED.
- [ ] Tramas de tamaños variados y back-to-back.
- [ ] Tramas con Idles intermedios de longitud aleatoria.
- [ ] `xgmii_tx_valid` en 0 durante la trama (si aplica).
- [ ] Soak: ≥ 100k tramas aleatorias.

## 8. Fase 6 – Casos negativos / robustez
- [ ] Terminate sin Start previo.
- [ ] Start dentro de otra trama.
- [ ] Códigos de control reservados.
- [ ] Reset en mitad de una trama.
- [ ] `cfg_tx_prbs31_enable=1`: salida es PRBS31 (comparar con modelo).

## 9. Fase 7 – RX (siguiente etapa)
Loopback SERDES TX→RX del DUT: `rx_block_lock`, `rx_status`, `rx_high_ber`, `rx_bad_block`, `rx_error_count`, bitslip, inyección de errores en header y payload.

## 10. Criterios de salida
- Todos los tests de las fases 0–5 en PASSED, sin errores X/Z.
- Cobertura funcional: todos los block types de Cl.49 generados y vistos al menos una vez.
- Tamaños de trama {1..1518} y alineaciones de Start (lane 0 y lane 4) cubiertos.
- Regresión con semillas PRBS distintas.

## 11. Orden recomendado de trabajo
1. Cerrar Fase 0 (error injection + tamaños).
2. Armar `tb_dut.sv` con el DUT y `SCRAMBLER_DISABLE=1`, `TX_GBX_IF_EN=0` → tests E1–E10.
3. Activar scrambler → S1–S8 (modelo de referencia).
4. Activar gearbox → G1–G6.
5. End to end (Fase 5) y luego robustez.
