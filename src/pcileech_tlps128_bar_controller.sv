//
// PCILeech FPGA.
//
// PCIe BAR PIO controller.
//
// The PCILeech BAR PIO controller allows for easy user-implementation on top
// of the PCILeech AXIS128 PCIe TLP streaming interface.
// The controller consists of a read engine and a write engine and pluggable
// user-implemented PCIe BAR implementations (found at bottom of the file).
//
// Considerations:
// - The core handles 1 DWORD read + 1 DWORD write per CLK max. If a lot of
//   data is written / read from the TLP streaming interface the core may
//   drop packet silently.
// - The core reads 1 DWORD of data (without byte enable) per CLK.
// - The core writes 1 DWORD of data (with byte enable) per CLK.
// - All user-implemented cores must have the same latency in CLKs for the
//   returned read data or else undefined behavior will take place.
// - 32-bit addresses are passed for read/writes. Larger BARs than 4GB are
//   not supported due to addressing constraints. Lower bits (LSBs) are the
//   BAR offset, Higher bits (MSBs) are the 32-bit base address of the BAR.
// - DO NOT edit read/write engines.
// - DO edit pcileech_tlps128_bar_controller (to swap bar implementations).
// - DO edit the bar implementations (at bottom of the file, if neccessary).
//
// Example implementations exists below, swap out any of the example cores
// against a core of your use case, or modify existing cores.
// Following test cores exist (see below in this file):
// - pcileech_bar_impl_zerowrite4k = zero-initialized read/write BAR.
//     It's possible to modify contents by use of .coe file.
// - pcileech_bar_impl_loopaddr = test core that loops back the 32-bit
//     address of the current read. Does not support writes.
// - pcileech_bar_impl_none = core without any reply.
// 
// (c) Ulf Frisk, 2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_tlps128_bar_controller(
    input                   rst,
    input                   clk,
    input                   bar_en,
    input [15:0]            pcie_id,
    input [31:0]            base_address_register,
    IfAXIS128.sink_lite     tlps_in,
    IfAXIS128.source        tlps_out
);
    
    // ------------------------------------------------------------------------
    // 1: TLP RECEIVE:
    // Receive incoming BAR requests from the TLP stream:
    // send them onwards to read and write FIFOs
    // ------------------------------------------------------------------------
    wire in_is_wr_ready;
    bit  in_is_wr_last;
    wire in_is_first    = tlps_in.tuser[0];
    wire in_is_bar      = bar_en && (tlps_in.tuser[8:2] != 0);
    wire in_is_rd       = (in_is_first && tlps_in.tlast && ((tlps_in.tdata[31:25] == 7'b0000000) || (tlps_in.tdata[31:25] == 7'b0010000) || (tlps_in.tdata[31:24] == 8'b00000010)));
    wire in_is_wr       = in_is_wr_last || (in_is_first && in_is_wr_ready && ((tlps_in.tdata[31:25] == 7'b0100000) || (tlps_in.tdata[31:25] == 7'b0110000) || (tlps_in.tdata[31:24] == 8'b01000010)));
    
    always @ ( posedge clk )
        if ( rst ) begin
            in_is_wr_last <= 0;
        end
        else if ( tlps_in.tvalid ) begin
            in_is_wr_last <= !tlps_in.tlast && in_is_wr;
        end
    
    wire [6:0]  wr_bar;
    wire [31:0] wr_addr;
    wire [3:0]  wr_be;
    wire [31:0] wr_data;
    wire        wr_valid;
    wire [87:0] rd_req_ctx;
    wire [6:0]  rd_req_bar;
    wire [31:0] rd_req_addr;
    wire        rd_req_valid;
    wire [87:0] rd_rsp_ctx;
    wire [31:0] rd_rsp_data;
    wire        rd_rsp_valid;
        
    pcileech_tlps128_bar_rdengine i_pcileech_tlps128_bar_rdengine(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        // TLPs:
        .pcie_id        ( pcie_id                       ),
        .tlps_in        ( tlps_in                       ),
        .tlps_in_valid  ( tlps_in.tvalid && in_is_bar && in_is_rd ),
        .tlps_out       ( tlps_out                      ),
        // BAR reads:
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_bar     ( rd_req_bar                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid                  ),
        .rd_rsp_ctx     ( rd_rsp_ctx                    ),
        .rd_rsp_data    ( rd_rsp_data                   ),
        .rd_rsp_valid   ( rd_rsp_valid                  )
    );

    pcileech_tlps128_bar_wrengine i_pcileech_tlps128_bar_wrengine(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        // TLPs:
        .tlps_in        ( tlps_in                       ),
        .tlps_in_valid  ( tlps_in.tvalid && in_is_bar && in_is_wr ),
        .tlps_in_ready  ( in_is_wr_ready                ),
        // outgoing BAR writes:
        .wr_bar         ( wr_bar                        ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid                      )
    );
    
    wire [87:0] bar_rsp_ctx[7];
    wire [31:0] bar_rsp_data[7];
    wire        bar_rsp_valid[7];
    
    assign rd_rsp_ctx = bar_rsp_valid[0] ? bar_rsp_ctx[0] :
                        bar_rsp_valid[1] ? bar_rsp_ctx[1] :
                        bar_rsp_valid[2] ? bar_rsp_ctx[2] :
                        bar_rsp_valid[3] ? bar_rsp_ctx[3] :
                        bar_rsp_valid[4] ? bar_rsp_ctx[4] :
                        bar_rsp_valid[5] ? bar_rsp_ctx[5] :
                        bar_rsp_valid[6] ? bar_rsp_ctx[6] : 0;
    assign rd_rsp_data = bar_rsp_valid[0] ? bar_rsp_data[0] :
                        bar_rsp_valid[1] ? bar_rsp_data[1] :
                        bar_rsp_valid[2] ? bar_rsp_data[2] :
                        bar_rsp_valid[3] ? bar_rsp_data[3] :
                        bar_rsp_valid[4] ? bar_rsp_data[4] :
                        bar_rsp_valid[5] ? bar_rsp_data[5] :
                        bar_rsp_valid[6] ? bar_rsp_data[6] : 0;
    assign rd_rsp_valid = bar_rsp_valid[0] || bar_rsp_valid[1] || bar_rsp_valid[2] || bar_rsp_valid[3] || bar_rsp_valid[4] || bar_rsp_valid[5] || bar_rsp_valid[6];
    
    pcileech_bar_impl_e1000e i_bar0(
        .rst                   ( rst                           ),
        .clk                   ( clk                           ),
        .wr_addr               ( wr_addr                       ),
        .wr_be                 ( wr_be                         ),
        .wr_data               ( wr_data                       ),
        .wr_valid              ( wr_valid && wr_bar[0]         ),
        .rd_req_ctx            ( rd_req_ctx                    ),
        .rd_req_addr           ( rd_req_addr                   ),
        .rd_req_valid          ( rd_req_valid && rd_req_bar[0] ),
        .base_address_register ( base_address_register         ),
        .rd_rsp_ctx            ( bar_rsp_ctx[0]                ),
        .rd_rsp_data           ( bar_rsp_data[0]               ),
        .rd_rsp_valid          ( bar_rsp_valid[0]              )
    );
    
    pcileech_bar_impl_loopaddr i_bar1(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[1]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[1] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[1]                ),
        .rd_rsp_data    ( bar_rsp_data[1]               ),
        .rd_rsp_valid   ( bar_rsp_valid[1]              )
    );
    
    pcileech_bar_impl_none i_bar2(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[2]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[2] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[2]                ),
        .rd_rsp_data    ( bar_rsp_data[2]               ),
        .rd_rsp_valid   ( bar_rsp_valid[2]              )
    );
    
    pcileech_bar_impl_none i_bar3(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[3]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[3] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[3]                ),
        .rd_rsp_data    ( bar_rsp_data[3]               ),
        .rd_rsp_valid   ( bar_rsp_valid[3]              )
    );
    
    pcileech_bar_impl_none i_bar4(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[4]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[4] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[4]                ),
        .rd_rsp_data    ( bar_rsp_data[4]               ),
        .rd_rsp_valid   ( bar_rsp_valid[4]              )
    );
    
    pcileech_bar_impl_none i_bar5(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[5]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[5] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[5]                ),
        .rd_rsp_data    ( bar_rsp_data[5]               ),
        .rd_rsp_valid   ( bar_rsp_valid[5]              )
    );
    
    pcileech_bar_impl_none i_bar6_optrom(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[6]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[6] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[6]                ),
        .rd_rsp_data    ( bar_rsp_data[6]               ),
        .rd_rsp_valid   ( bar_rsp_valid[6]              )
    );


endmodule



// ------------------------------------------------------------------------
// BAR WRITE ENGINE:
// Receives BAR WRITE TLPs and output BAR WRITE requests.
// Holds a 2048-byte buffer.
// Input flow rate is 16bytes/CLK (max).
// Output flow rate is 4bytes/CLK.
// If write engine overflows incoming TLP is completely discarded silently.
// ------------------------------------------------------------------------
module pcileech_tlps128_bar_wrengine(
    input                   rst,    
    input                   clk,
    // TLPs:
    IfAXIS128.sink_lite     tlps_in,
    input                   tlps_in_valid,
    output                  tlps_in_ready,
    // outgoing BAR writes:
    output bit [6:0]        wr_bar,
    output bit [31:0]       wr_addr,
    output bit [3:0]        wr_be,
    output bit [31:0]       wr_data,
    output bit              wr_valid
);

    wire            f_rd_en;
    wire [127:0]    f_tdata;
    wire [3:0]      f_tkeepdw;
    wire [8:0]      f_tuser;
    wire            f_tvalid;
    
    bit [127:0]     tdata;
    bit [3:0]       tkeepdw;
    bit             tlast;
    
    bit [3:0]       be_first;
    bit [3:0]       be_last;
    bit             first_dw;
    bit [31:0]      addr;

    fifo_141_141_clk1_bar_wr i_fifo_141_141_clk1_bar_wr(
        .srst           ( rst                           ),
        .clk            ( clk                           ),
        .wr_en          ( tlps_in_valid                 ),
        .din            ( {tlps_in.tuser[8:0], tlps_in.tkeepdw, tlps_in.tdata} ),
        .full           (                               ),
        .prog_empty     ( tlps_in_ready                 ),
        .rd_en          ( f_rd_en                       ),
        .dout           ( {f_tuser, f_tkeepdw, f_tdata} ),    
        .empty          (                               ),
        .valid          ( f_tvalid                      )
    );
    
    // STATE MACHINE:
    `define S_ENGINE_IDLE        3'h0
    `define S_ENGINE_FIRST       3'h1
    `define S_ENGINE_4DW_REQDATA 3'h2
    `define S_ENGINE_TX0         3'h4
    `define S_ENGINE_TX1         3'h5
    `define S_ENGINE_TX2         3'h6
    `define S_ENGINE_TX3         3'h7
    (* KEEP = "TRUE" *) bit [3:0] state = `S_ENGINE_IDLE;
    
    assign f_rd_en = (state == `S_ENGINE_IDLE) ||
                     (state == `S_ENGINE_4DW_REQDATA) ||
                     (state == `S_ENGINE_TX3) ||
                     ((state == `S_ENGINE_TX2 && !tkeepdw[3])) ||
                     ((state == `S_ENGINE_TX1 && !tkeepdw[2])) ||
                     ((state == `S_ENGINE_TX0 && !f_tkeepdw[1]));

    always @ ( posedge clk ) begin
        wr_addr     <= addr;
        wr_valid    <= ((state == `S_ENGINE_TX0) && f_tvalid) || (state == `S_ENGINE_TX1) || (state == `S_ENGINE_TX2) || (state == `S_ENGINE_TX3);
        
    end

    always @ ( posedge clk )
        if ( rst ) begin
            state <= `S_ENGINE_IDLE;
        end
        else case ( state )
            `S_ENGINE_IDLE: begin
                state   <= `S_ENGINE_FIRST;
            end
            `S_ENGINE_FIRST: begin
                if ( f_tvalid && f_tuser[0] ) begin
                    wr_bar      <= f_tuser[8:2];
                    tdata       <= f_tdata;
                    tkeepdw     <= f_tkeepdw;
                    tlast       <= f_tuser[1];
                    first_dw    <= 1;
                    be_first    <= f_tdata[35:32];
                    be_last     <= f_tdata[39:36];
                    if ( f_tdata[31:29] == 8'b010 ) begin       // 3 DW header, with data
                        addr    <= { f_tdata[95:66], 2'b00 };
                        state   <= `S_ENGINE_TX3;
                    end
                    else if ( f_tdata[31:29] == 8'b011 ) begin  // 4 DW header, with data
                        addr    <= { f_tdata[127:98], 2'b00 };
                        state   <= `S_ENGINE_4DW_REQDATA;
                    end 
                end
                else begin
                    state   <= `S_ENGINE_IDLE;
                end
            end 
            `S_ENGINE_4DW_REQDATA: begin
                state   <= `S_ENGINE_TX0;
            end
            `S_ENGINE_TX0: begin
                tdata       <= f_tdata;
                tkeepdw     <= f_tkeepdw;
                tlast       <= f_tuser[1];
                addr        <= addr + 4;
                wr_data     <= { f_tdata[0+00+:8], f_tdata[0+08+:8], f_tdata[0+16+:8], f_tdata[0+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (f_tkeepdw[1] ? 4'hf : be_last);
                state       <= f_tvalid ? (f_tkeepdw[1] ? `S_ENGINE_TX1 : `S_ENGINE_FIRST) : `S_ENGINE_IDLE;
            end
            `S_ENGINE_TX1: begin
                addr        <= addr + 4;
                wr_data     <= { tdata[32+00+:8], tdata[32+08+:8], tdata[32+16+:8], tdata[32+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (tkeepdw[2] ? 4'hf : be_last);
                state       <= tkeepdw[2] ? `S_ENGINE_TX2 : `S_ENGINE_FIRST;
            end
            `S_ENGINE_TX2: begin
                addr        <= addr + 4;
                wr_data     <= { tdata[64+00+:8], tdata[64+08+:8], tdata[64+16+:8], tdata[64+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (tkeepdw[3] ? 4'hf : be_last);
                state       <= tkeepdw[3] ? `S_ENGINE_TX3 : `S_ENGINE_FIRST;
            end
            `S_ENGINE_TX3: begin
                addr        <= addr + 4;
                wr_data     <= { tdata[96+00+:8], tdata[96+08+:8], tdata[96+16+:8], tdata[96+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (!tlast ? 4'hf : be_last);
                state       <= !tlast ? `S_ENGINE_TX0 : `S_ENGINE_FIRST;
            end
        endcase

endmodule



// ------------------------------------------------------------------------
// BAR READ ENGINE:
// Receives BAR READ TLPs and output BAR READ requests.
// ------------------------------------------------------------------------
module pcileech_tlps128_bar_rdengine(
    input                   rst,    
    input                   clk,
    // TLPs:
    input [15:0]            pcie_id,
    IfAXIS128.sink_lite     tlps_in,
    input                   tlps_in_valid,
    IfAXIS128.source        tlps_out,
    // BAR reads:
    output [87:0]           rd_req_ctx,
    output [6:0]            rd_req_bar,
    output [31:0]           rd_req_addr,
    output                  rd_req_valid,
    input  [87:0]           rd_rsp_ctx,
    input  [31:0]           rd_rsp_data,
    input                   rd_rsp_valid
);

    // ------------------------------------------------------------------------
    // 1: PROCESS AND QUEUE INCOMING READ TLPs:
    // ------------------------------------------------------------------------
    wire [10:0] rd1_in_dwlen    = (tlps_in.tdata[9:0] == 0) ? 11'd1024 : {1'b0, tlps_in.tdata[9:0]};
    wire [6:0]  rd1_in_bar      = tlps_in.tuser[8:2];
    wire [15:0] rd1_in_reqid    = tlps_in.tdata[63:48];
    wire [7:0]  rd1_in_tag      = tlps_in.tdata[47:40];
    wire [31:0] rd1_in_addr     = { ((tlps_in.tdata[31:29] == 3'b000) ? tlps_in.tdata[95:66] : tlps_in.tdata[127:98]), 2'b00 };
    wire [73:0] rd1_in_data;
    assign rd1_in_data[73:63]   = rd1_in_dwlen;
    assign rd1_in_data[62:56]   = rd1_in_bar;   
    assign rd1_in_data[55:48]   = rd1_in_tag;
    assign rd1_in_data[47:32]   = rd1_in_reqid;
    assign rd1_in_data[31:0]    = rd1_in_addr;
    
    wire        rd1_out_rden;
    wire [73:0] rd1_out_data;
    wire        rd1_out_valid;
    
    fifo_74_74_clk1_bar_rd1 i_fifo_74_74_clk1_bar_rd1(
        .srst           ( rst                           ),
        .clk            ( clk                           ),
        .wr_en          ( tlps_in_valid                 ),
        .din            ( rd1_in_data                   ),
        .full           (                               ),
        .rd_en          ( rd1_out_rden                  ),
        .dout           ( rd1_out_data                  ),    
        .empty          (                               ),
        .valid          ( rd1_out_valid                 )
    );
    
    // ------------------------------------------------------------------------
    // 2: PROCESS AND SPLIT READ TLPs INTO RESPONSE TLP READ REQUESTS AND QUEUE:
    //    (READ REQUESTS LARGER THAN 128-BYTES WILL BE SPLIT INTO MULTIPLE).
    // ------------------------------------------------------------------------
    
    wire [10:0] rd1_out_dwlen       = rd1_out_data[73:63];
    wire [4:0]  rd1_out_dwlen5      = rd1_out_data[67:63];
    wire [4:0]  rd1_out_addr5       = rd1_out_data[6:2];
    
    // 1st "instant" packet:
    wire [4:0]  rd2_pkt1_dwlen_pre  = ((rd1_out_addr5 + rd1_out_dwlen5 > 6'h20) || ((rd1_out_addr5 != 0) && (rd1_out_dwlen5 == 0))) ? (6'h20 - rd1_out_addr5) : rd1_out_dwlen5;
    wire [5:0]  rd2_pkt1_dwlen      = (rd2_pkt1_dwlen_pre == 0) ? 6'h20 : rd2_pkt1_dwlen_pre;
    wire [10:0] rd2_pkt1_dwlen_next = rd1_out_dwlen - rd2_pkt1_dwlen;
    wire        rd2_pkt1_large      = (rd1_out_dwlen > 32) || (rd1_out_dwlen != rd2_pkt1_dwlen);
    wire        rd2_pkt1_tiny       = (rd1_out_dwlen == 1);
    wire [11:0] rd2_pkt1_bc         = rd1_out_dwlen << 2;
    wire [85:0] rd2_pkt1;
    assign      rd2_pkt1[85:74]     = rd2_pkt1_bc;
    assign      rd2_pkt1[73:63]     = rd2_pkt1_dwlen;
    assign      rd2_pkt1[62:0]      = rd1_out_data[62:0];
    
    // Nth packet (if split should take place):
    bit  [10:0] rd2_total_dwlen;
    wire [10:0] rd2_total_dwlen_next = rd2_total_dwlen - 11'h20;
    
    bit  [85:0] rd2_pkt2;
    wire [10:0] rd2_pkt2_dwlen = rd2_pkt2[73:63];
    wire        rd2_pkt2_large = (rd2_total_dwlen > 11'h20);
    
    wire        rd2_out_rden;
    
    // STATE MACHINE:
    `define S2_ENGINE_REQDATA     1'h0
    `define S2_ENGINE_PROCESSING  1'h1
    (* KEEP = "TRUE" *) bit [0:0] state2 = `S2_ENGINE_REQDATA;
    
    always @ ( posedge clk )
        if ( rst ) begin
            state2 <= `S2_ENGINE_REQDATA;
        end
        else case ( state2 )
            `S2_ENGINE_REQDATA: begin
                if ( rd1_out_valid && rd2_pkt1_large ) begin
                    rd2_total_dwlen <= rd2_pkt1_dwlen_next;                             // dwlen (total remaining)
                    rd2_pkt2[85:74] <= rd2_pkt1_dwlen_next << 2;                        // byte-count
                    rd2_pkt2[73:63] <= (rd2_pkt1_dwlen_next > 11'h20) ? 11'h20 : rd2_pkt1_dwlen_next;   // dwlen next
                    rd2_pkt2[62:12] <= rd1_out_data[62:12];                             // various data
                    rd2_pkt2[11:0]  <= rd1_out_data[11:0] + (rd2_pkt1_dwlen << 2);      // base address (within 4k page)
                    state2 <= `S2_ENGINE_PROCESSING;
                end
            end
            `S2_ENGINE_PROCESSING: begin
                if ( rd2_out_rden ) begin
                    rd2_total_dwlen <= rd2_total_dwlen_next;                                // dwlen (total remaining)
                    rd2_pkt2[85:74] <= rd2_total_dwlen_next << 2;                           // byte-count
                    rd2_pkt2[73:63] <= (rd2_total_dwlen_next > 11'h20) ? 11'h20 : rd2_total_dwlen_next;   // dwlen next
                    rd2_pkt2[62:12] <= rd2_pkt2[62:12];                                     // various data
                    rd2_pkt2[11:0]  <= rd2_pkt2[11:0] + (rd2_pkt2_dwlen << 2);              // base address (within 4k page)
                    if ( !rd2_pkt2_large ) begin
                        state2 <= `S2_ENGINE_REQDATA;
                    end
                end
            end
        endcase
    
    assign rd1_out_rden = rd2_out_rden && (((state2 == `S2_ENGINE_REQDATA) && (!rd1_out_valid || rd2_pkt1_tiny)) || ((state2 == `S2_ENGINE_PROCESSING) && !rd2_pkt2_large));

    wire [85:0] rd2_in_data  = (state2 == `S2_ENGINE_REQDATA) ? rd2_pkt1 : rd2_pkt2;
    wire        rd2_in_valid = rd1_out_valid || ((state2 == `S2_ENGINE_PROCESSING) && rd2_out_rden);

    bit  [85:0] rd2_out_data;
    bit         rd2_out_valid;
    always @ ( posedge clk ) begin
        rd2_out_data    <= rd2_in_valid ? rd2_in_data : rd2_out_data;
        rd2_out_valid   <= rd2_in_valid && !rst;
    end

    // ------------------------------------------------------------------------
    // 3: PROCESS EACH READ REQUEST PACKAGE PER INDIVIDUAL 32-bit READ DWORDS:
    // ------------------------------------------------------------------------

    wire [4:0]  rd2_out_dwlen   = rd2_out_data[67:63];
    wire        rd2_out_last    = (rd2_out_dwlen == 1);
    wire [9:0]  rd2_out_dwaddr  = rd2_out_data[11:2];
    
    wire        rd3_enable;
    
    bit         rd3_process_valid;
    bit         rd3_process_first;
    bit         rd3_process_last;
    bit [4:0]   rd3_process_dwlen;
    bit [9:0]   rd3_process_dwaddr;
    bit [85:0]  rd3_process_data;
    wire        rd3_process_next_last = (rd3_process_dwlen == 2);
    wire        rd3_process_nextnext_last = (rd3_process_dwlen <= 3);
    
    assign rd_req_ctx   = { rd3_process_first, rd3_process_last, rd3_process_data };
    assign rd_req_bar   = rd3_process_data[62:56];
    assign rd_req_addr  = { rd3_process_data[31:12], rd3_process_dwaddr, 2'b00 };
    assign rd_req_valid = rd3_process_valid;
    
    // STATE MACHINE:
    `define S3_ENGINE_REQDATA     1'h0
    `define S3_ENGINE_PROCESSING  1'h1
    (* KEEP = "TRUE" *) bit [0:0] state3 = `S3_ENGINE_REQDATA;
    
    always @ ( posedge clk )
        if ( rst ) begin
            rd3_process_valid   <= 1'b0;
            state3              <= `S3_ENGINE_REQDATA;
        end
        else case ( state3 )
            `S3_ENGINE_REQDATA: begin
                if ( rd2_out_valid ) begin
                    rd3_process_valid       <= 1'b1;
                    rd3_process_first       <= 1'b1;                    // FIRST
                    rd3_process_last        <= rd2_out_last;            // LAST (low 5 bits of dwlen == 1, [max pktlen = 0x20))
                    rd3_process_dwlen       <= rd2_out_dwlen;           // PKT LENGTH IN DW
                    rd3_process_dwaddr      <= rd2_out_dwaddr;          // DWADDR OF THIS DWORD
                    rd3_process_data[85:0]  <= rd2_out_data[85:0];      // FORWARD / SAVE DATA
                    if ( !rd2_out_last ) begin
                        state3 <= `S3_ENGINE_PROCESSING;
                    end
                end
                else begin
                    rd3_process_valid       <= 1'b0;
                end
            end
            `S3_ENGINE_PROCESSING: begin
                rd3_process_first           <= 1'b0;                    // FIRST
                rd3_process_last            <= rd3_process_next_last;   // LAST
                rd3_process_dwlen           <= rd3_process_dwlen - 1;   // LEN DEC
                rd3_process_dwaddr          <= rd3_process_dwaddr + 1;  // ADDR INC
                if ( rd3_process_next_last ) begin
                    state3 <= `S3_ENGINE_REQDATA;
                end
            end
        endcase

    assign rd2_out_rden = rd3_enable && (
        ((state3 == `S3_ENGINE_REQDATA) && (!rd2_out_valid || rd2_out_last)) ||
        ((state3 == `S3_ENGINE_PROCESSING) && rd3_process_nextnext_last));
    
    // ------------------------------------------------------------------------
    // 4: PROCESS RESPONSES:
    // ------------------------------------------------------------------------
    
    wire        rd_rsp_first    = rd_rsp_ctx[87];
    wire        rd_rsp_last     = rd_rsp_ctx[86];
    
    wire [9:0]  rd_rsp_dwlen    = rd_rsp_ctx[72:63];
    wire [11:0] rd_rsp_bc       = rd_rsp_ctx[85:74];
    wire [15:0] rd_rsp_reqid    = rd_rsp_ctx[47:32];
    wire [7:0]  rd_rsp_tag      = rd_rsp_ctx[55:48];
    wire [6:0]  rd_rsp_lowaddr  = rd_rsp_ctx[6:0];
    wire [31:0] rd_rsp_addr     = rd_rsp_ctx[31:0];
    wire [31:0] rd_rsp_data_bs  = { rd_rsp_data[7:0], rd_rsp_data[15:8], rd_rsp_data[23:16], rd_rsp_data[31:24] };
    
    // 1: 32-bit -> 128-bit state machine:
    bit [127:0] tdata;
    bit [3:0]   tkeepdw = 0;
    bit         tlast;
    bit         first   = 1;
    wire        tvalid  = tlast || tkeepdw[3];
    
    always @ ( posedge clk )
        if ( rst ) begin
            tkeepdw <= 0;
            tlast   <= 0;
            first   <= 0;
        end
        else if ( rd_rsp_valid && rd_rsp_first ) begin
            tkeepdw         <= 4'b1111;
            tlast           <= rd_rsp_last;
            first           <= 1'b1;
            tdata[31:0]     <= { 22'b0100101000000000000000, rd_rsp_dwlen };            // format, type, length
            tdata[63:32]    <= { pcie_id[7:0], pcie_id[15:8], 4'b0, rd_rsp_bc };        // pcie_id, byte_count
            tdata[95:64]    <= { rd_rsp_reqid, rd_rsp_tag, 1'b0, rd_rsp_lowaddr };      // req_id, tag, lower_addr
            tdata[127:96]   <= rd_rsp_data_bs;
        end
        else begin
            tlast   <= rd_rsp_valid && rd_rsp_last;
            tkeepdw <= tvalid ? (rd_rsp_valid ? 4'b0001 : 4'b0000) : (rd_rsp_valid ? ((tkeepdw << 1) | 1'b1) : tkeepdw);
            first   <= 0;
            if ( rd_rsp_valid ) begin
                if ( tvalid || !tkeepdw[0] )
                    tdata[31:0]   <= rd_rsp_data_bs;
                if ( !tkeepdw[1] )
                    tdata[63:32]  <= rd_rsp_data_bs;
                if ( !tkeepdw[2] )
                    tdata[95:64]  <= rd_rsp_data_bs;
                if ( !tkeepdw[3] )
                    tdata[127:96] <= rd_rsp_data_bs;   
            end
        end
    
    // 2.1 - submit to output fifo - will feed into mux/pcie core.
    fifo_134_134_clk1_bar_rdrsp i_fifo_134_134_clk1_bar_rdrsp(
        .srst           ( rst                       ),
        .clk            ( clk                       ),
        .din            ( { first, tlast, tkeepdw, tdata } ),
        .wr_en          ( tvalid                    ),
        .rd_en          ( tlps_out.tready           ),
        .dout           ( { tlps_out.tuser[0], tlps_out.tlast, tlps_out.tkeepdw, tlps_out.tdata } ),
        .full           (                           ),
        .empty          (                           ),
        .prog_empty     ( rd3_enable                ),
        .valid          ( tlps_out.tvalid           )
    );
    
    assign tlps_out.tuser[1] = tlps_out.tlast;
    assign tlps_out.tuser[8:2] = 0;
    
    // 2.2 - packet count:
    bit [10:0]  pkt_count       = 0;
    wire        pkt_count_dec   = tlps_out.tvalid && tlps_out.tlast;
    wire        pkt_count_inc   = tvalid && tlast;
    wire [10:0] pkt_count_next  = pkt_count + pkt_count_inc - pkt_count_dec;
    assign tlps_out.has_data    = (pkt_count_next > 0);
    
    always @ ( posedge clk ) begin
        pkt_count <= rst ? 0 : pkt_count_next;
    end

endmodule



// ------------------------------------------------------------------------
// Example BAR implementation that does nothing but drop any read/writes
// silently without generating a response.
// This is only recommended for placeholder designs.
// Latency = N/A.
// ------------------------------------------------------------------------
module pcileech_bar_impl_none(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);

    initial rd_rsp_ctx = 0;
    initial rd_rsp_data = 0;
    initial rd_rsp_valid = 0;

endmodule



// ------------------------------------------------------------------------
// Example BAR implementation of "address loopback" which can be useful
// for testing. Any read to a specific BAR address will result in the
// address as response.
// Latency = 2CLKs.
// ------------------------------------------------------------------------
module pcileech_bar_impl_loopaddr(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input [87:0]        rd_req_ctx,
    input [31:0]        rd_req_addr,
    input               rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);

    bit [87:0]      rd_req_ctx_1;
    bit [31:0]      rd_req_addr_1;
    bit             rd_req_valid_1;
    
    always @ ( posedge clk ) begin
        rd_req_ctx_1    <= rd_req_ctx;
        rd_req_addr_1   <= rd_req_addr;
        rd_req_valid_1  <= rd_req_valid;
        rd_rsp_ctx      <= rd_req_ctx_1;
        rd_rsp_data     <= rd_req_addr_1;
        rd_rsp_valid    <= rd_req_valid_1;
    end    

endmodule



// ------------------------------------------------------------------------
// Example BAR implementation of a 4kB writable initial-zero BAR.
// Latency = 2CLKs.
// ------------------------------------------------------------------------
module pcileech_bar_impl_zerowrite4k(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);

    bit [87:0]  drd_req_ctx;
    bit         drd_req_valid;
    wire [31:0] doutb;
    
    always @ ( posedge clk ) begin
        drd_req_ctx     <= rd_req_ctx;
        drd_req_valid   <= rd_req_valid;
        rd_rsp_ctx      <= drd_req_ctx;
        rd_rsp_valid    <= drd_req_valid;
        rd_rsp_data     <= doutb; 
    end
    
    bram_bar_zero4k i_bram_bar_zero4k(
        // Port A - write:
        .addra  ( wr_addr[11:2]     ),
        .clka   ( clk               ),
        .dina   ( wr_data           ),
        .ena    ( wr_valid          ),
        .wea    ( wr_be             ),
        // Port A - read (2 CLK latency):
        .addrb  ( rd_req_addr[11:2] ),
        .clkb   ( clk               ),
        .doutb  ( doutb             ),
        .enb    ( rd_req_valid      )
    );

endmodule



// ------------------------------------------------------------------------
// pcileech Intel PRO/1000 PT (82572EI / e1000e family) BAR implementation
// Emulates the MMIO register space of an Intel 82572EI Gigabit Ethernet
// Controller (PRO/1000 PT Desktop Adapter, DID 0x107D, VID 0x8086).
// Registers required by the e1000e (Linux) / e1e6032 (Windows) drivers are
// implemented with read/write storage; all other addresses read 0 and
// ignore writes (like reserved registers on real silicon).
// Link status is forced UP (STATUS.LU + PHY BMSR bit2) so the driver probes
// and initializes cleanly. DMA ring registers are stored but actual DMA
// transfers are performed by the PCILeech TLP engine, not by this core.
// Latency = 2 CLKs (same as the other bar implementations).
// ------------------------------------------------------------------------
module pcileech_bar_impl_e1000e(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    input  [31:0]       base_address_register,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);

    // 1 CLK input pipeline (matches latency of the other bar impls):
    bit [87:0]      drd_req_ctx;
    bit [31:0]      drd_req_addr;
    bit             drd_req_valid;
    bit [31:0]      dwr_addr;
    bit [31:0]      dwr_data;
    bit [3:0]       dwr_be;
    bit             dwr_valid;

    wire [31:0]     wr_off = dwr_addr - base_address_register;
    wire [31:0]     rd_off = drd_req_addr - base_address_register;

    // --------------------------------------------------------------------
    // register file (offsets per Intel 82571/82572 datasheet)
    // --------------------------------------------------------------------
    reg [31:0]  reg_ctrl;          // 0x0000 CTRL
    reg [31:0]  reg_ctrl_ext;      // 0x0018 CTRL_EXT
    reg [31:0]  reg_mdic;          // 0x0020 MDIC
    reg [31:0]  reg_kmrn;          // 0x0034 KMRNCTRLSTA
    reg [31:0]  reg_itr;           // 0x00C4 ITR
    reg [31:0]  reg_ims;           // 0x00D0 IMS
    reg [31:0]  reg_iam;           // 0x00E0 IAM
    reg [31:0]  reg_ivar;          // 0x00E4 IVAR
    reg [31:0]  reg_rctl;          // 0x0100 RCTL
    reg [31:0]  reg_tctl;          // 0x0400 TCTL
    reg [31:0]  reg_tctl_ext;      // 0x0404 TCTL_EXT
    reg [31:0]  reg_tipg;          // 0x0410 TIPG
    reg [31:0]  reg_ledctl;        // 0x0E00 LEDCTL
    reg [31:0]  reg_rdbal;         // 0x2800 RDBAL
    reg [31:0]  reg_rdbah;         // 0x2804 RDBAH
    reg [31:0]  reg_rdlen;         // 0x2808 RDLEN
    reg [31:0]  reg_srrctl;        // 0x280C SRRCTL
    reg [31:0]  reg_rdh;           // 0x2810 RDH
    reg [31:0]  reg_rdt;           // 0x2818 RDT
    reg [31:0]  reg_rdtr;          // 0x2820 RDTR
    reg [31:0]  reg_radv;          // 0x282C RADV
    reg [31:0]  reg_rsrpd;         // 0x2C00 RSRPD
    reg [31:0]  reg_txdmac;        // 0x3000 TXDMAC
    reg [31:0]  reg_tdbal;         // 0x3800 TDBAL
    reg [31:0]  reg_tdbah;         // 0x3804 TDBAH
    reg [31:0]  reg_tdlen;         // 0x3808 TDLEN
    reg [31:0]  reg_tdh;           // 0x3810 TDH
    reg [31:0]  reg_tdt;           // 0x3818 TDT
    reg [31:0]  reg_tidv;          // 0x3820 TIDV
    reg [31:0]  reg_txdctl;        // 0x3828 TXDCTL
    reg [31:0]  reg_tadv;          // 0x382C TADV
    reg [31:0]  reg_phy_ctrl;      // 0x0F10 PHY_CTRL
    reg [31:0]  reg_pba;           // 0x1000 PBA (packet buffer allocation)
    reg [31:0]  reg_rxcsum;        // 0x5000 RXCSUM
    reg [31:0]  reg_rlpml;         // 0x5004 RLPML
    reg [31:0]  reg_ral0;          // 0x5400 RAL0
    reg [31:0]  reg_rah0;          // 0x5404 RAH0
    reg [31:0]  reg_gcr;           // 0x5B00 GCR
    reg [31:0]  reg_fwsm;          // 0x5B50 FWSM
    reg [31:0]  reg_swfw_sync;     // 0x5B5C SW_FW_SYNC

    // helper state:
    reg [3:0]   ctrl_rst_cnt;      // CTRL.RST self-clear countdown
    reg [7:0]   eerd_addr;         // EEPROM address of last EERD command
    reg [15:0]  mdic_data;         // MDIC read data
    reg         mdic_ready;        // MDIC operation complete
    reg         mdic_wr_pending;   // MDIC command written, set ready next CLK

    // EEPROM contents (NVM):
    //   MAC address = 00:1B:21:12:34:56 (Intel OUI 00-1B-21)
    //   word0 = MAC[1:0] = 0x1B00, word1 = MAC[3:2] = 0x2112, word2 = MAC[5:4] = 0x3456
    //   words 0x0B..0x0E = subsystem/device/vendor ids (read by some drivers)
    //   checksum word 0x3F chosen so that sum(0x00..0x3F) == 0xBABA (NVM_SUM)
    //   sum(0x00..0x3E) = 0x926E  ->  checksum = 0xBABA - 0x926E = 0x284C
    function automatic [15:0] eeprom_read(input [7:0] addr);
        case (addr)
            8'h00: eeprom_read = 16'h1B00;  // MAC[1:0]
            8'h01: eeprom_read = 16'h2112;  // MAC[3:2]
            8'h02: eeprom_read = 16'h3456;  // MAC[5:4]
            8'h0B: eeprom_read = 16'h107D;  // NVM_SUB_DEV_ID
            8'h0C: eeprom_read = 16'h8086;  // NVM_SUB_VEN_ID
            8'h0D: eeprom_read = 16'h107D;  // NVM_DEV_ID
            8'h0E: eeprom_read = 16'h8086;  // NVM_VEN_ID
            8'h3F: eeprom_read = 16'h284C;  // NVM checksum
            default: eeprom_read = 16'h0000;
        endcase
    endfunction

    // PHY model: Marvell 88E1111 (commonly used on 82572EI PRO/1000 PT cards).
    // MDIC writes are stored and read back unchanged (write-verify safe).
    // BMSR reports link UP (bit2) and autoneg complete (bit5).
    function automatic [15:0] phy_read(input [4:0] addr);
        case (addr)
            5'h01: phy_read = 16'h78AD;  // MII_BMSR: link up, 1000T-FD capable
            5'h02: phy_read = 16'h0141;  // PHY_ID1 (Marvell 88E1111)
            5'h03: phy_read = 16'h0CC0;  // PHY_ID2
            5'h11: phy_read = 16'hAC00;  // M88 PSSR: link up, 1000Mbs FD resolved
            default: phy_read = 16'h0000;
        endcase
    endfunction

    task automatic wreg(output [31:0] r, input [31:0] d, input [3:0] be);
        if (be[0]) r[7:0]   <= d[7:0];
        if (be[1]) r[15:8]  <= d[15:8];
        if (be[2]) r[23:16] <= d[23:16];
        if (be[3]) r[31:24] <= d[31:24];
    endtask

    // --------------------------------------------------------------------
    // write path
    // --------------------------------------------------------------------
    always @ ( posedge clk ) begin
        if ( rst ) begin
            reg_ctrl        <= 32'h00000000;
            reg_ctrl_ext    <= 32'h00000000;
            reg_mdic        <= 32'h00000000;
            reg_kmrn        <= 32'h00000000;
            reg_itr         <= 32'h00000000;
            reg_ims         <= 32'h00000000;
            reg_iam         <= 32'h00000000;
            reg_ivar        <= 32'h00000000;
            reg_rctl        <= 32'h00000000;
            reg_tctl        <= 32'h00000000;
            reg_tctl_ext    <= 32'h00000000;
            reg_tipg        <= 32'h00000000;
            reg_ledctl      <= 32'h00000000;
            reg_rdbal       <= 32'h00000000;
            reg_rdbah       <= 32'h00000000;
            reg_rdlen       <= 32'h00000000;
            reg_srrctl      <= 32'h00000000;
            reg_rdh         <= 32'h00000000;
            reg_rdt         <= 32'h00000000;
            reg_rdtr        <= 32'h00000000;
            reg_radv        <= 32'h00000000;
            reg_rsrpd       <= 32'h00000000;
            reg_txdmac      <= 32'h00000000;
            reg_tdbal       <= 32'h00000000;
            reg_tdbah       <= 32'h00000000;
            reg_tdlen       <= 32'h00000000;
            reg_tdh         <= 32'h00000000;
            reg_tdt         <= 32'h00000000;
            reg_tidv        <= 32'h00000000;
            reg_txdctl      <= 32'h00000000;
            reg_tadv        <= 32'h00000000;
            reg_phy_ctrl    <= 32'h00000000;
            reg_pba         <= 32'h00100028;
            reg_rxcsum      <= 32'h00000000;
            reg_rlpml       <= 32'h00000000;
            reg_ral0        <= 32'h21121B00;  // MAC 00:1B:21:12:34:56 [31:0]
            reg_rah0        <= 32'h00003456;  // MAC [47:32], AV bit cleared
            reg_gcr         <= 32'h00000000;
            reg_fwsm        <= 32'h00000000;
            reg_swfw_sync   <= 32'h00000000;
            ctrl_rst_cnt    <= 4'h0;
            eerd_addr       <= 8'h00;
            mdic_data       <= 16'h0000;
            mdic_ready      <= 1'b0;
            mdic_wr_pending <= 1'b0;
        end
        else begin
            // --- register writes ---
            if ( dwr_valid ) begin
                case ( wr_off[15:0] )
                    16'h0000, 16'h0004: begin          // CTRL / CTRL_DUP
                        wreg(reg_ctrl, dwr_data, dwr_be);
                        if ( dwr_be[3] && dwr_data[26] )   // CTRL.RST self-clear
                            ctrl_rst_cnt <= 4'h8;
                    end
                    16'h0014: begin                    // EERD
                        eerd_addr <= dwr_data[15:8];   // EEPROM word address
                    end
                    16'h0018: wreg(reg_ctrl_ext, dwr_data, dwr_be);  // CTRL_EXT
                    16'h0020: begin                    // MDIC
                        wreg(reg_mdic, dwr_data, dwr_be);
                        mdic_ready      <= 1'b0;
                        mdic_wr_pending <= 1'b1;
                        if ( dwr_data[27] )            // MDIC OP_READ (bit27)
                            mdic_data <= phy_read(dwr_data[20:16]);
                        else
                            mdic_data <= dwr_data[15:0];
                    end
                    16'h0034: wreg(reg_kmrn, dwr_data, dwr_be);       // KMRNCTRLSTA
                    16'h00C4: wreg(reg_itr, dwr_data, dwr_be);        // ITR
                    16'h00D0: wreg(reg_ims, dwr_data, dwr_be);        // IMS
                    16'h00D8: reg_ims <= reg_ims & ~dwr_data;         // IMC
                    16'h00E0: wreg(reg_iam, dwr_data, dwr_be);        // IAM
                    16'h00E4: wreg(reg_ivar, dwr_data, dwr_be);       // IVAR
                    16'h0100: wreg(reg_rctl, dwr_data, dwr_be);       // RCTL
                    16'h0400: wreg(reg_tctl, dwr_data, dwr_be);       // TCTL
                    16'h0404: wreg(reg_tctl_ext, dwr_data, dwr_be);   // TCTL_EXT
                    16'h0410: wreg(reg_tipg, dwr_data, dwr_be);       // TIPG
                    16'h0E00: wreg(reg_ledctl, dwr_data, dwr_be);     // LEDCTL
                    16'h2800: wreg(reg_rdbal, dwr_data, dwr_be);      // RDBAL
                    16'h2804: wreg(reg_rdbah, dwr_data, dwr_be);      // RDBAH
                    16'h2808: wreg(reg_rdlen, dwr_data, dwr_be);      // RDLEN
                    16'h280C: wreg(reg_srrctl, dwr_data, dwr_be);     // SRRCTL
                    16'h2810: wreg(reg_rdh, dwr_data, dwr_be);        // RDH
                    16'h2818: wreg(reg_rdt, dwr_data, dwr_be);        // RDT
                    16'h2820: wreg(reg_rdtr, dwr_data, dwr_be);       // RDTR
                    16'h282C: wreg(reg_radv, dwr_data, dwr_be);       // RADV
                    16'h2C00: wreg(reg_rsrpd, dwr_data, dwr_be);      // RSRPD
                    16'h3000: wreg(reg_txdmac, dwr_data, dwr_be);     // TXDMAC
                    16'h3800: wreg(reg_tdbal, dwr_data, dwr_be);      // TDBAL
                    16'h3804: wreg(reg_tdbah, dwr_data, dwr_be);      // TDBAH
                    16'h3808: wreg(reg_tdlen, dwr_data, dwr_be);      // TDLEN
                    16'h3810: wreg(reg_tdh, dwr_data, dwr_be);        // TDH
                    16'h3818: wreg(reg_tdt, dwr_data, dwr_be);        // TDT
                    16'h3820: wreg(reg_tidv, dwr_data, dwr_be);       // TIDV
                    16'h3828: wreg(reg_txdctl, dwr_data, dwr_be);     // TXDCTL
                    16'h382C: wreg(reg_tadv, dwr_data, dwr_be);       // TADV
                    16'h0F10: wreg(reg_phy_ctrl, dwr_data, dwr_be);   // PHY_CTRL
                    16'h1000: wreg(reg_pba, dwr_data, dwr_be);        // PBA
                    16'h5000: wreg(reg_rxcsum, dwr_data, dwr_be);     // RXCSUM
                    16'h5004: wreg(reg_rlpml, dwr_data, dwr_be);      // RLPML
                    16'h5400: wreg(reg_ral0, dwr_data, dwr_be);       // RAL0
                    16'h5404: wreg(reg_rah0, dwr_data, dwr_be);       // RAH0
                    16'h5B00: wreg(reg_gcr, dwr_data, dwr_be);        // GCR
                    16'h5B50: wreg(reg_fwsm, dwr_data, dwr_be);       // FWSM
                    16'h5B5C: wreg(reg_swfw_sync, dwr_data, dwr_be);  // SW_FW_SYNC
                    default: ;                                        // ignore others
                endcase
            end
            // --- CTRL.RST self-clear ---
            if ( ctrl_rst_cnt != 4'h0 ) begin
                ctrl_rst_cnt <= ctrl_rst_cnt - 4'h1;
                if ( ctrl_rst_cnt == 4'h1 )
                    reg_ctrl[26] <= 1'b0;
            end
            // --- MDIC READY (set on CLK after command write) ---
            if ( mdic_wr_pending ) begin
                mdic_wr_pending <= 1'b0;
                mdic_ready      <= 1'b1;
            end
        end
    end

    // --------------------------------------------------------------------
    // read path (2 CLK total latency)
    // --------------------------------------------------------------------
    always @ ( posedge clk ) begin
        if ( rst ) begin
            drd_req_valid   <= 1'b0;
            dwr_valid       <= 1'b0;
            rd_rsp_valid    <= 1'b0;
            rd_rsp_data     <= 32'h00000000;
        end
        else begin
            drd_req_ctx     <= rd_req_ctx;
            drd_req_addr    <= rd_req_addr;
            drd_req_valid   <= rd_req_valid;
            dwr_addr        <= wr_addr;
            dwr_data        <= wr_data;
            dwr_be          <= wr_be;
            dwr_valid       <= wr_valid;

            rd_rsp_ctx      <= drd_req_ctx;
            rd_rsp_valid    <= drd_req_valid;
            if ( drd_req_valid ) begin
                case ( rd_off[15:0] )
                    16'h0000: rd_rsp_data <= reg_ctrl;                    // CTRL
                    16'h0008: rd_rsp_data <= 32'h00000283;                // STATUS: FD|LU|LAN_INIT_DONE|SPEED_1000
                    16'h0014: rd_rsp_data <= { eeprom_read(eerd_addr), 8'h00, eerd_addr, 8'h10 };  // EERD: data|addr|done (start self-cleared)
                    16'h0018: rd_rsp_data <= reg_ctrl_ext;                // CTRL_EXT
                    16'h0020: rd_rsp_data <= { reg_mdic[31:29], mdic_ready, reg_mdic[27:16], mdic_data };  // MDIC
                    16'h0034: rd_rsp_data <= reg_kmrn;                    // KMRNCTRLSTA
                    16'h00C0: rd_rsp_data <= 32'h00000000;                // ICR: no interrupts pending
                    16'h00C4: rd_rsp_data <= reg_itr;                     // ITR
                    16'h00D0: rd_rsp_data <= reg_ims;                     // IMS
                    16'h00E0: rd_rsp_data <= reg_iam;                     // IAM
                    16'h00E4: rd_rsp_data <= reg_ivar;                    // IVAR
                    16'h0100: rd_rsp_data <= reg_rctl;                    // RCTL
                    16'h0400: rd_rsp_data <= reg_tctl;                    // TCTL
                    16'h0404: rd_rsp_data <= reg_tctl_ext;                // TCTL_EXT
                    16'h0410: rd_rsp_data <= reg_tipg;                    // TIPG
                    16'h0E00: rd_rsp_data <= reg_ledctl;                  // LEDCTL
                    16'h2800: rd_rsp_data <= reg_rdbal;                   // RDBAL
                    16'h2804: rd_rsp_data <= reg_rdbah;                   // RDBAH
                    16'h2808: rd_rsp_data <= reg_rdlen;                   // RDLEN
                    16'h280C: rd_rsp_data <= reg_srrctl;                  // SRRCTL
                    16'h2810: rd_rsp_data <= reg_rdh;                     // RDH
                    16'h2818: rd_rsp_data <= reg_rdt;                     // RDT
                    16'h2820: rd_rsp_data <= reg_rdtr;                    // RDTR
                    16'h282C: rd_rsp_data <= reg_radv;                    // RADV
                    16'h2C00: rd_rsp_data <= reg_rsrpd;                   // RSRPD
                    16'h3000: rd_rsp_data <= reg_txdmac;                  // TXDMAC
                    16'h3800: rd_rsp_data <= reg_tdbal;                   // TDBAL
                    16'h3804: rd_rsp_data <= reg_tdbah;                   // TDBAH
                    16'h3808: rd_rsp_data <= reg_tdlen;                   // TDLEN
                    16'h3810: rd_rsp_data <= reg_tdh;                     // TDH
                    16'h3818: rd_rsp_data <= reg_tdt;                     // TDT
                    16'h3820: rd_rsp_data <= reg_tidv;                    // TIDV
                    16'h3828: rd_rsp_data <= reg_txdctl;                  // TXDCTL
                    16'h382C: rd_rsp_data <= reg_tadv;                    // TADV
                    16'h0F10: rd_rsp_data <= reg_phy_ctrl;                 // PHY_CTRL
                    16'h1000: rd_rsp_data <= reg_pba;                      // PBA
                    16'h5000: rd_rsp_data <= reg_rxcsum;                   // RXCSUM
                    16'h5004: rd_rsp_data <= reg_rlpml;                    // RLPML
                    16'h5400: rd_rsp_data <= reg_ral0;                    // RAL0
                    16'h5404: rd_rsp_data <= reg_rah0;                    // RAH0
                    16'h5B00: rd_rsp_data <= reg_gcr;                     // GCR
                    16'h5B50: rd_rsp_data <= reg_fwsm;                    // FWSM
                    16'h5B5C: rd_rsp_data <= reg_swfw_sync;               // SW_FW_SYNC
                    default: rd_rsp_data <= 32'h00000000;                 // reserved -> 0
                endcase
            end
            else begin
                rd_rsp_data <= 32'h00000000;
            end
        end
    end

endmodule

