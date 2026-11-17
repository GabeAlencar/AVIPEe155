/*
 * Testbench: frame_tx_tb
 * Author: Gabe Alencar gmenendezdealencar@g.hmc.edu
 * Date:   11/16/26
 *
 * Tests spi_frame_tx and uart_frame_tx together with a known pattern, the
 * way fft_controller drives them (256 writes, then a send pulse):
 *   1. frame 10: both drivers send it; every word is checked
 *   2. frame 11 arrives while both are still sending: both must skip it
 *      and the frame going out must not change
 *   3. frame 12 after both are idle: both send it correctly
 * The SPI receiver reads mosi on rising sck while cs_b is low; the UART
 * receiver reads 8N1 bytes and checks the checksum word.
 */
`timescale 1ns/1ps
module frame_tx_tb;
   logic        clk = 0, reset_b = 0;
   logic        we = 0, send = 0;
   logic [7:0]  waddr = 0, frame_num = 0;
   logic [31:0] wdata = 0;
   logic        sck, mosi, cs_b, tx;
   int          errors = 0;

   spi_frame_tx  #(.STAGE_SHIFT(1), .HALF_PERIOD(2))   u_spi  (.clk(clk), .reset_b(reset_b), .we(we), .waddr(waddr), .wdata(wdata), .send(send), .frame_num(frame_num), .sck(sck), .mosi(mosi), .cs_b(cs_b));
   uart_frame_tx #(.STAGE_SHIFT(1), .CLKS_PER_BIT(16)) u_uart (.clk(clk), .reset_b(reset_b), .we(we), .waddr(waddr), .wdata(wdata), .send(send), .frame_num(frame_num), .tx(tx));

   always #41.667 clk = ~clk;        // 12 MHz

   // the bins for frame f: re = f*1000 + k, im = -(k + 1)
   function automatic logic [15:0] expected(input int f, input int w);
      int k;
      if (w == 0) return 16'hA55A;
      if (w == 1) return {8'(f), 8'd1};
      k = (w - 2) / 2;
      return (w % 2 == 0) ? 16'(f * 1000 + k) : 16'(-(k + 1));
   endfunction

   task automatic write_frame(input int f);
      for (int k = 0; k < 256; k++) begin
         @(posedge clk); we <= 1; waddr <= 8'(k); wdata <= {16'(f * 1000 + k), 16'(-(k + 1))};
      end
      @(posedge clk); we <= 0; send <= 1; frame_num <= 8'(f);
      @(posedge clk); send <= 0;
   endtask

   // ---- SPI receiver ----
   logic [15:0] sh;
   int          sbits, swords, sframes, sframe_id [0:9];
   always @(negedge cs_b) begin sbits = 0; swords = 0; end
   always @(posedge sck) if (!cs_b) begin
      sh = {sh[14:0], mosi}; sbits++;
      if (sbits % 16 == 0) begin
         if (swords == 1) sframe_id[sframes] = sh[15:8];
         if (sh !== expected(swords == 0 ? 0 : int'(sframe_id[sframes]), swords)) begin
            errors++; $display("ERROR: spi frame %0d word %0d = %04h, expected %04h", sframes, swords, sh, expected(int'(sframe_id[sframes]), swords));
         end
         swords++;
      end
   end
   always @(posedge cs_b) if (reset_b) begin
      if (swords != 514) begin errors++; $display("ERROR: spi frame %0d had %0d words", sframes, swords); end
      sframes++;
   end

   // ---- UART receiver ----
   localparam real BIT_NS = 16 * 83.333;
   logic [7:0]  ub;
   logic [15:0] uw, usum;
   int          ubytes, uwords, uframes, uframe_id [0:9];
   always @(negedge tx) if (reset_b) begin
      #(BIT_NS * 1.5);
      for (int i = 0; i < 8; i++) begin ub[i] = tx; #(BIT_NS); end
      if (tx !== 1'b1) begin errors++; $display("ERROR: uart stop bit"); end
      if (ubytes % 2 == 0) uw[15:8] = ub;
      else begin
         uw[7:0] = ub;
         if (uwords == 1) uframe_id[uframes] = uw[15:8];
         if (uwords == 514) begin
            if (uw !== usum) begin errors++; $display("ERROR: uart frame %0d checksum %04h, expected %04h", uframes, uw, usum); end
            uframes++; uwords = -1;
         end else if (uw !== expected(uwords == 0 ? 0 : int'(uframe_id[uframes]), uwords)) begin
            errors++; $display("ERROR: uart frame %0d word %0d = %04h", uframes, uwords, uw);
         end
         if (uwords == 0) usum = 0; else if (uwords > 0) usum += uw;
         uwords++;
      end
      ubytes++;
   end

   initial begin
      sframes = 0; uframes = 0; ubytes = 0; uwords = 0;
      repeat (3) @(posedge clk); reset_b <= 1;
      write_frame(10);                   // 1. sent by both
      #(500us);                          // SPI still sending (2.9 ms), UART too (13.7 ms)
      write_frame(11);                   // 2. must be skipped by both
      wait (sframes == 1 && uframes == 1);
      #(1ms);
      write_frame(12);                   // 3. sent by both
      wait (sframes == 2 && uframes == 2);
      #(1ms);
      $display("spi frames: %0d (ids %0d, %0d), uart frames: %0d (ids %0d, %0d)", sframes, sframe_id[0], sframe_id[1], uframes, uframe_id[0], uframe_id[1]);
      if (sframe_id[0] != 10 || sframe_id[1] != 12 || uframe_id[0] != 10 || uframe_id[1] != 12 || sframes != 2 || uframes != 2) begin
         errors++; $display("ERROR: expected frames 10 and 12 on both, with 11 skipped");
      end
      if (errors == 0) $display("PASSED"); else $display("FAILED: %0d errors", errors);
      $finish;
   end
endmodule
