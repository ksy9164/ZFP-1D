package Zfp;
import FIFO::*;
import FIFOF::*;
import Clocks::*;
import Vector::*;
import BRAM::*;
import BRAMFIFO::*;
import PcieCtrl::*;
import ZfpCompress::*;
import ZfpDecompress::*;

interface ZfpIfc;
method Action host_put_1(Bit#(128) data);
method Action host_put_2(Bit#(128) data);
method Action host_put_3(Bit#(128) data);
method Action host_put_4(Bit#(128) data);
method ActionValue#(Bit#(128)) host_get;
method ActionValue#(Vector#(4,Bit#(32))) host_get_6k_idx;
method Action host_put_6k_idx(Vector#(4,Bit#(32)) idx);
method Action compress(Vector#(4, Bit#(64)) data);
method ActionValue#(Vector#(4, Bit#(64)))get_decompressed;
method Action put_noiseMargin(Int#(7) size);
method Action put_matrix_cnt(Bit#(32) cnt);
endinterface

(* synthesize *)
module mkZfp(ZfpIfc);
    /* interface Q */
    Vector#(4,FIFO#(Bit#(128))) hostInputQ <- replicateM(mkSizedFIFO(11));
    FIFO#(Bit#(128)) hostOutputQ <- mkSizedFIFO(11);
    FIFO#(Vector#(4,Bit#(64))) compressQ <- mkFIFO;
    FIFO#(Vector#(4,Bit#(64))) decompressQ <- mkSizedFIFO(11);
    Vector#(4,Reg#(Bit#(32))) chunk_6k_idx <- replicateM(mkReg(0));
    FIFO#(Vector#(4,Bit#(32))) put_chunk6K_idxQ <- mkFIFO;

    /* interface data */
    Reg#(Int#(7)) noiseMargin <- mkReg(0);
    Reg#(Bit#(32)) totalMatrixCnt <- mkReg(10000);

    /* ZFP comp/decomp modules */
    ZfpCompressIfc compressM <- mkZfpCompress;
    Vector#(4,ZfpDecompressIfc) decompressM <- replicateM(mkZfpDecompress);

    /* Variable / Cycles */
    Reg#(Bit#(32)) compOutputCnt <- mkReg(0);

    /* get original data and put ZFP compress module*/
    rule startCompress;
        compressQ.deq;
        Vector#(4,Bit#(64)) in = compressQ.first;
        compressM.put(in);
    endrule

    Vector#(4,Reg#(Bit#(32))) chunk_idx <- replicateM(mkReg(0));
    Reg#(Bit#(2)) idx_cycle <- mkReg(0);
    Reg#(Bit#(32)) idx_sum <- mkReg(0);
    Reg#(Bit#(1)) idx_trigger <- mkReg(0);
    FIFO#(Vector#(4,Bit#(32))) get_chunk6K_idxQ <- mkFIFO;

    rule get_6k_idx (idx_trigger == 0);
        Bit#(32) idx <- compressM.get_6k_idx;
        Bit#(2) cycle = idx_cycle;
        Bit#(32) sum = idx_sum + idx;

        chunk_idx[cycle] <= chunk_idx[cycle] + idx;

        if (sum == totalMatrixCnt) begin
            idx_sum <= 0;
            idx_cycle <= 0;
            idx_trigger <= 1;
        end else begin
            idx_sum <= sum + idx;
            idx_cycle <= idx_cycle + 1;
        end
    endrule

    rule send_6k_idx (idx_trigger == 1);
        Vector#(4,Bit#(32)) data = replicate(0);
        for (Bit#(4) i = 0; i < 4; i = i + 1) begin
            data[i] = chunk_idx[i];
            chunk_idx[i] <= 0;
        end
        get_chunk6K_idxQ.enq(data);
        idx_trigger <= 0;
    endrule

    rule getCompressedData;
        Bit#(128) comp <- compressM.get;
        hostOutputQ.enq(comp);
    endrule

    /* get compressed data from host and put data to Decompress Moudles(4) */
    Vector#(4,Reg#(Bit#(256))) decompBuf <- replicateM(mkReg(0));
    Vector#(4,Reg#(Bit#(8))) decompOff <- replicateM(mkReg(0));
    Vector#(4,FIFO#(Bit#(48))) toDecompQ <- replicateM(mkSizedFIFO(30));

    /* Get data from host (128bits -> 48bits) */
    for (Bit#(4) i = 0; i < 4; i = i + 1) begin
        rule startDecompress;
            Bit#(256) d_buff = decompBuf[i];
            Bit#(8) d_off = decompOff[i];
            if (d_off < 48) begin
                hostInputQ[i].deq;
                Bit#(128) compressed =  hostInputQ[i].first;
                Bit#(256) temp_buff = zeroExtend(compressed);
                temp_buff = temp_buff << d_off;
                d_buff = d_buff | temp_buff;
                d_off = d_off + 128;
            end else begin
                toDecompQ[i].enq(truncate(d_buff));
                d_buff = d_buff >> 48;
                d_off = d_off - 48;
            end
            decompBuf[i] <= d_buff;
            decompOff[i] <= d_off;
        endrule
    end

    /* Put data to Deompress Module */
    for (Bit#(4) i = 0; i < 4; i = i + 1) begin
        rule putDecompressMoudle;
            toDecompQ[i].deq;
            Bit#(48) data = toDecompQ[i].first;
            decompressM[i].put(data);
        endrule
    end

    Vector#(4,Reg#(Bit#(32))) each_total_matrix <- replicateM(mkReg(0));
    /* put each 4 decompress module total matrix number */
    rule put6K_idx;
        put_chunk6K_idxQ.deq;
        Vector#(4,Bit#(32)) idx = put_chunk6K_idxQ.first;
        for (Bit#(4) i = 0; i < 4; i = i + 1) begin
            each_total_matrix[i] <= idx[i];
            decompressM[i].put_matrix_cnt(idx[i]);
        end
    endrule

    /* Put Decompressed data to BRAMFIFO Buffer */
    Vector#(4,FIFO#(Vector#(4,Bit#(64)))) getDecompQ <- replicateM(mkSizedBRAMFIFO(1000));
    for (Bit#(4) i = 0; i < 4; i = i + 1) begin
        rule putDecompressMoudle;
            Vector#(4,Bit#(64)) in <- decompressM[i].get;
            getDecompQ[i].enq(in);
        endrule
    end

    /* send decompressed data */
    Reg#(Bit#(2)) send_decomp_cycle <- mkReg(0);
    Reg#(Bit#(32)) decomp_cnt <- mkReg(0);
    rule send_decompressed_data;
        Bit#(2) idx = send_decomp_cycle;
        getDecompQ[idx].deq;
        Vector#(4,Bit#(64)) data = getDecompQ[idx].first;
        Bit#(32) cnt = decomp_cnt + 1;
        if (cnt == each_total_matrix[idx]) begin
            idx = idx + 1;
            cnt = 0;
        end
        send_decomp_cycle <= idx;
        decomp_cnt <= cnt;
        decompressQ.enq(data);
    endrule

    /* interface method */
    method Action host_put_1(Bit#(128) data);
        hostInputQ[0].enq(data);
    endmethod
    method Action host_put_2(Bit#(128) data);
        hostInputQ[1].enq(data);
    endmethod
    method Action host_put_3(Bit#(128) data);
        hostInputQ[2].enq(data);
    endmethod
    method Action host_put_4(Bit#(128) data);
        hostInputQ[3].enq(data);
    endmethod
    method ActionValue#(Bit#(128)) host_get;
        hostOutputQ.deq;
        return hostOutputQ.first;
    endmethod
    method ActionValue#(Vector#(4,Bit#(32))) host_get_6k_idx;
        get_chunk6K_idxQ.deq;
        return get_chunk6K_idxQ.first;
    endmethod
    method Action host_put_6k_idx(Vector#(4,Bit#(32)) idx);
        put_chunk6K_idxQ.enq(idx);
    endmethod
    method Action compress(Vector#(4,Bit#(64)) data);
        compressQ.enq(data);
    endmethod
    method ActionValue#(Vector#(4,Bit#(64))) get_decompressed;
        decompressQ.deq;
        return decompressQ.first;
    endmethod
    method Action put_noiseMargin(Int#(7) size);
        noiseMargin <= size;
        compressM.put_noiseMargin(size);
        for (Bit#(4) i = 0; i < 4; i = i + 1) begin
            decompressM[i].put_noiseMargin(size);
        end
    endmethod
    method Action put_matrix_cnt(Bit#(32) cnt);
        totalMatrixCnt <= cnt;
        compressM.put_matrix_cnt(cnt);
    endmethod
endmodule
endpackage

