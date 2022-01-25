///////////////////////////////////////////
//
// Written: Katherine Parry, James Stine, Brett Mathis
// Modified: 6/23/2021
//
// Purpose: FPU
// 
// A component of the Wally configurable RISC-V project.
// 
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// MIT LICENSE
// Permission is hereby granted, free of charge, to any person obtaining a copy of this 
// software and associated documentation files (the "Software"), to deal in the Software 
// without restriction, including without limitation the rights to use, copy, modify, merge, 
// publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons 
// to whom the Software is furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all copies or 
//   substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
//   INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR 
//   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS 
//   BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, 
//   TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE 
//   OR OTHER DEALINGS IN THE SOFTWARE.
////////////////////////////////////////////////////////////////////////////////////////////////

`include "wally-config.vh"

module fpu (
  input logic 		   clk,
  input logic 		   reset,
  input logic [2:0] 	   FRM_REGW, // Rounding mode from CSR
  input logic [31:0] 	   InstrD, // instruction from IFU
  input logic [`XLEN-1:0]  ReadDataW,// Read data from memory
  input logic [`XLEN-1:0]  ForwardedSrcAE, // Integer input being processed (from IEU)
  input logic 		   StallE, StallM, StallW, // stall signals from HZU
  input logic 		   FlushE, FlushM, FlushW, // flush signals from HZU
  input logic [4:0] 	   RdM, RdW, // which FP register to write to (from IEU)
  output logic 		   FRegWriteM, // FP register write enable
  output logic 		   FStallD, // Stall the decode stage
  output logic 		   FWriteIntE, // integer register write enables
  output logic [`XLEN-1:0] FWriteDataE, // Data to be written to memory
  output logic [`XLEN-1:0] FIntResM, // data to be written to integer register
  output logic 		   FDivBusyE, // Is the divide/sqrt unit busy (stall execute stage)
  output logic 		   IllegalFPUInstrD, // Is the instruction an illegal fpu instruction
  output logic [4:0] 	   SetFflagsM        // FPU flags (to privileged unit)
  );

   //*** make everything FLEN at some point
   //*** add the 128 bit support to the if statement when needed
   //*** make new tests for fp using testfloat that include flag checking and all rounding modes
   //*** what is the format for 16-bit - finding conflicting info online can't find anything specified in spec
   //*** only fma/mul and fp <-> int convert flags have been tested. test the others.

   // FPU specifics:
   //    - uses NaN-blocking format
   //        - if there are any unsused bits the most significant bits are filled with 1s
   //                single stored in a double: | 32 1s | single precision value |
   //    - sets the underflow after rounding
  
   // control signals
   logic 		  FRegWriteD, FRegWriteE, FRegWriteW; // FP register write enable
   logic [2:0] 	  FrmD, FrmE, FrmM;                   // FP rounding mode
   logic 		  FmtD, FmtE, FmtM, FmtW;             // FP precision 0-single 1-double
   logic 		  FDivStartD, FDivStartE;             // Start division or squareroot
   logic 		  FWriteIntD;                         // Write to integer register
   logic [1:0] 	  FForwardXE, FForwardYE, FForwardZE; // forwarding mux control signals
   logic [1:0] 	  FResultSelD, FResultSelE;           // Select the result written to FP register
   logic [1:0] 	  FResultSelM, FResultSelW;           // Select the result written to FP register
   logic [2:0] 	  FOpCtrlD, FOpCtrlE;       // Select which opperation to do in each component
   logic [2:0] 	  FResSelD, FResSelE;       // Select one of the results that finish in the memory stage
   logic [1:0] 	  FIntResSelD, FIntResSelE;           // Select the result written to the integer resister
   logic [4:0] 	  Adr1E, Adr2E, Adr3E;                // adresses of each input

   // regfile signals
   logic [63:0] 	  FRD1D, FRD2D, FRD3D;                // Read Data from FP register - decode stage
   logic [63:0] 	  FRD1E, FRD2E, FRD3E;                // Read Data from FP register - execute stage
   logic [63:0] 	  FSrcXE;                             // Input 1 to the various units (after forwarding)
   logic [63:0] 	  FPreSrcYE, FSrcYE;                  // Input 2 to the various units (after forwarding)
   logic [63:0] 	  FPreSrcZE, FSrcZE;                  // Input 3 to the various units (after forwarding)

   // unpacking signals
   logic 		  XSgnE, YSgnE, ZSgnE;                // input's sign - execute stage
   logic 		  XSgnM, YSgnM;                       // input's sign - memory stage
   logic [10:0] 	  XExpE, YExpE, ZExpE;                // input's exponent - execute stage
   logic [10:0] 	  XExpM, YExpM, ZExpM;                // input's exponent - memory stage
   logic [52:0] 	  XManE, YManE, ZManE;                // input's fraction - execute stage
   logic [52:0] 	  XManM, YManM, ZManM;                // input's fraction - memory stage
   logic [10:0] 	  BiasE;                              // bias based on precision (single=7f double=3ff)
   logic 		  XNaNE, YNaNE, ZNaNE;                // is the input a NaN - execute stage
   logic 		  XNaNM, YNaNM, ZNaNM;                // is the input a NaN - memory stage
   logic 		  XNaNQ, YNaNQ;                       // is the input a NaN - divide
   logic 		  XSNaNE, YSNaNE, ZSNaNE;             // is the input a signaling NaN - execute stage
   logic 		  XSNaNM, YSNaNM, ZSNaNM;             // is the input a signaling NaN - memory stage
   logic 		  XDenormE, YDenormE, ZDenormE;       // is the input denormalized
   logic 		  XZeroE, YZeroE, ZZeroE;             // is the input zero - execute stage
   logic 		  XZeroM, YZeroM, ZZeroM;             // is the input zero - memory stage
   logic 		  XZeroQ, YZeroQ;                     // is the input zero - divide
   logic 		  XInfE, YInfE, ZInfE;                // is the input infinity - execute stage
   logic 		  XInfM, YInfM, ZInfM;                // is the input infinity - memory stage
   logic 		  XInfQ, YInfQ;                       // is the input infinity - divide
   logic 		  XExpMaxE;                           // is the exponent all ones (max value)
   logic 		  XNormE;                             // is normal
   logic 		  FmtQ;
   logic 		  FOpCtrlQ;     

   // result and flag signals
   logic [63:0] 	  FDivResM, FDivResW;                 // divide/squareroot result
   logic [4:0] 	  FDivFlgM;                 // divide/squareroot flags  
   logic [63:0] 	  FMAResM, FMAResW;                   // FMA/multiply result
   logic [4:0] 	  FMAFlgM;                   // FMA/multiply result	
   logic [63:0] 	  ReadResW;                           // read result (load instruction)
   logic [63:0] 	  CvtFpResE;    // add/FP -> FP convert result
   logic [4:0] 	  CvtFpFlgE;    // add/FP -> FP convert flags
   logic [63:0] 	  CvtResE;                   // FP <-> int convert result
   logic [4:0] 	  CvtFlgE;                   // FP <-> int convert flags //*** trim this	
   logic [63:0] 	  ClassResE;               // classify result
   logic [63:0] 	  CmpResE;                   // compare result
   logic 		  CmpNVE;                     // compare invalid flag (Not Valid)     
   logic [63:0] 	  SgnResE;                   // sign injection result
   logic [63:0] 	  FResE, FResM, FResW;                // selected result that is ready in the memory stage
   logic [4:0] 	  FFlgE, FFlgM;                       // selected flag that is ready in the memory stage     
   logic [`XLEN-1:0] 	  FIntResE;     
   logic [63:0] 	  FPUResultW;                         // final FP result being written to the FP register     
   // other signals
   logic 		  FDivSqrtDoneE;                      // is divide done
   logic [63:0] 	  DivInput1E, DivInput2E;             // inputs to divide/squareroot unit
   logic 		  load_preload;                       // enable for FF on fpdivsqrt     
   logic [63:0] 	  AlignedSrcAE;                       // align SrcA to the floating point format
   logic [63:0]     BoxedZeroE;                         // Zero value for Z for multiplication, with NaN boxing if needed
   
   // DECODE STAGE

   // calculate FP control signals
   fctrl fctrl (.Funct7D(InstrD[31:25]), .OpD(InstrD[6:0]), .Rs2D(InstrD[24:20]), .Funct3D(InstrD[14:12]), .FRM_REGW,
      .IllegalFPUInstrD, .FRegWriteD, .FDivStartD, .FResultSelD, .FOpCtrlD, .FResSelD, 
      .FIntResSelD, .FmtD, .FrmD, .FWriteIntD);

   // FP register file
   fregfile fregfile (.clk, .reset, .we4(FRegWriteW),
      .a1(InstrD[19:15]), .a2(InstrD[24:20]), .a3(InstrD[31:27]), 
      .a4(RdW), .wd4(FPUResultW),
      .rd1(FRD1D), .rd2(FRD2D), .rd3(FRD3D));	

   // D/E pipeline registers
   flopenrc #(64) DEReg1(clk, reset, FlushE, ~StallE, FRD1D, FRD1E);
   flopenrc #(64) DEReg2(clk, reset, FlushE, ~StallE, FRD2D, FRD2E);
   flopenrc #(64) DEReg3(clk, reset, FlushE, ~StallE, FRD3D, FRD3E);
   flopenrc #(15) DEAdrReg(clk, reset, FlushE, ~StallE, {InstrD[19:15], InstrD[24:20], InstrD[31:27]}, 
                           {Adr1E, Adr2E, Adr3E});
   flopenrc #(17) DECtrlReg3(clk, reset, FlushE, ~StallE, 
               {FRegWriteD, FResultSelD, FResSelD, FIntResSelD, FrmD, FmtD, FOpCtrlD, FWriteIntD, FDivStartD},
               {FRegWriteE, FResultSelE, FResSelE, FIntResSelE, FrmE, FmtE, FOpCtrlE, FWriteIntE, FDivStartE});

   // EXECUTION STAGE
   // Hazard unit for FPU  
   //    - determines if any forwarding or stalls are needed
   fhazard fhazard(.Adr1E, .Adr2E, .Adr3E, .FRegWriteM, .FRegWriteW, .RdM, .RdW, .FResultSelM, 
                  .FStallD, .FForwardXE, .FForwardYE, .FForwardZE);

   // forwarding muxs
   mux3  #(64)  fxemux (FRD1E, FPUResultW, FResM, FForwardXE, FSrcXE);
   mux3  #(64)  fyemux (FRD2E, FPUResultW, FResM, FForwardYE, FPreSrcYE);
   mux3  #(64)  fzemux (FRD3E, FPUResultW, FResM, FForwardZE, FPreSrcZE);
   mux3  #(64)  fyaddmux (FPreSrcYE, {{32{1'b1}}, 2'b0, {7{1'b1}}, 23'b0}, 
            {2'b0, {10{1'b1}}, 52'b0}, 
            {FmtE&FOpCtrlE[2]&FOpCtrlE[1]&(FResultSelE==2'b01), ~FmtE&FOpCtrlE[2]&FOpCtrlE[1]&(FResultSelE==2'b01)}, 
            FSrcYE); // Force Z to be 0 for multiply instructions
   // Force Z to be 0 for multiply instructions 
   mux2 #(64) fmulzeromux (64'hFFFFFFFF00000000, 64'b0, FmtE, BoxedZeroE); // NaN boxing for 32-bit zero
   mux3  #(64)  fzmulmux (FPreSrcZE, BoxedZeroE, FPreSrcYE, {FOpCtrlE[2]&FOpCtrlE[1], FOpCtrlE[2]&~FOpCtrlE[1]}, FSrcZE);
      
   // unpacking unit
   //    - splits FP inputs into their various parts
   //    - does some classifications (SNaN, NaN, Denorm, Norm, Zero, Infifnity)
   unpacking unpacking (.X(FSrcXE), .Y(FSrcYE), .Z(FSrcZE), .FOpCtrlE, .FmtE, 
         .XSgnE, .YSgnE, .ZSgnE, .XExpE, .YExpE, .ZExpE, .XManE, .YManE, .ZManE, 
         .XNaNE, .YNaNE, .ZNaNE, .XSNaNE, .YSNaNE, .ZSNaNE, .XDenormE, .YDenormE, .ZDenormE, 
         .XZeroE, .YZeroE, .ZZeroE, .BiasE, .XInfE, .YInfE, .ZInfE, .XExpMaxE, .XNormE);

   // FMA
   //   - two stage FMA
   //   - execute stage - multiplication and addend shifting
   //   - memory stage  - addition and rounding
   //   - handles FMA and multiply instructions
   fma fma (.clk, .reset, .FlushM, .StallM, 
      .XSgnE, .YSgnE, .ZSgnE, .XExpE, .YExpE, .ZExpE, .XManE, .YManE, .ZManE, 
      .XDenormE, .YDenormE, .ZDenormE, .XZeroE, .YZeroE, .ZZeroE,
      .XSgnM, .YSgnM, .XExpM, .YExpM, .ZExpM, .XManM, .YManM, .ZManM, 
      .XNaNM, .YNaNM, .ZNaNM, .XZeroM, .YZeroM, .ZZeroM, 
      .XInfM, .YInfM, .ZInfM, .XSNaNM, .YSNaNM, .ZSNaNM,
      .FOpCtrlE,
      .FmtE, .FmtM, .FrmM, 
      .FMAFlgM, .FMAResM);

   // fpdivsqrt using Goldschmidt's iteration
   flopenrc #(64) reg_input1 (.d({XSgnE, XExpE, XManE[51:0]}), .q(DivInput1E),
         .clear(FDivSqrtDoneE), .en(load_preload),
         .reset(reset),  .clk(clk));
   flopenrc #(64) reg_input2 (.d({YSgnE, YExpE, YManE[51:0]}), .q(DivInput2E),
            .clear(FDivSqrtDoneE), .en(load_preload),
            .reset(reset),  .clk(clk));
   flopenrc #(8) reg_input3 (.d({XNaNE, YNaNE, XInfE, YInfE, XZeroE, YZeroE, FmtE, FOpCtrlE[0]}), 
            .q({XNaNQ, YNaNQ, XInfQ, YInfQ, XZeroQ, YZeroQ, FmtQ, FOpCtrlQ}),
            .clear(FDivSqrtDoneE), .en(load_preload),
            .reset(reset),  .clk(clk));
   fpdiv_pipe fdivsqrt (.op1(DivInput1E), .op2(DivInput2E), .rm(FrmE[1:0]), .op_type(FOpCtrlQ), 
         .reset, .clk(clk), .start(FDivStartE), .P(~FmtQ), .OvEn(1'b1), .UnEn(1'b1),
         .XNaNQ, .YNaNQ, .XInfQ, .YInfQ, .XZeroQ, .YZeroQ, .load_preload,
         .FDivBusyE, .done(FDivSqrtDoneE), .AS_Result(FDivResM), .Flags(FDivFlgM));

   // convert from signle to double and vice versa
   cvtfp cvtfp (.XExpE, .XManE, .XSgnE, .XZeroE, .XDenormE, .XInfE, .XNaNE, .XSNaNE, .FrmE, .FmtE, .CvtFpResE, .CvtFpFlgE);

   // compare unit
   //    - computation is done in one stage
   //    - writes to FP file durring min/max instructions
   //    - other comparisons write a 1 or 0 to the integer register
   fcmp fcmp (.FmtE, .FOpCtrlE, .XSgnE, .YSgnE, .XExpE, .YExpE, .XManE, .YManE, 
            .XZeroE, .YZeroE, .XNaNE, .YNaNE, .XSNaNE, .YSNaNE, .FSrcXE, .FSrcYE, .CmpNVE, .CmpResE);

   // sign injection unit
   fsgn fsgn (.SgnOpCodeE(FOpCtrlE[1:0]), .XSgnE, .YSgnE, .FSrcXE, .FmtE, .XExpMaxE,
    .SgnResE);

   // classify
   fclassify fclassify (.XSgnE, .XDenormE, .XZeroE, .XNaNE, .XInfE, .XNormE, 
         .XSNaNE, .ClassResE);

   // Convert
   fcvt fcvt (.XSgnE, .XExpE, .XManE, .XZeroE, .XNaNE, .XInfE, .XDenormE, .BiasE, .ForwardedSrcAE, .FOpCtrlE, .FmtE, .FrmE,
   .CvtResE, .CvtFlgE);

   // data to be stored in memory - to IEU
   //    - FP uses NaN-blocking format
   //        - if there are any unsused bits the most significant bits are filled with 1s
   assign FWriteDataE = FSrcYE[`XLEN-1:0];     

   // Align SrcA to MSB when single precicion
   mux2  #(64)  SrcAMux({{32{1'b1}}, ForwardedSrcAE[31:0]}, {{64-`XLEN{1'b1}}, ForwardedSrcAE}, FmtE, AlignedSrcAE);

   // select a result that may be written to the FP register
   mux5  #(64) FResMux(AlignedSrcAE, SgnResE, CmpResE, CvtResE, CvtFpResE, FResSelE, FResE);
   mux5  #(5)  FFlgMux(5'b0, 5'b0, {CmpNVE, 4'b0}, CvtFlgE, CvtFpFlgE, FResSelE, FFlgE);

   // select the result that may be written to the integer register - to IEU
   mux4  #(`XLEN)  IntResMux(CmpResE[`XLEN-1:0], FSrcXE[`XLEN-1:0], ClassResE[`XLEN-1:0], 
               CvtResE[`XLEN-1:0], FIntResSelE, FIntResE);

   // E/M pipe registers

   // flopenrc #(64) EMFpReg1(clk, reset, FlushM, ~StallM, FSrcXE, FSrcXM);
   flopenrc #(65) EMFpReg2 (clk, reset, FlushM, ~StallM, {XSgnE,XExpE,XManE}, {XSgnM,XExpM,XManM});
   flopenrc #(65) EMFpReg3 (clk, reset, FlushM, ~StallM, {YSgnE,YExpE,YManE}, {YSgnM,YExpM,YManM});
   flopenrc #(64) EMFpReg4 (clk, reset, FlushM, ~StallM, {ZExpE,ZManE}, {ZExpM,ZManM});
   flopenrc #(12) EMFpReg5 (clk, reset, FlushM, ~StallM, 
            {XZeroE, YZeroE, ZZeroE, XInfE, YInfE, ZInfE, XNaNE, YNaNE, ZNaNE, XSNaNE, YSNaNE, ZSNaNE},
            {XZeroM, YZeroM, ZZeroM, XInfM, YInfM, ZInfM, XNaNM, YNaNM, ZNaNM, XSNaNM, YSNaNM, ZSNaNM});     
   flopenrc #(64) EMRegCmpRes (clk, reset, FlushM, ~StallM, FResE, FResM); 
   flopenrc #(5)  EMRegCmpFlg (clk, reset, FlushM, ~StallM, FFlgE, FFlgM);      
   flopenrc #(`XLEN) EMRegSgnRes (clk, reset, FlushM, ~StallM, FIntResE, FIntResM);
   flopenrc #(7) EMCtrlReg (clk, reset, FlushM, ~StallM,
               {FRegWriteE, FResultSelE, FrmE, FmtE},
               {FRegWriteM, FResultSelM, FrmM, FmtM});

   // BEGIN MEMORY STAGE

   // FPU flag selection - to privileged
   mux4  #(5)  FPUFlgMux (5'b0, FMAFlgM, FDivFlgM, FFlgM, FResultSelM, SetFflagsM);

   // M/W pipe registers
   flopenrc #(64) MWRegFma(clk, reset, FlushW, ~StallW, FMAResM, FMAResW); 
   flopenrc #(64) MWRegDiv(clk, reset, FlushW, ~StallW, FDivResM, FDivResW); 
   flopenrc #(64) MWRegClass(clk, reset, FlushW, ~StallW, FResM, FResW);
   flopenrc #(4)  MWCtrlReg(clk, reset, FlushW, ~StallW,
            {FRegWriteM, FResultSelM, FmtM},
            {FRegWriteW, FResultSelW, FmtW});

   // BEGIN WRITEBACK STAGE

   // put ReadData into NaN-blocking format
   //    - if there are any unsused bits the most significant bits are filled with 1s
   //    - for load instruction
   mux2  #(64)  ReadResMux ({{32{1'b1}}, ReadDataW[31:0]}, {{64-`XLEN{1'b1}}, ReadDataW}, FmtW, ReadResW);

   // select the result to be written to the FP register
   mux4  #(64)  FPUResultMux (ReadResW, FMAResW, FDivResW, FResW, FResultSelW, FPUResultW);
endmodule // fpu