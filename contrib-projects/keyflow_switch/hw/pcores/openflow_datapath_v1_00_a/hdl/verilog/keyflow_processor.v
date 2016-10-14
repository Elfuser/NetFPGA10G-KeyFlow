/*******************************************************************************
 *
 *  NetFPGA-10G http://www.netfpga.org
 *
 *  File:
 *        keyflow_processor.v
 *
 *  Module:
 *        openflow_datapath
 *
 *  Author:
 *        Matheus de Souza
          matheussouza@get.inatel.br
 *
 *  Description:
 *        This module operates according to KeyFlow logic.
 *        It receives packets as AXI stream,
 *        updates fowarding bitmask from the remainder of division of packet label by switch key
 *        then forwards them to the next module as AXI stream.
 *
 *
 *
 *        This file is free code: you can redistribute it and/or modify it under
 *        the terms of the GNU Lesser General Public License version 2.1 as
 *        published by the Free Software Foundation.
 *
 *        This package is distributed in the hope that it will be useful, but
 *        WITHOUT ANY WARRANTY; without even the implied warranty of
 *        MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *        Lesser General Public License for more details.
 *
 *        You should have received a copy of the GNU Lesser General Public
 *        License along with the NetFPGA source package.  If not, see
 *        http://www.gnu.org/licenses/.
 *
 */

`timescale 1ns/1ps
`include "registers.v"

module keyflow_processor
#(
   // AXI Stream Data Width
   parameter C_AXIS_DATA_WIDTH = 64,
   parameter C_AXIS_TUSER_WIDTH=128,
   parameter C_AXIS_LEN_DATA_WIDTH=16,
   parameter C_AXIS_SPT_DATA_WIDTH=8,
   parameter C_AXIS_DPT_DATA_WIDTH=8,
   // Parameters for Flow Table interface
   parameter OPENFLOW_ACTION_SIZE = 320,
   // Parameters for divider interface	
	parameter DIVIDER_WIDTH = 16,
	parameter KEYFLOW_LOCAL_KEY = 5
)
(
   // AXI ports
   input asclk,
   input aresetn,

   // Slave AXI Stream Ports
   input [C_AXIS_DATA_WIDTH-1:0] s_axis_tdata,
   input [(C_AXIS_DATA_WIDTH/8)-1:0] s_axis_tstrb,
   input [C_AXIS_TUSER_WIDTH-1:0] s_axis_tuser,
   input  s_axis_tvalid,
   input  s_axis_tlast,
   output s_axis_tready,

   // interface with flow table
   input action_req,

	// Interface with Divider
	input [DIVIDER_WIDTH-1:0] dv_key,

   // Master AXI Stream Ports
   output [C_AXIS_DATA_WIDTH-1:0] m_axis_tdata,
   output [(C_AXIS_DATA_WIDTH/8)-1:0] m_axis_tstrb,
   output [C_AXIS_TUSER_WIDTH-1:0] m_axis_tuser,
   output reg  m_axis_tvalid,
   output reg  m_axis_tlast,
   input  m_axis_tready,

   // Debug register
   output reg [31:0] num_pkts_processed
);

   //-------------------- Internal Parameters ------------------------
	
	// Keyflow 
	localparam KEYFLOW_LOCK = 1;
	
   localparam FIFO_CTRL_WIDTH = 2;
   localparam FIFO_DATA_WIDTH = C_AXIS_DATA_WIDTH +
                                C_AXIS_DATA_WIDTH/8 +
                                FIFO_CTRL_WIDTH;

   localparam TUSER_LEN_POS = 0;
   localparam TUSER_SPT_POS = TUSER_LEN_POS
                            + C_AXIS_LEN_DATA_WIDTH;
   localparam TUSER_DPT_POS = TUSER_SPT_POS
                            + C_AXIS_SPT_DATA_WIDTH;

   // Data read state machine
   localparam NUM_DT_RD_STATES = 2;
   localparam DT_RD_1ST = 1,
              DT_RD_REST = 2;

   // DL state machine
   localparam NUM_DL_STATES = 2;
   localparam DL_HDR_1ST = 1,
              DL_THRU = 2;

   localparam NUM_TU_STATES = 2;
   localparam TU_WAIT_TVALID = 1,
              TU_WAIT_TLAST = 2;

   //------------------------ Wires/Regs -----------------------------
	
	// Forward bitmask for Keyflow logic.
	wire [`OPENFLOW_FORWARD_BITMASK_WIDTH-1:0] k_forward_bitmask;

   // Input buffer and peripheral
   reg fifo_rd_en;
   wire fifo_nearly_full;
   wire fifo_empty;
	wire pkt_buf_empty;

   reg tready_int;
	wire m_axis_tlast_int;
	wire m_axis_tvalid_dummy;

   // DATA read state machine
   reg [NUM_DT_RD_STATES-1:0] dt_rd_state, dt_rd_state_nxt;

   // Metadata handling
	reg mi_tuser_valid, mi_tuser_valid_nxt;
   reg  s_tuser_valid, s_tuser_valid_nxt;
   wire s_tuser_wr_en;
   wire [C_AXIS_TUSER_WIDTH-1:0] tx_user;
   wire [C_AXIS_TUSER_WIDTH-1:0] tx_user_1;
   reg tx_user_rd_en;
   reg [NUM_TU_STATES-1:0] s_tuser_state, s_tuser_state_nxt;

   wire m_fifo_empty;
   wire m_tuser_wr_en;
   reg m_tuser_rd_en;
   reg [NUM_TU_STATES-1:0] mi_tuser_state, mi_tuser_state_nxt;
	wire mt_rdIn_wtOut;
	
	// Divider 
	wire [DIVIDER_WIDTH-1:0] dv_rest;
	
	// Shift register 
	reg [DIVIDER_WIDTH-1:0] reg_tmp; 
	wire s_in, s_out;

   // Outgoing DATA read state machine
   reg [NUM_DT_RD_STATES-1:0] out_dt_rd_state, out_dt_rd_state_nxt;
	reg dl_out_wr, dl_out_wr_nxt;
	reg dl_out_last, dl_out_last_nxt;

   // Debug register
   reg [31:0] num_pkts_processed_nxt;
   //--------------------------- Logic -------------------------------
	
//	assign  dividend = dv_key;
	
	divider_core pipelined_dv (
	.clk(asclk), 						// input clk
	.ce(1'b1), 							// input ce
	.sclr(~aresetn), 					// input sclr
	.rfd(), 								// output rfd
	.dividend(dv_key), 				// input dividend
	.divisor(KEYFLOW_LOCAL_KEY),  // input divisor
	.quotient(), 						// output quotient
	.fractional(dv_rest)); 			// output rest
	
 
  // A valid divison go out from divider (DIVIDER_WIDTH) cycles after action_req transition
  // mt_rdIn_wtOut <<---(shift by DIVIDER_WIDTH)--< action_req
  
assign s_in = action_req;
assign mt_rdIn_wtOut = s_out;
  
  // Shift register for action_reg
always @(posedge asclk) begin 
	if(~(aresetn && KEYFLOW_LOCK)) begin
		reg_tmp = 0;
	end
   else begin  
		reg_tmp = reg_tmp << 1; 
      reg_tmp[0] = s_in; 
   end 
 end
assign s_out = reg_tmp[DIVIDER_WIDTH-1];  

// Bitmask for fowarding interface logic
assign k_forward_bitmask = (dv_rest == 1) ? 16'b0000000000000001 :  // MAC0
								  ((dv_rest == 2) ? 16'b0000000000000100 :  // MAC1
								  ((dv_rest == 3) ? 16'b0000000000010000 :  // MAC2
								  ((dv_rest == 4) ? 16'b0000000001000000 :  // MAC3
								  ((dv_rest == 5) ? 16'b0000000000000010 :  // CPU0
														  16'b0000000000000000))));  // Drop
														 
  
assign   tx_user_1[C_AXIS_TUSER_WIDTH-1:(TUSER_DPT_POS+C_AXIS_DPT_DATA_WIDTH)] = 
											tx_user[C_AXIS_TUSER_WIDTH-1:(TUSER_DPT_POS+C_AXIS_DPT_DATA_WIDTH)];
											
assign   tx_user_1[TUSER_DPT_POS +: C_AXIS_DPT_DATA_WIDTH] = k_forward_bitmask[C_AXIS_DPT_DATA_WIDTH-1:0];
						
assign   tx_user_1[TUSER_DPT_POS-1:0] = tx_user[TUSER_DPT_POS-1:0];


   //---Pkt/Tuser input_buf
	
   // Generate TUSER latching signal
   // TUSER is valid only at the first cycle of pkt reception
   always @(*) begin
      s_tuser_valid_nxt = s_tuser_valid;
      s_tuser_state_nxt = s_tuser_state;
      case (s_tuser_state)
         TU_WAIT_TVALID: begin
            if (s_axis_tvalid) begin
               s_tuser_valid_nxt = 0;
               s_tuser_state_nxt = TU_WAIT_TLAST;
            end
         end
         TU_WAIT_TLAST: begin
            if (s_axis_tlast) begin
               s_tuser_valid_nxt = 1;
               s_tuser_state_nxt = TU_WAIT_TVALID;
            end
         end
      endcase
   end

   always @(posedge asclk) begin
      if (~aresetn) begin
         s_tuser_valid <= 1;
         s_tuser_state <= TU_WAIT_TVALID;
      end
      else begin
         s_tuser_valid <= s_tuser_valid_nxt;
         s_tuser_state <= s_tuser_state_nxt;
      end
   end

   assign s_tuser_wr_en = s_axis_tvalid && s_tuser_valid;

   // Input FIFO for TUSER
   fallthrough_small_fifo
     #(.WIDTH(C_AXIS_TUSER_WIDTH), .MAX_DEPTH_BITS(4))
     input_metadata_buf
       (.din           (s_axis_tuser),
        .wr_en         (s_tuser_wr_en),
        .rd_en         (mt_rdIn_wtOut),
        .dout          (tx_user),
        .full          (),
        .prog_full     (),
        .nearly_full   (tx_user_nearly_full),
        .empty         (tx_user_empty),
        .reset         (~aresetn),
        .clk           (asclk)
        );
					
					
 // Output fifo handling 
 // start tranfering packet data when metadata_fifo is not empty
   always @(*) begin
      num_pkts_processed_nxt = num_pkts_processed;
		m_axis_tvalid = 0;
		m_axis_tlast = 0;
		m_tuser_rd_en = 0;
      out_dt_rd_state_nxt = out_dt_rd_state;
      case (out_dt_rd_state)
         DT_RD_1ST: begin
            if (~pkt_buf_empty && ~m_fifo_empty) begin
					m_axis_tvalid = 1;
					m_tuser_rd_en = 1;
               out_dt_rd_state_nxt = DT_RD_REST;
            end
         end
         DT_RD_REST: begin
            if (~pkt_buf_empty) begin
					m_axis_tvalid = 1;
               if (m_axis_tlast_int) begin
                  num_pkts_processed_nxt = num_pkts_processed+1;
                  m_axis_tlast = 1; 
                  out_dt_rd_state_nxt = DT_RD_1ST;
               end
            end
         end
      endcase
   end

   always @(posedge asclk) begin
      if (~aresetn) begin
         out_dt_rd_state <= DT_RD_1ST;
         num_pkts_processed <= 0;
      end
      else begin
         out_dt_rd_state <= out_dt_rd_state_nxt;
         num_pkts_processed <= num_pkts_processed_nxt;
      end
   end
	
	
   // Input/Output buffer for pkt
   fallthrough_small_fifo
     #(.WIDTH(FIFO_DATA_WIDTH), .MAX_DEPTH_BITS(4))
     output_fifo
       (.din          ({s_axis_tvalid, 
								s_axis_tlast,
                        s_axis_tstrb,
                        s_axis_tdata}),  // Data in
								
        .wr_en         ((s_axis_tvalid && s_axis_tready)),   // Write enable
        .rd_en         (m_tdata_rd_en),
        .dout          ({m_axis_tvalid_dummy, // Should always be 1
                         m_axis_tlast_int,
                         m_axis_tstrb,
                         m_axis_tdata}),
        .full          (pkt_buf_drop),
        .prog_full     (),
        .nearly_full   (fifo_nearly_full),
        .empty         (pkt_buf_empty),
        .reset         (~aresetn),
        .clk           (asclk)
        );

   assign s_axis_tready = (~fifo_nearly_full);
	 
 //  assign m_axis_tvalid = ~pkt_buf_empty;
	assign m_tdata_rd_en = ~pkt_buf_empty && m_axis_tvalid && m_axis_tready;


   // Output buffer for TUSER  
   always @(*) begin
      mi_tuser_valid_nxt = mi_tuser_valid;
      mi_tuser_state_nxt = mi_tuser_state;
      case (mi_tuser_state)
         TU_WAIT_TVALID: begin
            if (dl_out_wr) begin
               mi_tuser_valid_nxt = 0;
               mi_tuser_state_nxt = TU_WAIT_TLAST;
            end
         end
         TU_WAIT_TLAST: begin
            if (dl_out_wr && dl_out_last) begin
               mi_tuser_valid_nxt = 1;
               mi_tuser_state_nxt = TU_WAIT_TVALID;
            end
         end
      endcase
   end

   always @(posedge asclk) begin
      if (~aresetn) begin
         mi_tuser_valid <= 1;
         mi_tuser_state <= TU_WAIT_TVALID;
      end
      else begin
         mi_tuser_valid <= mi_tuser_valid_nxt;
         mi_tuser_state <= mi_tuser_state_nxt;
      end
   end

   assign m_tuser_wr_en = dl_out_wr && mi_tuser_valid;
	
   fallthrough_small_fifo
     #(.WIDTH(C_AXIS_TUSER_WIDTH), .MAX_DEPTH_BITS(4))
     output_metadata_fifo
       (.din           (tx_user_1),
        .wr_en         (mt_rdIn_wtOut),   // Write enable        
		  .rd_en         (m_tuser_rd_en),
        .dout          (m_axis_tuser),
        .full          (),
        .prog_full     (),
        .nearly_full   (),
        .empty         (m_fifo_empty),
        .reset         (~aresetn),
        .clk           (asclk)
        );
	
endmodule
