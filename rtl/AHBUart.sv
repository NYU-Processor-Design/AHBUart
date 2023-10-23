/*
*   Copyright 2023 Purdue University
*
*   Licensed under the Apache License, Version 2.0 (the "License");
*   you may not use this file except in compliance with the License.
*   You may obtain a copy of the License at
*
*       http://www.apache.org/licenses/LICENSE-2.0
*
*   Unless required by applicable law or agreed to in writing, software
*   distributed under the License is distributed on an "AS IS" BASIS,
*   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
*   See the License for the specific language governing permissions and
*   limitations under the License.
*
*
*   Filename:     AHBUart.sv
*
*   Created by:   Vito Gamberini
*   Email:        vito@gamberini.email
*   Date Created: 07/13/2023
*   Description:  AHB wrapper for PurdNyUart
*/


module AHBUart #(
    int DefaultRate = 5207  // Chosen by fair dice roll
) (
    input clk,
    input nReset,

    input  rx,
    output tx,

    bus_protocol_if.peripheral_vital bp
);
  typedef enum logic [31:0] {
    RX_STATE = 0,
    RX_DATA  = 4,
    TX_STATE = 8,
    TX_DATA  = 12
  } ADDRS;

  // Not meaningful in a UART context
  assign bp.error = 0;
  assign bp.request_stall = 0;

  // Uart stuff
  logic [ 7:0] rxData;

  logic [15:0] rate;
  logic [ 7:0] txData;

  logic rxErr, rxClk, rxDone;
  logic txValid, txClk, txDone;

  logic syncReset;

  always_ff @(posedge clk, negedge nReset) begin
    if (!nReset) begin
      syncReset <= 1;
    end else if (bp.wen) begin
      case (bp.addr)
        RX_STATE, TX_STATE: syncReset <= 1;
      endcase
    end else begin
      syncReset <= 0;
    end
  end

  // Params set "clock rate" to 2**16, and "min baud rate" to 1
  // This is equivalent to "please give me 16-bit counters"
  BaudRateGen #(2 ** 16, 1) bg (
      .phase(1'b0),
      .*
  );

  UartRxEn uartRx (
      .en  (rxClk),
      .in  (rx),
      .data(rxData),
      .done(rxDone),
      .err (rxErr),
      .*
  );

  UartTxEn uartTx (
      .en   (txClk),
      .data (txData),
      .valid(txValid),
      .out  (tx),  // verilator lint_off PINCONNECTEMPTY
      .busy (),  // verilator lint_on PINCONNECTEMPTY
      .done (txDone),
      .*
  );

  // State variables, done is handled by the transmit FIFO
  logic err, avail, done;

  always_ff @(posedge clk, negedge nReset) begin
    if (!nReset) begin
      err   <= 0;
      avail <= 0;
    end else if (bp.ren) begin
      err   <= rxErr || ((bp.addr != RX_STATE) && err);
      avail <= rxDone || ((bp.addr != RX_DATA) && avail);
    end else begin
      err   <= rxErr || err;
      avail <= rxDone || avail;
    end
  end

  logic [7:0] rFIFOCount;
  logic [7:0] rFIFO[2:0];

  always_ff @(posedge clk, negedge nReset) begin
    if (!nReset) begin
      rFIFOCount <= 0;
      rFIFO <= '{default: 0};
    end else if (bp.ren && bp.addr == RX_DATA) begin
      if (rxDone) begin
        rFIFO[0]   <= rxData;
        rFIFOCount <= 1;
      end else begin
        rFIFOCount <= 0;
      end
    end else if (rxDone) begin
      if (rFIFOCount < 3) rFIFO[2'(rFIFOCount)] <= rxData;
      rFIFOCount <= rFIFOCount + 1;
    end
  end

  logic [7:0] wFIFOCount;
  logic [1:0] wFIFOMaxIndex;
  logic [1:0] wIndex;
  logic [7:0] wFIFO[2:0];
  logic wStart;

  assign txData = wFIFO[wIndex];

  always_ff @(posedge clk, negedge nReset) begin
    if (!nReset) begin
      wIndex <= 0;
      txValid <= 0;
      done <= 1;
      wStart <= 0;
    end else if (done && bp.wen && bp.addr == TX_DATA) begin
      wIndex <= 0;
      done   <= 0;
      wStart <= 1;
    end else if (wStart || (wIndex != wFIFOMaxIndex && txDone)) begin
      txValid <= 1;
      wIndex  <= wIndex + !wStart;
      wStart  <= 0;
    end else begin
      if (txValid) txValid <= 0;
      if (wIndex == wFIFOMaxIndex && txDone) done <= 1;
    end
  end

  // We're only compatible with 32-bit words

  // status[31:24]: wStatus only: Counter MSB
  // status[23:16]: wStatus only: Counter LSB
  // status[15: 2]: Reserved/Do nothing
  // status[1]: err
  // status[0]: done/avail
  logic [31:0] rStatus;
  logic [31:0] wStatus;

  // Data registers are tiny FIFOs
  // data[31:24]: Number of bytes in queue, 0 is treated the same as 1, >3 is same as 3
  // data[23:16]: 3rd byte in queue
  // data[15: 8]: 2nd byte in queue
  // data[ 7: 0]: 1st byte in queue
  logic [31:0] rData;
  logic [31:0] wData;

  always_ff @(posedge clk, negedge nReset) begin
    if (!nReset) begin
      rStatus <= 0;
      rData   <= 0;
      wStatus <= 1;
      wData   <= 0;
    end else begin
      rStatus <= {30'(0), err, avail};
      rData   <= {rFIFOCount, rFIFO[2], rFIFO[1], rFIFO[0]};
      wStatus <= {rate, 15'(0), done};
      wData   <= {wFIFOCount, wFIFO[2], wFIFO[1], wFIFO[0]};
    end
  end

  logic [7:0] bpData[3:0];

  always_comb begin
    bpData = {bp.wdata[31:24], bp.wdata[23:16], bp.wdata[15:8], bp.wdata[7:0]};

    if (bp.ren) begin
      case (bp.addr)
        RX_STATE: bp.rdata = rStatus;
        RX_DATA:  bp.rdata = rData;
        TX_STATE: bp.rdata = wStatus;
        TX_DATA:  bp.rdata = wData;
      endcase
    end else begin
      bp.rdata = 0;
    end
  end

  always_ff @(posedge clk, negedge nReset) begin
    if (!nReset) begin
      rate <= 16'(DefaultRate);

      wFIFOCount <= 0;
      wFIFOMaxIndex <= 0;
      wFIFO <= '{default: 0};
    end else if (bp.wen) begin
      case (bp.addr)
        TX_STATE: begin
          if (bp.strobe[2]) rate[7:0] <= bpData[2];
          if (bp.strobe[3]) rate[15:8] <= bpData[3];
        end

        TX_DATA:
        if (done) begin
          if (bp.strobe[3]) begin
            wFIFOCount <= bpData[3];
            wFIFOMaxIndex <= bpData[3] > 3 ? 2 : |bpData[3] ? 2'(bpData[3] - 8'b1) : 0;
          end
          if (bp.strobe[2]) wFIFO[2] <= bpData[2];
          if (bp.strobe[1]) wFIFO[1] <= bpData[1];
          if (bp.strobe[0]) wFIFO[0] <= bpData[0];
        end
      endcase
    end
  end
endmodule
