// Copyright 2026 Vyges Inc.
// SPDX-License-Identifier: Apache-2.0
//
// pinmux_lite — Lightweight pin multiplexer with TL-UL slave interface
//
// Features:
//   - NUM_PINS configurable IO pins (default 16)
//   - Per-pin 2-bit function select (4 functions per pin)
//   - Per-pin output enable override
//   - Per-pin pull-up/pull-down enable
//   - Input sampling with 2-FF synchronizer
//
// Register map (32-bit aligned):
//   0x00  PIN_FUNC[0]  — [1:0] func select for pins 0-15 (2 bits each, packed)
//                        pins 0-15 in bits [31:0] (2 bits per pin)
//   0x04  PIN_FUNC[1]  — [1:0] func select for pins 16-31 (if NUM_PINS > 16)
//   0x10  PIN_OE       — [NUM_PINS-1:0] output enable override (1=output)
//   0x14  PIN_OUT      — [NUM_PINS-1:0] direct output value (when func=GPIO)
//   0x18  PIN_IN       — [NUM_PINS-1:0] sampled input values (read-only)
//   0x1C  PIN_PULL     — [NUM_PINS-1:0] pull enable (1=pull enabled)
//   0x20  PIN_PULLSEL  — [NUM_PINS-1:0] pull direction (1=pull-up, 0=pull-down)
//
// Function encoding per pin:
//   2'b00 = GPIO (direct from PIN_OUT/PIN_IN registers)
//   2'b01 = Function A (e.g. UART)
//   2'b10 = Function B (e.g. SPI)
//   2'b11 = Function C (reserved / custom)

`ifndef PINMUX_LITE_SV
`define PINMUX_LITE_SV

module pinmux_lite
  import tlul_pkg::*;
#(
  parameter int unsigned NUM_PINS = 16,
  parameter int unsigned NUM_FUNCS = 4   // functions per pin (2-bit select)
) (
  input  logic clk_i,
  input  logic rst_ni,

  // TL-UL slave interface
  input  tlul_pkg::tl_h2d_t tl_i,
  output tlul_pkg::tl_d2h_t tl_o,

  // Peripheral function inputs (active when selected via PIN_FUNC)
  // Function A inputs/outputs (e.g. UART)
  input  logic [NUM_PINS-1:0] func_a_out_i,    // function A output data
  input  logic [NUM_PINS-1:0] func_a_oe_i,     // function A output enable
  output logic [NUM_PINS-1:0] func_a_in_o,     // function A input data

  // Function B inputs/outputs (e.g. SPI)
  input  logic [NUM_PINS-1:0] func_b_out_i,
  input  logic [NUM_PINS-1:0] func_b_oe_i,
  output logic [NUM_PINS-1:0] func_b_in_o,

  // Function C inputs/outputs (reserved)
  input  logic [NUM_PINS-1:0] func_c_out_i,
  input  logic [NUM_PINS-1:0] func_c_oe_i,
  output logic [NUM_PINS-1:0] func_c_in_o,

  // External pad interface
  output logic [NUM_PINS-1:0] pad_out_o,       // pad output data
  output logic [NUM_PINS-1:0] pad_oe_o,        // pad output enable
  input  logic [NUM_PINS-1:0] pad_in_i,        // pad input data
  output logic [NUM_PINS-1:0] pad_pull_en_o,   // pad pull enable
  output logic [NUM_PINS-1:0] pad_pull_sel_o   // pad pull select (1=up, 0=down)
);

  // -------------------------------------------------------------------------
  // TL-UL response logic
  // -------------------------------------------------------------------------
  logic        req_valid;
  logic        req_write;
  logic [31:0] req_addr;
  logic [31:0] req_wdata;
  logic [7:0]  req_source;
  logic [1:0]  req_size;

  logic        rsp_valid;
  logic [31:0] rsp_rdata;
  logic        rsp_error;

  assign req_valid  = tl_i.a_valid;
  assign req_write  = (tl_i.a_opcode == PutFullData) || (tl_i.a_opcode == PutPartialData);
  assign req_addr   = tl_i.a_address;
  assign req_wdata  = tl_i.a_data;
  assign req_source = tl_i.a_source;
  assign req_size   = tl_i.a_size;

  assign tl_o.a_ready  = 1'b1;
  assign tl_o.d_valid  = rsp_valid;
  assign tl_o.d_opcode = tl_d_op_e'(req_write ? AccessAck : AccessAckData);
  assign tl_o.d_param  = '0;
  assign tl_o.d_size   = req_size;
  assign tl_o.d_source = req_source;
  assign tl_o.d_sink   = '0;
  assign tl_o.d_data   = rsp_rdata;
  assign tl_o.d_error  = rsp_error;
  assign tl_o.d_user   = '0;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      rsp_valid <= 1'b0;
    else
      rsp_valid <= req_valid;
  end

  // -------------------------------------------------------------------------
  // Registers
  // -------------------------------------------------------------------------
  logic [1:0]          pin_func [NUM_PINS];  // function select per pin
  logic [NUM_PINS-1:0] pin_oe;              // output enable
  logic [NUM_PINS-1:0] pin_out;             // GPIO output
  logic [NUM_PINS-1:0] pin_pull;            // pull enable
  logic [NUM_PINS-1:0] pin_pullsel;         // pull direction

  // 2-FF input synchronizer
  logic [NUM_PINS-1:0] pad_in_sync1, pad_in_sync2;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pad_in_sync1 <= '0;
      pad_in_sync2 <= '0;
    end else begin
      pad_in_sync1 <= pad_in_i;
      pad_in_sync2 <= pad_in_sync1;
    end
  end

  // -------------------------------------------------------------------------
  // Register write
  // -------------------------------------------------------------------------
  logic [7:0] reg_offset;
  assign reg_offset = req_addr[7:0];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < NUM_PINS; i++) pin_func[i] <= 2'b00;  // default: GPIO
      pin_oe      <= '0;
      pin_out     <= '0;
      pin_pull    <= '0;
      pin_pullsel <= '0;
    end else if (req_valid && req_write) begin
      case (reg_offset)
        8'h00: begin  // PIN_FUNC[0]: pins 0-15
          for (int i = 0; i < 16 && i < NUM_PINS; i++)
            pin_func[i] <= req_wdata[i*2 +: 2];
        end
        8'h04: begin  // PIN_FUNC[1]: pins 16-31
          for (int i = 0; i < 16 && (i + 16) < NUM_PINS; i++)
            pin_func[i + 16] <= req_wdata[i*2 +: 2];
        end
        8'h10: pin_oe      <= req_wdata[NUM_PINS-1:0];
        8'h14: pin_out     <= req_wdata[NUM_PINS-1:0];
        8'h1C: pin_pull    <= req_wdata[NUM_PINS-1:0];
        8'h20: pin_pullsel <= req_wdata[NUM_PINS-1:0];
        default: ;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Register read
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_rdata <= '0;
      rsp_error <= 1'b0;
    end else if (req_valid && !req_write) begin
      rsp_error <= 1'b0;
      case (reg_offset)
        8'h00: begin
          rsp_rdata <= '0;
          for (int i = 0; i < 16 && i < NUM_PINS; i++)
            rsp_rdata[i*2 +: 2] <= pin_func[i];
        end
        8'h04: begin
          rsp_rdata <= '0;
          for (int i = 0; i < 16 && (i + 16) < NUM_PINS; i++)
            rsp_rdata[i*2 +: 2] <= pin_func[i + 16];
        end
        8'h10: rsp_rdata <= {{(32-NUM_PINS){1'b0}}, pin_oe};
        8'h14: rsp_rdata <= {{(32-NUM_PINS){1'b0}}, pin_out};
        8'h18: rsp_rdata <= {{(32-NUM_PINS){1'b0}}, pad_in_sync2};
        8'h1C: rsp_rdata <= {{(32-NUM_PINS){1'b0}}, pin_pull};
        8'h20: rsp_rdata <= {{(32-NUM_PINS){1'b0}}, pin_pullsel};
        default: begin
          rsp_rdata <= '0;
          rsp_error <= 1'b1;
        end
      endcase
    end else begin
      rsp_rdata <= '0;
      rsp_error <= 1'b0;
    end
  end

  // -------------------------------------------------------------------------
  // Pin mux logic
  // -------------------------------------------------------------------------
  always_comb begin
    for (int i = 0; i < NUM_PINS; i++) begin
      case (pin_func[i])
        2'b00: begin  // GPIO
          pad_out_o[i] = pin_out[i];
          pad_oe_o[i]  = pin_oe[i];
        end
        2'b01: begin  // Function A
          pad_out_o[i] = func_a_out_i[i];
          pad_oe_o[i]  = func_a_oe_i[i];
        end
        2'b10: begin  // Function B
          pad_out_o[i] = func_b_out_i[i];
          pad_oe_o[i]  = func_b_oe_i[i];
        end
        2'b11: begin  // Function C
          pad_out_o[i] = func_c_out_i[i];
          pad_oe_o[i]  = func_c_oe_i[i];
        end
      endcase
    end
  end

  // Route sampled input to all function interfaces
  assign func_a_in_o = pad_in_sync2;
  assign func_b_in_o = pad_in_sync2;
  assign func_c_in_o = pad_in_sync2;

  // Pull control
  assign pad_pull_en_o  = pin_pull;
  assign pad_pull_sel_o = pin_pullsel;

endmodule

`endif // PINMUX_LITE_SV
