import FIFO::*;
import FIFOF::*;
import Clocks::*;
import Vector::*;

import BRAM::*;
import BRAMFIFO::*;

import PcieCtrl::*;

import DMASplitter::*;

import Zfp::*;
import DecompZfp::*;

interface HwMainIfc;
endinterface

module mkHwMain#(PcieUserIfc pcie) 
    (HwMainIfc);

    Clock curClk <- exposeCurrentClock;
    Reset curRst <- exposeCurrentReset;

    Clock pcieclk = pcie.user_clk;
    Reset pcierst = pcie.user_rst;

    Reg#(Bit#(32)) dataBuffer0 <- mkReg(0);
    Reg#(Bit#(32)) dataBuffer1 <- mkReg(0);
    Reg#(Bit#(32)) writeCounter <- mkReg(0);

    Reg#(Bit#(1)) inputCycle <- mkReg(0);
    Reg#(Bit#(2)) mergeCycle <- mkReg(0);

    FIFO#(Bit#(64)) inputBramBuf <- mkSizedBRAMFIFO(1024); 

    ZfpIfc zfp <- mkZfp;
    DZfpIfc dzfp <- mkDecompZfp;

    FIFO#(Bit#(32)) next <- mkFIFO;
    FIFO#(Bit#(32)) inputQ <- mkFIFO;
    Reg#(Bit#(64)) inputBuf <- mkReg(0);
    FIFO#(Bit#(64)) mergeInputQ <- mkFIFO;
    Vector#(4,Reg#(Bit#(64))) zfpInput <- replicateM(mkReg(0));
    Reg#(Bit#(2)) sendCycle <- mkReg(0);
    Reg#(Bit#(128)) sendBuff <- mkReg(0);
    FIFOF#(Vector#(4, Bit#(64))) toZfp <- mkSizedBRAMFIFOF(126000);


    /* TODO */
/*     rule toSend;
 *         Bit#(2) cycle = sendCycle;
 *         Bit#(32) temp = 0;
 *         Bit#(128) ibuf = sendBuff;
 *
 *         if (cycle == 0) begin
 *             ibuf <- dzfp.get;
 *         end
 *         next.enq(truncate(ibuf));
 *
 *         sendBuff <= ibuf >> 32;
 *         sendCycle <= sendCycle + 1;
 *     endrule
 *
 *     rule echoRead;
 *         // read request handle must be returned with pcie.dataSend
 *         let r <- pcie.dataReq;
 *         let a = r.addr;
 *
 *         next.deq;
 *         let compressed = next.first;
 *
 *         // PCIe IO is done at 4 byte granularities
 *         // lower 2 bits are always zero
 *         let offset = (a>>2);
 *         if ( offset == 0 ) begin
 *             pcie.dataSend(r, compressed);
 *         end else if ( offset == 1 ) begin
 *             pcie.dataSend(r, compressed);
 *         end else begin
 *             //pcie.dataSend(r, pcie.debug_data);
 *             pcie.dataSend(r, writeCounter);
 *         end
 *     endrule */

    rule getDataFromHost;
        let w <- pcie.dataReceive;
        let a = w.addr;
        let d = w.data;

        let off = (a>>2);
        if ( off == 0 ) begin
            zfp.put_noiseMargin(truncate(unpack(d)));
            dzfp.put_noiseMargin(truncate(unpack(d)));
        end else if ( off == 1 ) begin
            zfp.put_matrix_cnt(d);
        end else if (off == 3) begin
            inputQ.enq(d);
        end else begin
            writeCounter <= writeCounter + 1;
        end
    endrule

    Reg#(Bit#(64)) inputCnt <- mkReg(0);
    Reg#(Bit#(64)) zfpCnt <- mkReg(0);

    rule matrixInputCtl;
        inputQ.deq;
        Bit#(64) ibuf = 0;
        if (inputCycle == 1) begin
            ibuf= inputBuf | zeroExtend(inputQ.first) << 32;
            mergeInputQ.enq(ibuf);
        end else begin
            ibuf = zeroExtend(inputQ.first);
            inputBuf <= ibuf;
        end
        inputCycle <= inputCycle + 1;
    endrule

    rule merge_Input_256Bits(inputCnt < 125010);
        mergeInputQ.deq;
        Vector#(4, Bit#(64)) d;
        for (Bit#(4) i = 0; i < 4 ; i = i +1) begin
            d[i] = zfpInput[i];
        end

        let in = mergeInputQ.first;
        d[mergeCycle] = in;
        mergeCycle <= mergeCycle + 1;

        if (mergeCycle == 3) begin
            toZfp.enq(d);
            inputCnt <= inputCnt + 1;
        end
        for (Bit#(4) i = 0; i < 4 ; i = i +1) begin
            zfpInput[i] <= d[i];
        end
    endrule
    Reg#(Bool) inputTrigger <- mkReg(False);

    rule inputTriggerOn(inputCnt > 125000);
        inputTrigger <= True;
    endrule

    rule cnttZfp(inputTrigger);
        zfpCnt <= zfpCnt + 1;
    endrule

    rule queueingZfp(inputTrigger);
        zfp.put(toZfp.first);
        $display("clock is %d ",zfpCnt);
        toZfp.deq;
    endrule

    /* Decompress part */
    Reg#(Bit#(8)) comp_buf_off <- mkReg(0);
    Reg#(Bit#(256)) comp_buf <- mkReg(0);
    Reg#(Bool) tset <- mkReg(False);
    Reg#(Bool) final_set <- mkReg(False);
    Reg#(Bit#(64)) dzfpCnt <- mkReg(0);

    rule get_zfp;
        Bit#(128) data <- zfp.get;
        dzfpCnt <= dzfpCnt + 1;
        $display("dzfpCnt is %d ",dzfpCnt);
    endrule

    /* rule sendToDecomp(!final_set);
     *     Bit#(8) b_off = comp_buf_off;
     *     Bit#(256) b_buf = comp_buf;
     *     if (b_off < 19) begin
     *         Bit#(128) compressed <- zfp.get;
     *         dzfpCnt <= dzfpCnt + 1;
     *         $display("dzfpCnt is %d ",dzfpCnt);
     *         Bit#(256) t_buf = zeroExtend(compressed);
     *         t_buf = t_buf << b_off;
     *         b_buf = b_buf | t_buf;
     *         b_off = b_off + 128;
     *         tset <= True;
     *     end
     *     if (tset && b_off > 18) begin
     *         dzfp.put(truncate(comp_buf));
     *         b_buf = b_buf >> 19;
     *         b_off = b_off - 19;
     *     end
     *     comp_buf <= b_buf;
     *     comp_buf_off <= b_off;
     * endrule */

    Reg#(Bit#(128)) dzfp_d <- mkReg(0);

    rule dzfpGet;
        Bit#(128) d  <- dzfp.get;
        dzfp_d <= d;
    endrule

    rule finalOutput(!final_set && comp_buf_off < 19);
        Bit#(128) compressed <- zfp.get_last_data;
        Bit#(8) off <- zfp.get_last_off;
        Bit#(8) b_off = comp_buf_off;
        Bit#(256) b_buf = comp_buf;
        Bit#(256) t_buf = zeroExtend(compressed);

        t_buf = t_buf << b_off;
        b_buf = b_buf | t_buf;
        b_off = b_off + off;

        comp_buf <= b_buf;
        comp_buf_off <= b_off;
        final_set <= True;
    endrule

    rule final_queueing (final_set  && comp_buf_off > 0);
        Bit#(256) b_buf = comp_buf;
        Bit#(8) b_off = comp_buf_off;

        $display("last Q is %b ", comp_buf);
        dzfp.put(truncate(comp_buf));
        b_buf = b_buf >> 19;

        if (b_off > 19) begin
            b_off = b_off - 19;
        end else begin
            b_off = 0;
        end

        comp_buf_off <= b_off;
        comp_buf <= b_buf;
    endrule
endmodule
