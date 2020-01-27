import FIFO::*;
import FIFOF::*;
import Vector::*;
import BitShifter::*;

interface ZfpCompressIfc;
    method Action put(Vector#(4, Bit#(64)) data);
    method Action put_noiseMargin(Int#(7) size);
    method Action put_matrix_cnt(Bit#(32) cnt);
    method ActionValue#(Bit#(256)) get;
endinterface

function Bit#(64) uint_to_int(Bit#(64) t);
    Bit#(64) d = 64'haaaaaaaaaaaaaaaa;
    t = t ^ d;
    t = t - d;
    return t;
endfunction

function Bit#(11) get_max(Bit#(11) a, Bit#(11) b, Bit#(11) c, Bit#(11) d);
    if (a >= b && a >= c && a >= d)
        return a;
    else if (b >= a && b >= c && b >= d)
        return b;
    else if (c >= a && c >= b && c >= d)
        return c;
    else
        return d;
endfunction

function Bit#(64) intShift(Bit#(64) t);
    Bit#(1) s;
    s = t[63];
    t = t >> 1;
    t[63] = s;
    return t;
endfunction

function Bit#(64) int_to_uint(Bit#(64) t);
    return (t + 64'haaaaaaaaaaaaaaaa) ^ 64'haaaaaaaaaaaaaaaa;
endfunction

function Bit#(2) get_header(Bit#(18) d);
    if (d == 0) begin
        return 0;
    end else if (d < 64) begin
        return 1;
    end else if (d < 4096) begin
        return 2;
    end else begin
        return 3;
    end
endfunction

function Bit#(5) get_amount(Bit#(2) h);
    Bit#(5) amount = 0;
    case (h)
        0 : amount = 0;
        1 : amount = 6;
        2 : amount = 12;
        3 : amount = 18;
    endcase
    return amount;
endfunction

(* synthesize *)
module mkZfpCompress (ZfpCompressIfc);
    /* Rule to Rule FIFO */
    FIFO#(Vector#(4, Bit#(64))) inputQ <- mkFIFO;
    FIFO#(Bit#(256)) outputQ <- mkSizedFIFO(11);

    Reg#(Int#(7)) noiseMargin <- mkReg(0);
    FIFO#(Vector#(4, Bit#(7))) shiftQ <- mkSizedFIFO(5);

    /* Encoding Size, Cnt */
    Reg#(Bit#(32)) totalMatrixCnt <- mkReg(100);

    // new
    FIFO#(Bit#(11)) sendMaximumExp <- mkSizedFIFO(5);
    FIFO#(Bit#(11)) maximumExp <- mkSizedFIFO(5);
    FIFO#(Bit#(11)) encodingExp <- mkSizedFIFO(41);
    FIFO#(Bit#(11)) encodingExp_post <- mkFIFO;
    FIFO#(Bit#(11)) encodingExp_pre <- mkFIFO;

    FIFO#(Vector#(4, Bit#(64))) toGetFraction <- mkFIFO;
    Vector#(4,FIFO#(Bit#(1))) signQ <- replicateM(mkSizedFIFO(16));
    FIFO#(Bit#(11)) toCalEncodeBudget <- mkSizedFIFO(15);
    FIFO#(Vector#(4, Bit#(64))) toMakeFixedPoint <- mkSizedFIFO(11);
    FIFO#(Vector#(4, Bit#(11))) exp <- mkSizedFIFO(5);
    FIFO#(Vector#(4, Bit#(64))) toSignTrans <- mkFIFO;
    FIFO#(Vector#(4, Bit#(64))) toLift <- mkFIFO;
    FIFO#(Vector#(4, Bit#(64))) toLift_2 <- mkFIFO;
    FIFO#(Vector#(4, Bit#(64))) toLift_3 <- mkFIFO;
    FIFO#(Vector#(4, Bit#(64))) toLift_4 <- mkFIFO;
    FIFO#(Vector#(4, Bit#(64))) toConvertBits <- mkFIFO;
    FIFO#(Vector#(4, Bit#(64))) toShuffle <- mkFIFO;
    Vector#(8,FIFO#(Bit#(18))) toMakeHeader <- replicateM(mkFIFO);
    
    Vector#(8,FIFO#(Bit#(20))) toMerge_1_d <- replicateM(mkFIFO);
    Vector#(8,FIFO#(Bit#(5))) toMerge_1_a <- replicateM(mkFIFO);

    Vector#(4,FIFO#(Bit#(40))) toMerge_2_d <- replicateM(mkFIFO);
    Vector#(4,FIFO#(Bit#(6))) toMerge_2_a <- replicateM(mkFIFO);

    FIFOF#(Bit#(4)) encodeBudgetQ <- mkSizedFIFOF(16);
    FIFO#(Bit#(48)) toOut_Group_1 <- mkSizedFIFO(11);

    Vector#(2,FIFO#(Bit#(4))) toOut_Group_1_bud <- replicateM(mkSizedFIFO(5));
    Vector#(2,FIFO#(Bit#(7))) toOut_Group_1_amount <- replicateM(mkSizedFIFO(5));
    Vector#(2,FIFO#(Bit#(256))) toOut_Group_1_d <- replicateM(mkSizedFIFO(5));

    Vector#(2,FIFO#(Bit#(80))) toOut_Group_2_d <-replicateM(mkFIFO);
    Vector#(2,FIFO#(Bit#(7))) toOut_Group_2_a <- replicateM(mkFIFO);
    
    Vector#(2,FIFO#(Bit#(80))) toOut_Group_3_d <-replicateM(mkFIFO);
    Vector#(2,FIFO#(Bit#(7))) toOut_Group_3_a <- replicateM(mkFIFO);

    Vector#(8,FIFO#(Bit#(1))) budgetMask <- replicateM(mkSizedFIFO(20));
    FIFO#(Bit#(8)) toSend_amount <- mkSizedFIFO(15);
    Vector#(2,FIFO#(Bit#(8))) toSend_amount_pre <- replicateM(mkSizedFIFO(15));

    Vector#(2,Reg#(Bit#(2))) mergeCycle <- replicateM(mkReg(0));

    Vector#(2,ByteShiftIfc#(Bit#(256),8)) pipeShiftL <- replicateM(mkPipelineLeftShifter());

    /* buffer */
    Reg#(Bit#(8)) send_buffer_off <- mkReg(0);
    Reg#(Bit#(256)) send_buffer <- mkReg(0);

    rule getMaxExp;
        inputQ.deq;
        Vector#(4, Bit#(64)) in = inputQ.first;

        Bit#(11) expMax = 0;
        /* Get 256bit data & Calculate current Maximum Exp in this vector
        * Update ExpMax & Dequeue to Next Step (getFraction) */

        Vector#(4, Bit#(11)) matrixExp = replicate(0);
        for (Integer i = 0; i < 4; i = i+1) begin
            matrixExp[i] = truncateLSB(in[i]<<1);
        end
        expMax = get_max(matrixExp[0],matrixExp[1],matrixExp[2],matrixExp[3]);

        toCalEncodeBudget.enq(expMax);
        encodingExp_pre.enq(expMax);
        exp.enq(matrixExp);
        toGetFraction.enq(in);
    endrule

    rule getFraction;
        toGetFraction.deq;
        Vector#(4, Bit#(64)) in = toGetFraction.first;
        Vector#(4, Bit#(64)) outd = replicate(0);
        Vector#(4, Bit#(52)) frac = replicate(0);

        /* Get Fraction from double data be using Bit operation <<, zeroextention, truncate
        * Make output vecotor and send to NextStep which is makeFixedPoint */
        for (Bit#(6) i = 0; i < 4; i = i+1) begin
            outd[i] = in[i] << 11;
            /* Make Signed Extention */
            outd[i][63] = 1;
            signQ[i].enq(in[i][63]);
        end

        toMakeFixedPoint.enq(outd);
    endrule

    Reg#(Bit#(2)) sendExp_handle <- mkReg(0);


    rule calEncodeBudget;
        toCalEncodeBudget.deq;
        Int#(11) exp_max = unpack(toCalEncodeBudget.first) + 1023;
        Int#(11) margin = signExtend(noiseMargin);
        Bit#(6) budget = truncate(pack(exp_max + margin));
        Bit#(6) bud_num = (budget - 1) / 6 + 1;
        
        if (budget == 0) begin
            bud_num = 1;
        end else begin
            if (bud_num  >8) begin
                bud_num = 8;
            end 
        end

        encodeBudgetQ.enq(truncate(bud_num));

        for (Bit#(6)i=0; i<8; i = i+1) begin
            if (i < bud_num) begin
                budgetMask[i].enq(1);
            end else begin
                budgetMask[i].enq(0);
            end
        end
        sendMaximumExp.enq(toCalEncodeBudget.first);
    endrule

    rule calShift;
        sendMaximumExp.deq;
        exp.deq; // Get element's exp
        let exp_max = sendMaximumExp.first;
        let expCurrent = exp.first;
        Vector#(4, Bit#(7)) outd = replicate(0);
        for (Integer i = 0; i < 4; i = i+1) begin
            Bit#(11) term = exp_max - expCurrent[i] + 2;
            Bit#(7) shift = 0;
            if (term > 63) begin
                shift = 64;
            end else begin
                shift = truncate(term);
            end
            outd[i] = shift;
        end
        shiftQ.enq(outd);
    endrule

    rule makeFixedPoint;
        toMakeFixedPoint.deq; // Get 256Bits fraction data
        shiftQ.deq;
        let in = toMakeFixedPoint.first;
        let shift = shiftQ.first;
        Vector#(4, Bit#(64)) outd = replicate(0);
        /* Make Fixed Point by considering maximum Exp in Matrix */
        for (Integer i = 0; i < 4; i = i+1) begin
            if (shift[i] > 48) begin
                outd[i] = 0;
            end else begin
                outd[i] = in[i] >> shift[i];
            end
        end
        toSignTrans.enq(outd);
    endrule

    rule signTrans;
        toSignTrans.deq;
        let in = toSignTrans.first;
        Vector#(4, Bit#(64)) outd = replicate(0);
        for (Bit#(5) i = 0; i < 4; i = i + 1) begin
            signQ[i].deq;
            if (signQ[i].first == 1) begin
                outd[i] = -in[i];
            end else begin
                outd[i] = in[i];
            end
        end
        toLift.enq(outd);
    endrule

    rule lift;
        toLift.deq;
        let in = toLift.first;
        in[0] = (in[0]+in[3]); in[0] = intShift(in[0]); in[3] = (in[3]-in[0]);
        in[2] = (in[2]+in[1]); 
        toLift_2.enq(in);
    endrule
    rule lift_2;
        toLift_2.deq;
        let in = toLift_2.first;
        in[2] = intShift(in[2]); in[1] = (in[1]-in[2]);
        in[0] = (in[0]+in[2]); in[0] = intShift(in[0]);
        toLift_3.enq(in);
    endrule

    rule lift_3;
        toLift_3.deq;
        let in = toLift_3.first;
        in[2] = (in[2]-in[0]);
        in[3] = (in[3]+in[1]); in[3] = intShift(in[3]); in[1] = (in[1]-in[3]);
        toLift_4.enq(in);
    endrule

    rule lift_4;
        toLift_4.deq;
        let in = toLift_4.first;
        in[3] = (in[3]+ intShift(in[1])); in[1] = (in[1] - (intShift(in[3])));
        toConvertBits.enq(in);
    endrule

    rule convertBits;
        toConvertBits.deq;
        Vector#(4, Bit#(64)) in = toConvertBits.first;
        for (Bit#(5)i = 0; i < 4; i = i + 1) begin
            in[i] = int_to_uint(in[i]);
        end
        toShuffle.enq(in);
    endrule

    rule shuffle;
        toShuffle.deq;
        let in = toShuffle.first;
        Vector#(8, Bit#(18)) d = replicate(0);
        for (Bit#(8)i = 0; i < 8; i = i + 1) begin
            Bit#(18) temp = 0;
            temp[5:0] = in[1][(63-i*6):(58-i*6)];
            temp[11:6] = in[2][(63-i*6):(58-i*6)];
            temp[17:12] = in[3][(63-i*6):(58-i*6)];
            toMakeHeader[i].enq(temp);
        end
        toOut_Group_1.enq(truncateLSB(in[0]));
    endrule

    for (Bit#(4)i = 0; i < 8; i = i + 1) begin
        rule makeHeader;
            toMakeHeader[i].deq;
            budgetMask[i].deq;
            let in = toMakeHeader[i].first;
            let mask = budgetMask[i].first;

            Bit#(4) encodingLv = 4;
            Bit#(2) header = get_header(in);
            Bit#(5) amount = get_amount(header);
            Bit#(20) merged = 0;
            if (i < encodingLv) begin
                merged = zeroExtend(in);
                merged = merged << 2;
                merged = merged | zeroExtend(header);
                amount = amount + 2;
            end else begin
                merged = zeroExtend(in);
                amount = 18;
            end
            if (mask == 0) begin
                merged = 0;
                amount = 0;
            end
            toMerge_1_d[i].enq(merged);
            toMerge_1_a[i].enq(amount);
        endrule
    end

    for (Bit#(5)i = 0; i < 4; i = i + 1) begin
        rule merge1;
            toMerge_1_d[i*2].deq;
            toMerge_1_a[i*2].deq;
            toMerge_1_d[i*2+1].deq;
            toMerge_1_a[i*2+1].deq;
            let d1 = toMerge_1_d[i*2].first;
            let d2 = toMerge_1_d[i*2+1].first;
            let a1 = toMerge_1_a[i*2].first;
            let a2 = toMerge_1_a[i*2+1].first;

            Bit#(40) data = 0;
            data = zeroExtend(d2);
            
            /* for 4bits shifter */
            a1 = a1 >> 1;
            a1 = a1 << 1;
            data = data << a1;
            data = data | zeroExtend(d1);

            toMerge_2_d[i].enq(data);
            toMerge_2_a[i].enq(zeroExtend(a1)+zeroExtend(a2));
        endrule
    end

    FIFO#(Bit#(80)) scatter_Group_2_d <-mkFIFO;
    FIFO#(Bit#(7)) scatter_Group_2_a <- mkFIFO;
    FIFO#(Bit#(80)) scatter_Group_3_d <- mkFIFO;
    FIFO#(Bit#(7)) scatter_Group_3_a <- mkFIFO;
    FIFO#(Bit#(4)) scatter_Group_1_bud <- mkSizedFIFO(5);
    FIFO#(Bit#(7)) scatter_Group_1_amount <- mkSizedFIFO(5);
    FIFO#(Bit#(256)) scatter_Group_1_d <- mkSizedFIFO(5);

    for (Bit#(5)i=0; i < 2; i = i + 1) begin
        rule merge2;
            Vector#(4, Bit#(2)) header = replicate(0);
            toMerge_2_d[i*2].deq;
            toMerge_2_a[i*2].deq;
            toMerge_2_d[i*2+1].deq;
            toMerge_2_a[i*2+1].deq;
            let d1 = toMerge_2_d[i*2].first;
            let d2 = toMerge_2_d[i*2+1].first;
            let a1 = toMerge_2_a[i*2].first;
            let a2 = toMerge_2_a[i*2+1].first;

            Bit#(80) data = zeroExtend(d2);
            /* for 5bits shifter */
            a1 = a1 >> 1;
            a1 = a1 << 1;
            data = data << a1;
            data = data | zeroExtend(d1);

            Bit#(7) amount = zeroExtend(a1) + zeroExtend(a2);
            if (i == 0 && amount != 0) begin
                scatter_Group_2_d.enq(data);
                scatter_Group_2_a.enq(amount);
            end else if (i == 1 && amount != 0) begin
                scatter_Group_3_d.enq(data);
                scatter_Group_3_a.enq(amount);
            end
        endrule
    end

    Vector#(2,Reg#(Bit#(4))) currentBudget <- replicateM(mkReg(0));
    Vector#(2,FIFO#(Bit#(1))) scatter_cycleQ<- replicateM(mkSizedFIFO(17));
    Vector#(2,Reg#(Bit#(8))) pipeShifter_off <- replicateM(mkReg(0));
    Reg#(Bit#(32)) inputCnt <- mkReg(0);
    Reg#(Bit#(16)) chunkAmount <- mkReg(0);
    Reg#(Bit#(5)) last_out_trigger <- mkReg(30);
    Reg#(Bit#(1)) scatter_c_1 <- mkReg(0);
    Reg#(Bit#(1)) scatter_c_2 <- mkReg(0);
    Reg#(Bit#(1)) scatter_c_3 <- mkReg(0);
    Reg#(Bool) resetTrigger <- mkReg(False);


    rule encoding_Exp_bridge;
        encodingExp_pre.deq;
        let d = encodingExp_pre.first;
        encodingExp.enq(d);
    endrule

    rule encoding_Exp_post;
        encodingExp.deq;
        let d = encodingExp.first;
        encodingExp_post.enq(d);
    endrule

    rule preOutGroup1;
        toOut_Group_1.deq;
        encodingExp_post.deq;
        encodeBudgetQ.deq;
        let d = toOut_Group_1.first;
        let e = encodingExp_post.first;
        let bud = encodeBudgetQ.first;
        Bit#(7) a = zeroExtend(bud) * 6 + 11;
        Bit#(6) s =  48 - (zeroExtend(bud) * 6);
        d = d >> s;
        Bit#(256) merged = zeroExtend(d);
        merged = merged << 11;
        merged = merged | zeroExtend(e);

        scatter_Group_1_bud.enq(bud);
        scatter_Group_1_amount.enq(a);
        scatter_Group_1_d.enq(merged);
    endrule

    rule scatter_group_1;
        scatter_Group_1_bud.deq;
        scatter_Group_1_amount.deq;
        scatter_Group_1_d.deq;
        Bit#(4) bud = scatter_Group_1_bud.first;
        Bit#(7) amount = scatter_Group_1_amount.first;
        Bit#(256) d = scatter_Group_1_d.first;
        Bit#(1) cycle = scatter_c_1;

        toOut_Group_1_bud[cycle].enq(bud);
        toOut_Group_1_amount[cycle].enq(amount);
        toOut_Group_1_d[cycle].enq(d);

        if (bud != 0) begin
            scatter_cycleQ[0].enq(cycle);
        end
        if (bud > 4) begin
            scatter_cycleQ[1].enq(cycle);
        end

        scatter_c_1 <= scatter_c_1 + 1;
    endrule

    rule scatter_group_2;
        scatter_Group_2_d.deq;
        scatter_Group_2_a.deq;
        scatter_cycleQ[0].deq;
        Bit#(80) d = scatter_Group_2_d.first;
        Bit#(7) amount = scatter_Group_2_a.first;
        Bit#(1) cycle = scatter_cycleQ[0].first;

        toOut_Group_2_d[cycle].enq(d);
        toOut_Group_2_a[cycle].enq(amount);

    endrule

    rule scatter_group_3;
        scatter_Group_3_d.deq;
        scatter_Group_3_a.deq;
        scatter_cycleQ[1].deq;
        Bit#(80) d = scatter_Group_3_d.first;
        Bit#(7) amount = scatter_Group_3_a.first;
        Bit#(1) cycle = scatter_cycleQ[1].first;

        toOut_Group_3_d[cycle].enq(d);
        toOut_Group_3_a[cycle].enq(amount);
    endrule

    Vector#(2,FIFO#(Bit#(1))) check_merge_last <- replicateM(mkSizedFIFO(15));
    // new algorithm
    for (Bit#(2) i = 0; i < 2; i = i + 1) begin
        rule out_Group_1(mergeCycle[i] == 0);
            toOut_Group_1_amount[i].deq;
            toOut_Group_1_d[i].deq;
            toOut_Group_1_bud[i].deq;

            Bit#(7) a = toOut_Group_1_amount[i].first;
            Bit#(256) merged = toOut_Group_1_d[i].first;
            Bit#(4) bud = toOut_Group_1_bud[i].first;

            currentBudget[i] <= bud;
            pipeShiftL[i].rotateBitBy(merged,0);

            if (bud == 0) begin
                check_merge_last[i].enq(1);
                toSend_amount_pre[i].enq(zeroExtend(a));
                pipeShifter_off[i] <= 0;
            end else begin
                check_merge_last[i].enq(0);
                mergeCycle[i] <= mergeCycle[i] + 1;
                pipeShifter_off[i] <= zeroExtend(a);
            end
        endrule
    end

    for (Bit#(2) i = 0; i < 2; i = i + 1) begin
        rule out_Group_2(mergeCycle[i] == 1);
            toOut_Group_2_d[i].deq;
            toOut_Group_2_a[i].deq;
            Bit#(80) d = toOut_Group_2_d[i].first;
            Bit#(8) a = zeroExtend(toOut_Group_2_a[i].first);
            Bit#(8) off = pipeShifter_off[i];

            pipeShiftL[i].rotateBitBy(zeroExtend(d), off);

            if (currentBudget[i] > 4) begin
                check_merge_last[i].enq(0);
                mergeCycle[i] <= mergeCycle[i] + 1;
                pipeShifter_off[i] <= off + a;
            end else begin
                check_merge_last[i].enq(1);
                mergeCycle[i] <= 0;
                toSend_amount_pre[i].enq(off + a);
                pipeShifter_off[i] <= 0;
            end
        endrule
    end

    for (Bit#(2) i = 0; i < 2; i = i + 1) begin
        rule out_Group_3(mergeCycle[i] == 2);
            toOut_Group_3_d[i].deq;
            toOut_Group_3_a[i].deq;
            Bit#(80) d = toOut_Group_3_d[i].first;
            Bit#(8) a = zeroExtend(toOut_Group_3_a[i].first);

            pipeShiftL[i].rotateBitBy(zeroExtend(d), pipeShifter_off[i]);

            a = a + pipeShifter_off[i];
            toSend_amount_pre[i].enq(a);

            check_merge_last[i].enq(1);
            mergeCycle[i] <= 0;
            pipeShifter_off[i] <= 0;
        endrule
    end

    Vector#(2,Reg#(Bit#(256))) encoded_d <- replicateM(mkReg(0));
    FIFO#(Bit#(256)) mergeLastQ <- mkSizedFIFO(5);
    Vector#(2,FIFO#(Bit#(256))) mergeLastQ_pre <- replicateM(mkSizedFIFO(5));
    Reg#(Bit#(1)) merging_last_cycle <- mkReg(0);

    Reg#(Bool) flush_trigger <- mkReg(False);
    for (Bit#(2) i = 0; i < 2; i = i + 1) begin
        rule get_encoded;
            check_merge_last[i].deq;
            Bit#(256) d = encoded_d[i];
            Bit#(256) t <- pipeShiftL[i].getVal;
            Bit#(1) isLast = check_merge_last[i].first;
            d = d | t;
            if (isLast == 1) begin
                mergeLastQ_pre[i].enq(d);
                encoded_d[i] <= 0;
            end else begin
                encoded_d[i] <= d;
            end
        endrule
    end

    FIFO#(Bit#(8)) merging_amount <- mkSizedFIFO(10);
    rule cycle_merge;
        Bit#(1) cycle = merging_last_cycle;
        mergeLastQ_pre[cycle].deq;
        toSend_amount_pre[cycle].deq;
        Bit#(256) d = mergeLastQ_pre[cycle].first;
        Bit#(8) amount = toSend_amount_pre[cycle].first;
        mergeLastQ.enq(d);
        toSend_amount.enq(amount);
        merging_last_cycle <= merging_last_cycle + 1;
    endrule

    ByteShiftIfc#(Bit#(512),8) pipes_last <- mkPipelineLeftShifter();
    Reg#(Bit#(9)) pipes_off <- mkReg(0);

    rule merging_last(!flush_trigger&& inputCnt != totalMatrixCnt);
        mergeLastQ.deq;
        toSend_amount.deq;
        Bit#(8) amount = toSend_amount.first;
        Bit#(256) d = mergeLastQ.first;

        pipes_last.rotateBitBy(zeroExtend(d), truncate(pipes_off));

        if (pipes_off + zeroExtend(amount) >= 256)
            pipes_off <= pipes_off + zeroExtend(amount) - 256;
        else
            pipes_off <= pipes_off + zeroExtend(amount);

        if (chunkAmount > 49152 - 600) begin
            flush_trigger <= True;
        end

        inputCnt <= inputCnt + 1;
        merging_amount.enq(amount);
        chunkAmount <= chunkAmount + zeroExtend(amount);
    endrule

    rule flush_6k(flush_trigger || inputCnt == totalMatrixCnt);
        Bit#(9) a = 0;
        $display("flush chunk num is %d",chunkAmount);
        if (49152 - chunkAmount > 127) begin
            a = 128; 
            chunkAmount <= chunkAmount + 128;
        end else begin
            a = truncate(49152 - chunkAmount);
            chunkAmount <= 0;
            flush_trigger <= False;
            if (inputCnt == totalMatrixCnt) begin
                inputCnt <= 0;
            end
        end

        pipes_last.rotateBitBy(0, truncate(pipes_off));

        if (pipes_off + a >= 256)
            pipes_off <= pipes_off + a - 256;
        else
            pipes_off <= pipes_off + a;

        merging_amount.enq(truncate(a));
    endrule

    Reg#(Bit#(512)) last_buf <- mkReg(0);
    Reg#(Bit#(9)) last_buf_off <- mkReg(0);

    rule send;
        Bit#(512) d = last_buf;
        Bit#(512) t <- pipes_last.getVal;
        d = d | t;
        merging_amount.deq;
        Bit#(9) off = last_buf_off + zeroExtend(merging_amount.first);

        if (off >= 256) begin
            off = off - 256;
            outputQ.enq(d[255:0]);
            d = d >> 256;
        end

        last_buf_off <= off;
        last_buf <= d;
    endrule


    /* Get input from Top.bsv */
    method Action put(Vector#(4, Bit#(64)) data);
        inputQ.enq(data);
    endmethod

    method Action put_noiseMargin(Int#(7) size);
        noiseMargin <= size;
    endmethod

    method Action put_matrix_cnt(Bit#(32) cnt);
        totalMatrixCnt <= cnt;
    endmethod

    /* Send Output to Top.bsv */
    method ActionValue#(Bit#(256)) get;
        outputQ.deq;
        $display("comp is %b",outputQ.first);
        return outputQ.first;
    endmethod
endmodule
