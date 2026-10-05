// The keeper asks CreatorFee, which is the only address the pool will pay.
import "@acton/build"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/big_array"
import "@acton/types/message"
import "@acton/types/transaction"

import "@tests/fixtures"
import "@tests/gas-station-fixtures"
import "@wrappers/CreatorFee.gen"
import "@wrappers/CurveDex.gen"
import "@wrappers/FactoryDex.gen"
import "@wrappers/FeeSink.gen"
import "@wrappers/FeeSplitterV2.gen"
import "@wrappers/GasStation.gen"
import "@wrappers/RewardMasterDex.gen"
import "@wrappers/RewardWalletDex.gen"
import "@contracts/common/errors"
import "@contracts/launcher-dex/CreatorFee"
import "@contracts/launcher-dex/FactoryDex"
import "@contracts/launcher-dex/dedust-pool"
import "@contracts/launcher-dex/dividend-messages"
import "@contracts/launcher-v2/fee-splitter-messages"
import "@contracts/launcher-v2/launcher-messages"
import "@contracts/launcher-v2/launcher-types"

struct (0xc442500f) DedustSwap {
    minimalAmountOut: coins
    deadline: uint40
    next: cell?
    partnerConfig: cell?
    referrerConfig: cell?
}

struct SeenPool {
    status: int
    depositActive: bool
    swapActive: bool
    assetX: slice
    assetY: slice
    walletsByAssets: cell?
    assetsByWallets: cell?
    walletsResolutions: cell?
    baseFeeBPS: int
    reserveX: coins
    reserveY: coins
    liquidity: coins
    protocolFeeX: coins
    protocolFeeY: coins
    creatorFeeX: coins
    creatorFeeY: coins
    xLPFeePerToken: int
    yLPFeePerToken: int
    rewards: cell?
}

struct SeenPosition {
    poolAddress: address
    ownerAddress: address
    liquidity: coins
    lockedLiquidity: coins
    rewards: cell?
    xPending: coins
    yPending: coins
    xFeePerTokenCheckpoint: int
    yFeePerTokenCheckpoint: int
}

fun loadDedustLibraries() {
    val pool = build("DeDustPool", "tests/data/dedust-pool-v2.boc");
    val deposit = build("DeDustDeposit", "tests/data/dedust-deposit-v2.boc");
    val position = build("DeDustPosition", "tests/data/dedust-position-v2.boc");
    expect(pool.hash()).toEqual(DEDUST_POOL_V2_LIBRARY_HASH);
    expect(deposit.hash()).toEqual(DEDUST_DEPOSIT_V2_LIBRARY_HASH);
    expect(position.hash()).toEqual(DEDUST_POSITION_V2_LIBRARY_HASH);
    testing.registerLibrary(pool);
    testing.registerLibrary(deposit);
    testing.registerLibrary(position);
}

fun readPool(pool: address): SeenPool {
    return net.runGetMethod<SeenPool>(pool, "get_pool_data");
}

fun sliceHasCoins(root: slice, target: int, depth: int): bool {
    if (depth > 6) {
        return false;
    }
    var cur = root;
    while (cur.remainingBitsCount() >= 4) {
        val len = cur.preloadUint(4);
        if (len >= 1 && len <= 16 && cur.remainingBitsCount() >= 4 + len * 8) {
            var view = cur;
            view.loadUint(4);
            var value = 0;
            repeat (len) {
                value = value * 256 + view.loadUint(8);
            }
            if (value == target) {
                return true;
            }
        }
        cur.loadUint(1);
    }
    val refs = cur.remainingRefsCount();
    repeat (refs) {
        if (sliceHasCoins(cur.loadRef().beginParse(), target, depth + 1)) {
            return true;
        }
    }
    return false;
}

fun assertSwapEvent(res: SendResultList, before: SeenPool) {
    var sawEvent = false;
    var carried = 0;
    var txIdx = 0;
    repeat (res.size()) {
        val step = res.at(txIdx);
        var i = 0;
        repeat (step.outMessages.size()) {
            val cell = step.outMessages.get(i) as cell;
            val head = cell.beginParse();
            if (head.remainingBitsCount() >= 2 && head.preloadUint(2) == 0b11) {
                val ext = (cell as Cell<
                    TlbMessage<RemainingBitsAndRefs, TlbExternalOutMessageInfo>,
                >).load();
                var body = ext.loadBody();
                if (body.remainingBitsCount() >= 32 && body.preloadUint(32) == 0x78e79ba4) {
                    sawEvent = true;
                    body.loadUint(32);
                    val xToY = body.loadBool();
                    val amountIn = body.loadCoins();
                    val amountOut = body.loadCoins();
                    body.loadAddress();
                    body.loadAddress();
                    var next = body.loadRef().beginParse();
                    var fees = body.loadRef().beginParse();
                    val isX = fees.loadBool();
                    val lpFee = fees.loadCoins();
                    val creatorFee = fees.loadCoins();
                    val protocolFee = fees.loadCoins();
                    val partnerFee = fees.loadCoins();
                    val referrerFee = fees.loadCoins();
                    val reserveX = next.loadCoins();
                    next.loadCoins();
                    next.loadCoins();
                    var accrued = next.loadRef().beginParse();
                    val protocolFeeX = accrued.loadCoins();
                    val protocolFeeY = accrued.loadCoins();
                    val creatorFeeX = accrued.loadCoins();
                    val creatorFeeY = accrued.loadCoins();
                    println(
                        "swap fees isX {} lp {} creator {} protocol {}",
                        isX,
                        lpFee,
                        creatorFee,
                        protocolFee,
                    );
                    println("swap fees partner {} referrer {}", partnerFee, referrerFee);
                    println(
                        "pool fees X creator {} protocol {} Y creator {} protocol {}",
                        creatorFeeX,
                        protocolFeeX,
                        creatorFeeY,
                        protocolFeeY,
                    );
                    expect(xToY).toBeTrue();
                    expect(amountIn).toEqual(ton("1000"));
                    expect(amountOut).toEqual(80972512261197891);
                    expect(isX).toBeTrue();
                    expect(lpFee).toEqual(399600400);
                    expect(creatorFee).toEqual(399600400);
                    expect(protocolFee).toEqual(199800200);
                    expect(partnerFee).toEqual(0);
                    expect(referrerFee).toEqual(0);
                    expect(fees.remainingBitsCount()).toEqual(0);
                    expect(reserveX - before.reserveX).toEqual(999000999000);
                    expect(creatorFeeX - before.creatorFeeX).toEqual(399600400);
                    expect(protocolFeeX - before.protocolFeeX).toEqual(199800200);
                    expect(creatorFeeY).toEqual(before.creatorFeeY);
                    expect(protocolFeeY).toEqual(before.protocolFeeY);
                }
            } else if (head.remainingBitsCount() >= 1 && head.preloadUint(1) == 0) {
                val msg = (cell as Cell<
                    TlbMessage<RemainingBitsAndRefs, TlbInternalMessage>,
                >).load();
                val body = msg.loadBody();
                val op: int = body.remainingBitsCount() >= 32 ? body.preloadUint(32) : -1;
                if (sliceHasCoins(body, 399600400, 0)) {
                    println("internal carries 399600400 op {} grams {}", op, msg.info.value.grams);
                    carried += 1;
                }
            }
            i += 1;
        }
        txIdx += 1;
    }
    expect(sawEvent).toBeTrue();
    expect(carried).toEqual(0);
}

fun dumpOut(tx: TlbTransaction) {
    val msgs = tx.messages.load().outMsgs;
    var it = msgs.findFirst();
    while (it.isFound) {
        val message = it.loadValue().load();
        var body = message.body;
        val bits = body.remainingBitsCount();
        val opcode: int = bits >= 32 ? body.loadUint(32) : -1;
        val left = body.remainingBitsCount();
        val query: int = left >= 64 ? body.loadUint(64) : -1;
        println(
            "out grams {} bounced {} bits {}",
            message.info.value.grams,
            message.info.bounced,
            bits,
        );
        println("opcode {} query {} left {}", opcode, query, body.remainingBitsCount());
        it = msgs.iterateNext(it);
    }
}

get fun `test dedust claim: a swap accrues a creator fee and the payout body is recorded`() {
    loadDedustLibraries();
    testing.setNow(WORLD_T0);
    val admin = testing.treasury("clm-admin");
    val protocol = testing.treasury("clm-protocol");
    val vault = testing.treasury("clm-vault");
    val pot = testing.treasury("clm-pot");
    val buyback = testing.treasury("clm-buyback");
    val buyer = testing.treasury("clm-buyer");
    val stranger = testing.treasury("clm-stranger");
    val excess = testing.treasury("clm-excess");
    val keeper = testing.treasury("clm-keeper");
    val station = deployGasStation(admin.address, protocol.address, keeper.address, ton("0.05"));
    val factory = FactoryDex.fromStorage({
        admin: admin.address,
        protocol: protocol.address,
        station: station.address,
        nextSeq: 1,
        codes: FactoryDexCodes {
            masterCode: build("RewardMasterDex"),
            curveCode: build("CurveDex"),
            splitterCode: build("FeeSplitterV2"),
            more: FactoryDexCodesMore {
                creatorCode: build("CreatorFee"),
                walletCode: build("RewardWalletDex"),
            }.toCell(),
        }.toCell(),
        last: null,
        keeper: FactoryDexKeeper { keeper: keeper.address }.toCell(),
    });
    expect(
        factory.deploy(admin.address, { value: ton("0.1"), bounce: false }),
    ).toHaveSuccessfulDeploy({
        to: factory.address,
    });
    bindFactory(station, admin.address, factory.address);
    val launched = factory.sendLaunchDex(
        admin.address,
        1,
        jettonMetadata("COIN"),
        vault.address,
        pot.address,
        buyback.address,
        { value: ton("1"), bounce: true },
    );
    expect(launched).toHaveSuccessfulTx<OpenCurve>({ to: factory.getFactoryDexData().lastCurve! });
    val curve = CurveDex.fromAddress(factory.getFactoryDexData().lastCurve!);
    val master = factory.getFactoryDexData().lastMaster!;
    val creator = factory.getFactoryDexData().lastCreator!;
    val pool = calcDedustPool(master, creator).calculateAddress();
    expect(
        net.send(
            factory.address,
            createMessage({
                bounce: true,
                value: ton("0.15"),
                dest: curve.address,
                body: ExcludeFromDividends {
                    queryId: 2,
                    owner: pool,
                },
            }),
        ),
    ).toHaveSuccessfulTx<SetDividendExcluded>({ from: curve.address, to: master });
    val bought = curve.sendBuy(buyer.address, 3, 0, null, { value: ton("1700"), bounce: true });
    expect(bought).toHaveSuccessfulTx<DedustPayNative>({ from: curve.address, to: pool });
    expect(
        net.send(
            factory.address,
            createMessage({
                bounce: true,
                value: ton("0.1"),
                dest: curve.address,
                body: ConfirmDedustDeposit { queryId: 9 },
            }),
        ),
    ).toHaveSuccessfulTx<DedustPositionState>({ to: curve.address });
    val before = readPool(pool);
    val buyerWallet = RewardWalletDex.fromAddress(
        RewardMasterDex.fromAddress(master).getWalletAddress(buyer.address),
    );
    val jetsBefore = buyerWallet.getRewardWalletData().balance;
    val swap = net.send(
        buyer.address,
        createMessage({
            bounce: true,
            value: ton("1000") + ton("0.15"),
            dest: pool,
            body: DedustPayNative {
                queryId: 11,
                amount: ton("1000"),
                paymentPayload: DedustSwap {
                    minimalAmountOut: 1,
                    deadline: 1800003600,
                    next: null,
                    partnerConfig: null,
                    referrerConfig: null,
                }.toCell() as cell,
                payoutConfig: dedustPayout(buyer.address),
            },
        }),
    );
    expect(swap).toHaveSuccessfulTx<DedustPayNative>({ to: pool });
    expect(buyerWallet.getRewardWalletData().balance - jetsBefore).toEqual(80972512261197891);
    assertSwapEvent(swap, before);
    val after = readPool(pool);
    val dx = after.creatorFeeX - before.creatorFeeX;
    val dy = after.creatorFeeY - before.creatorFeeY;
    println("creator fee delta X {} Y {}", dx, dy);
    expect(dx).toEqual(399600400);
    expect(dy).toEqual(0);
    expect(after.reserveX - before.reserveX).toEqual(999000999000);
    expect(after.protocolFeeX - before.protocolFeeX).toEqual(199800200);
    expect(dx > 0 || dy > 0).toBeTrue();
    val position = net.runGetMethod<address>(pool, "get_position_address", [curve.address]);
    val lp = net.runGetMethod<SeenPosition>(position, "get_position_data");
    println("lp pending X {} Y {}", lp.xPending, lp.yPending);

    val sink = FeeSink.fromStorage({ hits: 0, opcode: 0, value: 0, body: null });
    expect(
        sink.deploy(admin.address, { value: ton("0.05"), bounce: false }),
    ).toHaveSuccessfulDeploy({
        to: sink.address,
    });
    val strangerClaim = net.send(
        stranger.address,
        createMessage({
            bounce: true,
            value: ton("0.5"),
            dest: pool,
            body: DedustClaimCreatorFees {
                queryId: 20,
                to: sink.address,
                excessesTo: excess.address,
            },
        }),
    );
    val strangerTx = strangerClaim.findTransaction<DedustClaimCreatorFees>({ to: pool });
    println("stranger claim fees {}", strangerTx!.totalFees.grams);
    println("stranger outs");
    dumpOut(strangerTx!);
    val mid = readPool(pool);
    println(
        "after stranger X {} Y {} sink hits {} empty {}",
        mid.creatorFeeX - before.creatorFeeX,
        mid.creatorFeeY - before.creatorFeeY,
        sink.getFeeSink().hits,
        sink.getFeeSink().body == null,
    );
    expect(mid.creatorFeeX).toEqual(after.creatorFeeX);
    expect(mid.creatorFeeY).toEqual(after.creatorFeeY);
    val poolBefore = testing.getAccountBalance(pool);
    val excessBefore = testing.getAccountBalance(excess.address);
    val sinkBefore = testing.getAccountBalance(sink.address);
    val splitter = FeeSplitterV2.fromAddress(factory.getFactoryDexData().lastSplitter!);
    val totalBefore = splitter.getSplitterData().totalIn;
    val creatorContract = CreatorFee.fromAddress(creator);
    expect(
        creatorContract.sendAny(
            stranger.address,
            AskCreatorClaim { queryId: 19 }.toCell(),
            { value: ton("0.55"), bounce: true },
        ),
    ).toHaveFailedTx<AskCreatorClaim>({ to: creator, exitCode: Errors.NotFromKeeper });
    val creatorClaim = creatorContract.sendAny(
        keeper.address,
        AskCreatorClaim { queryId: 21 }.toCell(),
        { value: ton("0.55"), bounce: true },
    );
    expect(creatorClaim).toHaveSuccessfulTx<DedustClaimCreatorFees>({ from: creator, to: pool });
    println("creator outs");
    dumpOut(creatorClaim.findTransaction<DedustClaimCreatorFees>({ to: pool })!);
    expect(creatorClaim).toHaveTx<FeeIn>({
        from: creator,
        to: splitter.address,
        value: dx + ton("0.03"),
    });
    expect(splitter.getSplitterData().totalIn - totalBefore).toEqual(dx);
    val paid = creatorClaim.findTransaction<FeeIn>({ from: creator, to: splitter.address });
    println("feein query {}", paid!.loadBody<FeeIn>().queryId);
    val seen = sink.getFeeSink();
    println(
        "payout hits {} opcode {} value {} empty {}",
        seen.hits,
        seen.opcode,
        seen.value,
        seen.body == null,
    );
    println(
        "balances excess {} pool {} sink {}",
        testing.getAccountBalance(excess.address) - excessBefore,
        testing.getAccountBalance(pool) - poolBefore,
        testing.getAccountBalance(sink.address) - sinkBefore,
    );
    val claimTx = creatorClaim.findTransaction<DedustClaimCreatorFees>({ to: pool });
    println("creator outs");
    dumpOut(claimTx!);
    val end = readPool(pool);
    println("creator fee left X {} Y {}", end.creatorFeeX, end.creatorFeeY);
    expect(end.creatorFeeX).toEqual(0);
    expect(end.creatorFeeY).toEqual(0);
    val foreign = net.send(
        stranger.address,
        createMessage({
            bounce: true,
            value: ton("0.02"),
            dest: creator,
            body: beginCell().storeUint(0x11111111, 32).endCell(),
        }),
    );
    expect(foreign).toHaveFailedTx({ to: creator, exitCode: 0xFFFF });
    expect(splitter.getSplitterData().totalIn - totalBefore).toEqual(dx);
}

get fun `test dedust claim: a payout under 0.1 GRAM stays on the creator contract`() {
    loadDedustLibraries();
    testing.setNow(WORLD_T0);
    val admin = testing.treasury("hold-admin");
    val protocol = testing.treasury("hold-protocol");
    val vault = testing.treasury("hold-vault");
    val pot = testing.treasury("hold-pot");
    val buyback = testing.treasury("hold-buyback");
    val buyer = testing.treasury("hold-buyer");
    val excess = testing.treasury("hold-excess");
    val keeper = testing.treasury("hold-keeper");
    val station = deployGasStation(admin.address, protocol.address, keeper.address, ton("0.05"));
    val factory = FactoryDex.fromStorage({
        admin: admin.address,
        protocol: protocol.address,
        station: station.address,
        nextSeq: 1,
        codes: FactoryDexCodes {
            masterCode: build("RewardMasterDex"),
            curveCode: build("CurveDex"),
            splitterCode: build("FeeSplitterV2"),
            more: FactoryDexCodesMore {
                creatorCode: build("CreatorFee"),
                walletCode: build("RewardWalletDex"),
            }.toCell(),
        }.toCell(),
        last: null,
        keeper: FactoryDexKeeper { keeper: keeper.address }.toCell(),
    });
    expect(
        factory.deploy(admin.address, { value: ton("0.1"), bounce: false }),
    ).toHaveSuccessfulDeploy({
        to: factory.address,
    });
    bindFactory(station, admin.address, factory.address);
    expect(
        factory.sendLaunchDex(
            admin.address,
            1,
            jettonMetadata("COIN"),
            vault.address,
            pot.address,
            buyback.address,
            { value: ton("1"), bounce: true },
        ),
    ).toHaveSuccessfulTx<OpenCurve>({ to: factory.getFactoryDexData().lastCurve! });
    val curve = CurveDex.fromAddress(factory.getFactoryDexData().lastCurve!);
    val master = factory.getFactoryDexData().lastMaster!;
    val creator = factory.getFactoryDexData().lastCreator!;
    val pool = calcDedustPool(master, creator).calculateAddress();
    expect(
        net.send(
            factory.address,
            createMessage({
                bounce: true,
                value: ton("0.15"),
                dest: curve.address,
                body: ExcludeFromDividends {
                    queryId: 2,
                    owner: pool,
                },
            }),
        ),
    ).toHaveSuccessfulTx<SetDividendExcluded>({ from: curve.address, to: master });
    expect(
        curve.sendBuy(buyer.address, 3, 0, null, { value: ton("1700"), bounce: true }),
    ).toHaveSuccessfulTx<DedustPayNative>({ from: curve.address, to: pool });
    expect(
        net.send(
            factory.address,
            createMessage({
                bounce: true,
                value: ton("0.1"),
                dest: curve.address,
                body: ConfirmDedustDeposit { queryId: 9 },
            }),
        ),
    ).toHaveSuccessfulTx<DedustPositionState>({ to: curve.address });
    val splitter = FeeSplitterV2.fromAddress(factory.getFactoryDexData().lastSplitter!);
    val totalBefore = splitter.getSplitterData().totalIn;
    expect(
        net.send(
            buyer.address,
            createMessage({
                bounce: true,
                value: ton("20.2"),
                dest: pool,
                body: DedustPayNative {
                    queryId: 11,
                    amount: ton("20"),
                    paymentPayload: DedustSwap {
                        minimalAmountOut: 1,
                        deadline: 1800003600,
                        next: null,
                        partnerConfig: null,
                        referrerConfig: null,
                    }.toCell() as cell,
                    payoutConfig: dedustPayout(buyer.address),
                },
            }),
        ),
    ).toHaveSuccessfulTx<DedustPayNative>({ to: pool });
    val due = readPool(pool).creatorFeeX;
    expect(due > 0 && due < ton("0.1")).toBeTrue();
    val claim = net.send(
        creator,
        createMessage({
            bounce: true,
            value: ton("0.5"),
            dest: pool,
            body: DedustClaimCreatorFees {
                queryId: 21,
                to: creator,
                excessesTo: excess.address,
            },
        }),
    );
    expect(claim).toHaveSuccessfulTx<DedustClaimCreatorFees>({ from: creator, to: pool });
    expect(readPool(pool).creatorFeeX).toEqual(0);
    expect(CreatorFee.fromAddress(creator).getCreatorFeeData().accrued).toEqual(due);
    expect(splitter.getSplitterData().totalIn).toEqual(totalBefore);
}
