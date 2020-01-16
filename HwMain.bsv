import FIFO::*;
import FIFOF::*;
import Clocks::*;
import Vector::*;

import BRAM::*;
import BRAMFIFO::*;

import PcieCtrl::*;

import DMASplitter::*;

import ZfpCompress::*;
import ZfpDecompress::*;

interface HwMainIfc;
endinterface

module mkHwMain#(PcieUserIfc pcie) 
    (HwMainIfc);
    Reg#(Bit#(32)) dataBuffer0 <- mkReg(0);
    Reg#(Bit#(32)) dataBuffer1 <- mkReg(0);
    Reg#(Bit#(32)) writeCounter <- mkReg(0);

    Reg#(Bit#(1)) inputCycle <- mkReg(0);
    Reg#(Bit#(2)) mergeCycle <- mkReg(0);

    ZfpCompressIfc zfp <- mkZfpCompress;
    ZfpDecompressIfc dzfp <- mkZfpDecompress;

    FIFO#(Bit#(32)) send_pcieQ <- mkFIFO;
    FIFO#(Bit#(32)) send_pcieQ_pre <- mkFIFO;
    FIFO#(Bit#(32)) inputQ <- mkFIFO;
    Reg#(Bit#(64)) inputBuf <- mkReg(0);
    FIFO#(Bit#(64)) mergeInputQ <- mkFIFO;
    Vector#(4,Reg#(Bit#(64))) zfpInput <- replicateM(mkReg(0));

    FIFO#(Vector#(4,Bit#(64))) get_decomp_toBRAM <- mkSizedBRAMFIFO(1000);
    FIFO#(Vector#(4,Bit#(64))) get_decomp_fromBRAM <- mkFIFO;
    FIFO#(Vector#(4,Bit#(64))) get_decomp_toBRAM_pre <- mkFIFO;

    Reg#(Bit#(32)) outputCounter <- mkReg(0);
    Reg#(Bit#(32)) totalMatrixCnt <- mkReg(1000);
    Reg#(Bool) decomp_reset <- mkReg(False);

    rule getDecomptoBRAM(totalMatrixCnt != outputCounter && !decomp_reset);
        Vector#(4,Bit#(64)) temp <- dzfp.get;
        Bool b <- dzfp.check_last;
        /* if (b) begin */
            get_decomp_toBRAM_pre.enq(temp);
            outputCounter <= outputCounter + 1;
        /* end */
    endrule

    rule reset(totalMatrixCnt == outputCounter && !decomp_reset);
        dzfp.finish(True);
        decomp_reset <= True;
    endrule

    rule flush_decomp(decomp_reset);
        Vector#(4,Bit#(64)) temp <- dzfp.get;
        Bool b <- dzfp.check_last;
    endrule

    rule toBRAM;
        get_decomp_toBRAM_pre.deq;
        let d = get_decomp_toBRAM_pre.first;
        get_decomp_toBRAM.enq(d);
    endrule

    rule getDecompFromBRAM;
        get_decomp_toBRAM.deq;
        get_decomp_fromBRAM.enq(get_decomp_toBRAM.first);
    endrule

    /* TODO */
    Vector#(4,Reg#(Bit#(64))) sendBuff <- replicateM(mkReg(0));
    Reg#(Bit#(3)) dzfpCycle <- mkReg(0);
    rule get_dzfp;
        Vector#(4,Bit#(64)) d = replicate(0);
        for (Bit#(4)i=0;i<4;i=i+1) begin
            d[i] = sendBuff[i];
        end
        if (dzfpCycle == 0) begin
            get_decomp_fromBRAM.deq;
            d = get_decomp_fromBRAM.first;
        end
        case (dzfpCycle)
            0:send_pcieQ_pre.enq(d[0][31:0]);
            1:send_pcieQ_pre.enq(d[0][63:32]);
            2:send_pcieQ_pre.enq(d[1][31:0]);
            3:send_pcieQ_pre.enq(d[1][63:32]);
            4:send_pcieQ_pre.enq(d[2][31:0]);
            5:send_pcieQ_pre.enq(d[2][63:32]);
            6:send_pcieQ_pre.enq(d[3][31:0]);
            7:send_pcieQ_pre.enq(d[3][63:32]);
        endcase
        for (Bit#(4)i=0;i<4;i=i+1) begin
            sendBuff[i] <= d[i];
        end
        dzfpCycle <= dzfpCycle + 1;
    endrule

    rule send_pcie_bridge;
        send_pcieQ_pre.deq;
        let d = send_pcieQ_pre.first;
        send_pcieQ.enq(d);
    endrule

    rule sendToHost;
        // read request handle must be returned with pcie.dataSend
        let r <- pcie.dataReq;
        let a = r.addr;
        send_pcieQ.deq;
        let decompressed = send_pcieQ.first;
        $display("goto pcie");
        // PCIe IO is done at 4 byte granularities
        // lower 2 bits are always zero
        let offset = (a>>2);
        if ( offset == 0 ) begin
            pcie.dataSend(r, decompressed);
        end else if ( offset == 1 ) begin
            pcie.dataSend(r, decompressed);
        end else begin
            pcie.dataSend(r, writeCounter);
        end
    endrule

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
            totalMatrixCnt <= d;
        end else if (off == 3) begin
            inputQ.enq(d);
        end else begin
            writeCounter <= writeCounter + 1;
        end
    endrule

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

    rule merge_Input_256Bits;
        mergeInputQ.deq;
        Vector#(4, Bit#(64)) d;
        for (Bit#(4) i = 0; i < 4 ; i = i +1) begin
            d[i] = zfpInput[i];
        end

        let in = mergeInputQ.first;
        d[mergeCycle] = in;
        mergeCycle <= mergeCycle + 1;

        if (mergeCycle == 3) begin
            zfp.put(d);
        end
        for (Bit#(4) i = 0; i < 4 ; i = i +1) begin
            zfpInput[i] <= d[i];
        end
    endrule
    /* Decompress part */
    Reg#(Bit#(8)) comp_buf_off <- mkReg(0);
    Reg#(Bit#(160)) comp_buf <- mkReg(0);
    Reg#(Bool) tset <- mkReg(False);

    Reg#(Bit#(1)) deserial_cycle <- mkReg(0);
    Reg#(Bit#(128)) temp_d <- mkReg(0);
    FIFO#(Bit#(128)) deserialQ <- mkFIFO;

    rule deserial;
        if (deserial_cycle == 0) begin
            Bit#(256) d <- zfp.get;
            deserialQ.enq(truncate(d));
            temp_d <= truncateLSB(d);
        end else begin
            deserialQ.enq(temp_d);
        end
        deserial_cycle <= deserial_cycle + 1;
    endrule

    rule sendToDecomp;
        Bit#(8) b_off = comp_buf_off;
        Bit#(160) b_buf = comp_buf;
        if (b_off < 48) begin
            deserialQ.deq;
            Bit#(128) compressed = deserialQ.first;
            Bit#(160) temp_buff = zeroExtend(compressed);
            case (b_off)
                16 : begin
                    temp_buff = temp_buff << 16;
                end
                32 : begin
                    temp_buff = temp_buff << 32;
                end
            endcase
            b_buf = b_buf | temp_buff;
            b_off = b_off + 128;
        end else begin
            dzfp.put(truncate(comp_buf));
            b_buf = b_buf >> 48;
            b_off = b_off - 48;
        end
        comp_buf <= b_buf;
        comp_buf_off <= b_off;
    endrule

endmodule
