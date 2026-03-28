# vyges-pinmux-lite

Lightweight pin multiplexer with native TL-UL slave interface. Vyges original IP — no OpenTitan RACL/lifecycle dependencies.

## Features

- Configurable number of IO pins (default 16)
- Per-pin 4-function mux (GPIO / Function A / Function B / Function C)
- Per-pin output enable override
- Per-pin pull-up/pull-down enable and direction
- 2-FF input synchronizer for metastability
- Software-configurable via TL-UL register writes

## Register Map

| Offset | Name      | Access | Description |
|--------|-----------|--------|-------------|
| 0x00   | PIN_FUNC0 | RW     | Function select pins 0-15 (2 bits per pin) |
| 0x04   | PIN_FUNC1 | RW     | Function select pins 16-31 |
| 0x10   | PIN_OE    | RW     | Output enable per pin |
| 0x14   | PIN_OUT   | RW     | GPIO output value per pin |
| 0x18   | PIN_IN    | RO     | Sampled input (2-FF synchronized) |
| 0x1C   | PIN_PULL  | RW     | Pull enable per pin |
| 0x20   | PIN_PULLSEL | RW   | Pull direction (1=up, 0=down) |

## Function Select

| Value | Function |
|-------|----------|
| 2'b00 | GPIO (PIN_OUT/PIN_IN registers) |
| 2'b01 | Function A (e.g. UART TX/RX) |
| 2'b10 | Function B (e.g. SPI SCLK/MOSI/MISO/CS) |
| 2'b11 | Function C (reserved) |

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| NUM_PINS  | 16      | Number of configurable IO pins |
| NUM_FUNCS | 4       | Functions per pin |

## License

Apache-2.0 — see [LICENSE](LICENSE).
