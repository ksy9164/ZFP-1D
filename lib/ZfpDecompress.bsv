import Connectable::*;
import FIFO::*;
import FIFOF::*;
import Vector::*;


interface ZfpDecompressIfc;
    method Action put(Bit#(48) data);
    method Action put_noiseMargin(Int#(7) data);
    method Action put_matrix_cnt(Bit#(32) cnt);
    method ActionValue#(Vector#(4,Bit#(64))) get;
endinterface
function Bit#(96)catBuf(Bit#(96)in_buf, Bit#(48)d, Bit#(7)in_bufoff);
    Bit#(96) t = zeroExtend(d);
    t = t << in_bufoff;
    in_buf = in_buf | t;
    return in_buf;
endfunction
function Bit#(11)getE(Bit#(96) ibuf);
    Bit#(11) e = 0;
    e = truncate(ibuf);
    return e;
endfunction
function Bit#(48)get_a(Bit#(96) ibuf);
    Bit#(48) e = 0;
    e = truncate(ibuf);
    return e;
endfunction
function Bit#(64) uint_to_int(Bit#(64) t);
    Bit#(64) d = 64'haaaaaaaaaaaaaaaa;
    t = t ^ d;
    t = t - d;
    return t;
endfunction
function Bit#(64)intShiftR(Bit#(64)t);
    Bit#(1) s = t[63];
    t = t >> 1;
    t[63] = s;
    return t;
endfunction
function Bit#(5) get_msb (Bit#(16) d);
    Bit#(5) msb = 0;
    if (d >= 256) begin
        if (d >= 4096) begin
            for (Bit#(5) j = 12; j < 16; j = j+1) begin
                if (d[j] == 1) begin
                    msb = j;
                end
            end   
        end else begin
            for (Bit#(5) j = 8; j < 12; j = j+1) begin
                if (d[j] == 1) begin
                    msb = j;
                end
            end   
        end
    end else begin
        if (d >= 16) begin
            for (Bit#(5) j = 4; j < 8; j = j+1) begin
                if (d[j] == 1) begin
                    msb = j;
                end
            end   
        end else begin
            for (Bit#(5) j = 0; j < 4; j = j+1) begin
                if (d[j] == 1) begin
                    msb = j;
                end
            end   
        end
    end
    return 15 - msb;
endfunction
(* synthesize *)
module mkZfpDecompress (ZfpDecompressIfc);
    /* rule to rule FIFO */
    FIFO#(Bit#(11)) expQ <- mkSizedFIFO(20);
    FIFO#(Bit#(48)) inputQ <- mkFIFO;
    FIFO#(Bit#(11)) toGroupA_E <- mkSizedFIFO(20);
    FIFO#(Bit#(48)) toGroupA_D <- mkSizedFIFO(20);
    FIFO#(Bit#(18)) toGather_B <- mkFIFO;
    FIFO#(Bit#(4)) encodeBudgetQ <- mkFIFO;
    FIFO#(Vector#(3,Bit#(48))) toGather_All <- mkFIFO;
    FIFO#(Vector#(4,Bit#(64))) toConvertBit <- mkFIFO;
    FIFO#(Vector#(4,Bit#(64))) toUnblock_1 <- mkFIFO;
    FIFO#(Vector#(4,Bit#(64))) outputQ <- mkFIFO;
    FIFO#(Vector#(4,Bit#(64))) toUnblock_2 <- mkFIFO;
    FIFO#(Vector#(4,Bit#(64))) toUnblock_3 <- mkFIFO;
    FIFO#(Vector#(4,Bit#(64))) toUnblock_4 <- mkFIFO;
    FIFO#(Vector#(4,Bit#(64))) toDivMSB <- mkFIFO;
    FIFO#(Vector#(4,Bit#(64))) toConvertNega <- mkFIFO;
    FIFO#(Vector#(4,Bit#(1))) signQ <- mkSizedFIFO(20);
    FIFO#(Vector#(4,Bit#(64))) toFindMSB <- mkFIFO;
    FIFO#(Vector#(4,Bit#(2))) toFindMSB_code <- mkFIFO;
    FIFO#(Vector#(4,Bit#(7))) toGetExp_msb <- mkFIFO;
    FIFO#(Vector#(4,Bit#(64))) toGetExp <- mkFIFO;

    Reg#(Int#(7)) noiseMargin <- mkReg(0);
    Reg#(Bit#(4)) encodeBudget <- mkReg(0);
    Reg#(Bit#(4)) gather_cnt <- mkReg(0);
    Reg#(Bit#(4)) budget_cnt <- mkReg(0);
    Reg#(Bit#(2)) inputCycle <- mkReg(0);
    Reg#(Bit#(7)) inputBufOff <- mkReg(0);
    Reg#(Bit#(96)) inputBuf <- mkReg(0);
    Reg#(Bit#(32)) inputCnt <- mkReg(0);
    Reg#(Bit#(16)) chunkAmount <- mkReg(0);
    Reg#(Bit#(32)) totalMatrixCnt <- mkReg(1000);
    Reg#(Bool) flushTrigger <- mkReg(False);

    rule getGroup1_E(inputCycle == 0 && inputCnt != totalMatrixCnt);
        Bit#(7)in_bufoff = inputBufOff;
        Bit#(96)in_buf = inputBuf;
        if (in_bufoff < 48) begin
            inputQ.deq;
            let d = inputQ.first;
            in_buf = catBuf(in_buf,d,in_bufoff);
            in_bufoff = in_bufoff + 48;
        end
        Bit#(11) e = getE(in_buf);
        in_buf = in_buf >> 11;
        in_bufoff = in_bufoff - 11;

        Int#(11) exp_max = unpack(e) + 1023;
        Int#(11) margin = signExtend(noiseMargin);
        Bit#(6) budget = truncate(pack(exp_max + margin));
        Bit#(6) bud_num = 0;
        Bool trigger = flushTrigger;
        
        if (budget == 0) begin
            encodeBudget <= 0;
            encodeBudgetQ.enq(0);
            inputCnt <= inputCnt + 1;
            bud_num = 0;
        end else begin
            bud_num = (budget - 1) / 6 + 1;
            if (bud_num < 9) begin
                encodeBudget <= truncate(bud_num);
                encodeBudgetQ.enq(truncate(bud_num));
            end else begin
                encodeBudget <= 8;
                encodeBudgetQ.enq(8);
            end
        end

        if (chunkAmount > 49152 - 512) begin
            trigger = True;
        end

        chunkAmount <= chunkAmount + 11;
        if (bud_num != 0) begin
            inputCycle <= 1;
        end else if (trigger) begin
            inputCycle <= 3;
        end 

        flushTrigger <= trigger;
        $display("chunk  1 is %d ",chunkAmount);
        toGroupA_E.enq(e);
        inputBuf <= in_buf;
        inputBufOff <= in_bufoff;
    endrule

    FIFO#(Bit#(6)) toShiftA_s_Q <- mkFIFO;
    FIFO#(Bit#(48)) toShiftA_d_Q <- mkFIFO;

    rule getGroup1_D (inputCycle == 1);
        Bit#(7)in_bufoff = inputBufOff;
        Bit#(96)in_buf = inputBuf;
        if (in_bufoff < 48) begin
            inputQ.deq;
            let d = inputQ.first;
            in_buf = catBuf(in_buf,d,in_bufoff);
            in_bufoff = in_bufoff + 48;
        end
        Bit#(48) data_a = get_a(in_buf);
        $display("chunk 2 is %d ",chunkAmount);
        Bit#(6) shift = zeroExtend(encodeBudget) * 6;
        chunkAmount <= chunkAmount + zeroExtend(shift);
        in_buf = in_buf >> shift;
        in_bufoff = in_bufoff - zeroExtend(shift);

        toShiftA_d_Q.enq(data_a);
        toShiftA_s_Q.enq(shift);

        inputBuf <= in_buf;
        inputBufOff <= in_bufoff;
        inputCycle <= 2;
    endrule

    rule shiftA;
        toShiftA_s_Q.deq;
        toShiftA_d_Q.deq;
        Bit#(6) shift = toShiftA_s_Q.first;
        Bit#(48) data = toShiftA_d_Q.first;

        data = data << (48 - shift);
        toGroupA_D.enq(data);
    endrule

    rule getGroup2 (inputCycle == 2);
        Bit#(4) encodingLv = 4;
        Bit#(7) in_bufoff = inputBufOff;
        Bit#(96) in_buf = inputBuf;
        if (in_bufoff < 48) begin
            inputQ.deq;
            let input_d = inputQ.first;
            in_buf = catBuf(in_buf,input_d,in_bufoff);
            in_bufoff = in_bufoff + 48;
        end

        Bit#(4) bud_cnt = budget_cnt;
        Bit#(18) data = 0;
        Bit#(2) header = 0;
        Bit#(16) amount  = 0;

        if (bud_cnt < encodingLv) begin
            header = truncate(in_buf);
            in_buf = in_buf >> 2;
            in_bufoff = in_bufoff - 2;
            amount = 2;
        end else begin
            header = 3;
        end
        $display("chunk 3 is %d ",chunkAmount);

        data = truncate(in_buf);
        case (header)
            0 : begin
                data = 0;
            end
            1 : begin
                data = zeroExtend(data[5:0]);
                in_buf = in_buf >> 6;
                in_bufoff = in_bufoff - 6;
                amount = amount + 6;
            end
            2 : begin
                data = zeroExtend(data[11:0]);
                in_buf = in_buf >> 12;
                in_bufoff = in_bufoff - 12;
                amount = amount + 12;
            end
            3 : begin
                in_buf = in_buf >> 18;
                in_bufoff = in_bufoff - 18;
                amount = amount + 18;
            end
        endcase
        bud_cnt = bud_cnt + 1;

        if (bud_cnt == encodeBudget) begin
            budget_cnt <= 0;
            inputCnt <= inputCnt + 1;
            if (flushTrigger) begin
                inputCycle <= 3;
            end else begin
                inputCycle <= 0;
            end
        end else begin
            budget_cnt <= bud_cnt;
        end

        chunkAmount <= amount + chunkAmount;
        toGather_B.enq(data);
        inputBuf <= in_buf;
        inputBufOff <= in_bufoff;
    endrule

    rule flush6K (inputCycle == 3);
        Bit#(16) amount = chunkAmount;
        inputQ.deq;
        if (inputBufOff != 0) begin
            chunkAmount <= chunkAmount + zeroExtend(inputBufOff) + 48;
            inputBufOff <= 0;
        end else if (amount + 48 == 49152) begin
            inputCycle <= 0;
            flushTrigger <= False;
            inputBufOff <= 0;
            chunkAmount <= 0;
            if (inputCnt == totalMatrixCnt) begin
                inputCnt <= 0;
            end
        end else begin
            chunkAmount <= chunkAmount + 48;
        end
    endrule

    rule last_in_ctl(inputCycle == 0 && inputCnt == totalMatrixCnt);
        inputCycle <= 3;
        inputCnt <= 0;
    endrule

    Vector#(3,Reg#(Bit#(48))) data_groupB <- replicateM(mkReg(0));

    rule gatherB;
        toGather_B.deq;
        Bit#(18) in = toGather_B.first;
        Bit#(4) cnt = gather_cnt;
        Vector#(3,Bit#(48)) data = replicate(0);
        for (Bit#(4) i=0;i<3;i=i+1) begin
            data[i] = data_groupB[i];
        end
        case (cnt)
            0: begin
                data[0][47:42] = in[5:0];
                data[1][47:42] = in[11:6];
                data[2][47:42] = in[17:12];
            end
            1 : begin
                data[0][41:36] = in[5:0];
                data[1][41:36] = in[11:6];
                data[2][41:36] = in[17:12];
            end
            2 : begin
                data[0][35:30] = in[5:0];
                data[1][35:30] = in[11:6];
                data[2][35:30] = in[17:12];
            end
            3 : begin
                data[0][29:24] = in[5:0];
                data[1][29:24] = in[11:6];
                data[2][29:24] = in[17:12];
            end
            4 : begin
                data[0][23:18] = in[5:0];
                data[1][23:18] = in[11:6];
                data[2][23:18] = in[17:12];
            end
            5 : begin
                data[0][17:12] = in[5:0];
                data[1][17:12] = in[11:6];
                data[2][17:12] = in[17:12];
            end
            6 : begin
                data[0][11:6] = in[5:0];
                data[1][11:6] = in[11:6];
                data[2][11:6] = in[17:12];
            end
            7 : begin
                data[0][5:0] = in[5:0];
                data[1][5:0] = in[11:6];
                data[2][5:0] = in[17:12];
            end
        endcase
        if (cnt == encodeBudgetQ.first - 1) begin
            encodeBudgetQ.deq;
            toGather_All.enq(data);
            data = replicate(0);
            gather_cnt <= 0;
        end else begin
            gather_cnt <= cnt + 1;
        end

        for (Bit#(4) i=0;i<3;i=i+1) begin
            data_groupB[i] <= data[i];
        end
    endrule

    rule gather_all;
        toGather_All.deq;
        toGroupA_D.deq;
        Vector#(3,Bit#(48)) data_b = toGather_All.first;
        Bit#(48) data_a = toGroupA_D.first;
        Vector#(4,Bit#(64)) outd = replicate(0);
        outd[0] = zeroExtend(data_a);
        outd[1] = zeroExtend(data_b[0]);
        outd[2] = zeroExtend(data_b[1]);
        outd[3] = zeroExtend(data_b[2]);
        for (Bit#(4) i = 0; i < 4; i = i + 1) begin
            outd[i] = outd[i] << 16;
        end
        toConvertBit.enq(outd);
    endrule

    rule convert;
        toConvertBit.deq;
        Vector#(4,Bit#(64)) d = toConvertBit.first;
        for (Bit#(4) i = 0; i < 4; i = i + 1) begin
            d[i] = uint_to_int(d[i]);
        end
        toUnblock_1.enq(d);
    endrule

    rule unblock_1;
        toUnblock_1.deq;
        Vector#(4,Bit#(64)) d = toUnblock_1.first;
        d[1] = d[1] + intShiftR(d[3]); d[3] = d[3] - intShiftR(d[1]);
        toUnblock_2.enq(d);
    endrule

    rule unblock_2;
        toUnblock_2.deq;
        Vector#(4,Bit#(64)) d = toUnblock_2.first;
        d[1] = d[1] + d[3]; d[3]= d[3] << 1; d[3] = d[3] - d[1];
        d[2] = d[2] + d[0]; d[0]= d[0] << 1; d[0] = d[0] - d[2];
        toUnblock_3.enq(d);
    endrule

    rule unblock_3;
        toUnblock_3.deq;
        Vector#(4,Bit#(64)) d = toUnblock_3.first;
        d[1] = d[1] + d[2]; d[2]= d[2] << 1; d[2] = d[2] - d[1];
        toUnblock_4.enq(d);
    endrule

    rule unblock_4;
        toUnblock_4.deq;
        Vector#(4,Bit#(64)) d = toUnblock_4.first;
        d[3] = d[3] + d[0]; d[0]= d[0] << 1; d[0] = d[0] - d[3];
        toConvertNega.enq(d);
    endrule

    rule convertNega;
        toConvertNega.deq;
        Vector#(4,Bit#(64)) d = toConvertNega.first;
        Vector#(4,Bit#(1)) sign = replicate(0);
        for (Bit#(4) i = 0; i < 4; i = i + 1) begin
            if (d[i][63] == 1) begin
                d[i] = -d[i];
                sign[i] = 1;
            end else begin
                sign[i] = 0;
            end
        end
        toDivMSB.enq(d);
        signQ.enq(sign);
    endrule

    rule divMSB;
        toDivMSB.deq;
        Vector#(4,Bit#(64)) d = toDivMSB.first;
        Vector#(4,Bit#(2)) idx = replicate(0);
        for (Bit#(4) i = 0; i < 4; i = i +1) begin
            if (d[i] >= 281474976710656) begin
                idx[i] = 3;
            end else if (d[i] >= 4294967296) begin
                idx[i] = 2;
            end else if (d[i] >= 65536) begin
                idx[i] = 1;
            end else begin
                idx[i] = 0;
            end
        end
        toFindMSB.enq(d);
        toFindMSB_code.enq(idx);
    endrule

    rule findMSB;
        toFindMSB.deq;
        toFindMSB_code.deq;
        let d = toFindMSB.first;
        let code = toFindMSB_code.first;
        Vector#(4,Bit#(7))msb = replicate(0);

        for (Bit#(4) i = 0; i < 4; i = i +1) begin
            Bit#(2) c = code[i];
            case (c)
                3 : msb[i] = zeroExtend(get_msb(d[i][63:48])) - 2;
                2 : msb[i] = zeroExtend(get_msb(d[i][47:32])) + 16 - 2;
                1 : msb[i] = zeroExtend(get_msb(d[i][31:16])) + 32 - 2;
                0 : msb[i] = zeroExtend(get_msb(d[i][15:0])) + 48 - 2;
            endcase
        end
        toGetExp_msb.enq(msb);
        toGetExp.enq(d);
    endrule

    rule getExp;
        toGroupA_E.deq;
        let e = toGroupA_E.first;
        toGetExp.deq;
        toGetExp_msb.deq;
        signQ.deq;
        Vector#(4,Bit#(64)) d = toGetExp.first;
        Vector#(4,Bit#(7)) msb = toGetExp_msb.first;
        Vector#(4,Bit#(64)) decomp = replicate(0);
        Vector#(4,Bit#(1)) sign = signQ.first;
        for (Bit#(4) i = 0; i < 4; i = i +1) begin
            Bit#(11) exp_double = e - zeroExtend(msb[i]);
            decomp[i][62:52] = exp_double;
            d[i] = d[i] << (msb[i] + 1 +2);
            decomp[i][51:0] = d[i][63:12];
            decomp[i][63] = sign[i];
        end
        outputQ.enq(decomp);
    endrule

    method Action put(Bit#(48) data);
        inputQ.enq(data);
    endmethod
    method ActionValue#(Vector#(4,Bit#(64))) get;
        outputQ.deq;
        return outputQ.first;
    endmethod
    method Action put_noiseMargin(Int#(7) data);
        noiseMargin <= data;
    endmethod
    method Action put_matrix_cnt(Bit#(32) cnt);
        totalMatrixCnt <= cnt;
    endmethod
endmodule
