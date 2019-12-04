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
import Zfp::*;

interface HwMainIfc;
endinterface

module mkHwMain#(PcieUserIfc pcie) 
    (HwMainIfc);
    Reg#(Bit#(32)) dataBuffer0 <- mkReg(0);
    Reg#(Bit#(32)) dataBuffer1 <- mkReg(0);
    Reg#(Bit#(32)) writeCounter <- mkReg(0);

    Reg#(Bit#(1)) inputCycle <- mkReg(0);
    Reg#(Bit#(2)) mergeCycle <- mkReg(0);

    ZfpIfc zfp <- mkZfp;

    FIFO#(Bit#(32)) send_pcieQ <- mkFIFO;
    FIFO#(Bit#(32)) inputQ <- mkFIFO;
    Reg#(Bit#(64)) inputBuf <- mkReg(0);
    FIFO#(Bit#(64)) mergeInputQ <- mkFIFO;
    Vector#(4,Reg#(Bit#(64))) zfpInput <- replicateM(mkReg(0));

    /* TODO */
    Vector#(4,Reg#(Bit#(64))) sendBuff <- replicateM(mkReg(0));
    Reg#(Bit#(3)) dzfpCycle <- mkReg(0);

    rule get_dzfp;
        Vector#(4,Bit#(64)) d = replicate(0);
        for (Bit#(4)i=0;i<4;i=i+1) begin
            d[i] = sendBuff[i];
        end
        if (dzfpCycle == 0) begin
            d <- zfp.get_decompressed;
        end
        case (dzfpCycle)
            0:send_pcieQ.enq(d[0][31:0]);
            1:send_pcieQ.enq(d[0][63:32]);
            2:send_pcieQ.enq(d[1][31:0]);
            3:send_pcieQ.enq(d[1][63:32]);
            4:send_pcieQ.enq(d[2][31:0]);
            5:send_pcieQ.enq(d[2][63:32]);
            6:send_pcieQ.enq(d[3][31:0]);
            7:send_pcieQ.enq(d[3][63:32]);
        endcase
        for (Bit#(4)i=0;i<4;i=i+1) begin
            sendBuff[i] <= d[i];
        end
        dzfpCycle <= dzfpCycle + 1;
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
        end else if ( off == 1 ) begin
            zfp.put_matrix_cnt(d);
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
            zfp.compress(d);
        end
        for (Bit#(4) i = 0; i < 4 ; i = i +1) begin
            zfpInput[i] <= d[i];
        end
    endrule

    /* Decompress part */
    Reg#(Bit#(8)) comp_buf_off <- mkReg(0);
    Reg#(Bit#(256)) comp_buf <- mkReg(0);
    Reg#(Bool) tset <- mkReg(False);

    Vector#(4,FIFO#(Bit#(128))) getcompQ_pre <- replicateM(mkFIFO);
    Vector#(4,FIFO#(Bit#(128))) getcompQ <- replicateM(mkSizedBRAMFIFO(385));
    Vector#(4,FIFO#(Bit#(128))) getcompQ_post <- replicateM(mkFIFO);

    Reg#(Bit#(12)) comp_cnt <- mkReg(0);
    Reg#(Bit#(2)) comp_cycle <- mkReg(0);
    Reg#(Bit#(1)) decomp_trigger <- mkReg(0);
    
    rule get_compressed;
        Bit#(128) d <- zfp.host_get;
        Bit#(2) cycle = comp_cycle;
        if (comp_cnt + 1 == 384) begin
            cycle = cycle + 1;
            comp_cnt <= 0;
            $display("cycle is changed ! %d -> %d ",cycle,cycle+1);
        end else begin
            comp_cnt <= comp_cnt + 1;
        end
        getcompQ_pre[comp_cycle].enq(d);
        comp_cycle <= cycle;
    endrule

    for (Bit#(4) i = 0; i < 4; i = i + 1) begin
        rule to_BRAM;
            getcompQ_pre[i].deq;
            getcompQ[i].enq(getcompQ_pre[i].first);
        endrule
    end

    for (Bit#(4) i = 0; i < 4; i = i + 1) begin
        rule to_out_BRAM;
            getcompQ[i].deq;
            getcompQ_post[i].enq(getcompQ[i].first);
        endrule
    end

    rule get_6k_idx;
        Bit#(32) data <- zfp.host_get_6k_idx;
        zfp.host_put_6k_idx(data);
    endrule

    for (Bit#(4) i = 0; i < 4; i = i + 1) begin
        rule send_to_decomp;
            case (i)
                0 : begin
                    getcompQ_post[i].deq;
                    zfp.host_put_1(getcompQ_post[i].first);
                end
                1 : begin
                    getcompQ_post[i].deq;
                    zfp.host_put_2(getcompQ_post[i].first);
                end
                2 : begin
                    getcompQ_post[i].deq;
                    zfp.host_put_3(getcompQ_post[i].first);
                end
                3 : begin
                    getcompQ_post[i].deq;
                    zfp.host_put_4(getcompQ_post[i].first);
                end
            endcase
        endrule
    end
endmodule
