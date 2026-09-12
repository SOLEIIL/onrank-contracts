// Shared world for desk / pot tests: two stock jettons, one USDT jetton, Pot, Collection.
// The "minter" role of the Collection is played by a treasury here; DeskMinter has its own tests.
import "@stdlib/strings"
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/big_array"
import "@acton/types/message"

import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/common/tep-nft"
import "@contracts/desk/desk-messages"
import "@contracts/desk/desk-types"
import "@contracts/pot/pot-messages"
import "@contracts/pot/pot-types"
import "@contracts/vendor/jetton/messages"
import "@contracts/vendor/jetton/storage"
import "@wrappers/DeskCollection.gen"
import "@wrappers/DeskItem.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"
import "@wrappers/Pot.gen"
import "@wrappers/utils"

// Omniston escrow forward payload layout (spikes/s1-omniston/locate-minout.mjs, 2026-09-09):
// op 0xc0a5f0d9, owner address field starts at bit 289 of the root, resolver min-out (Coins) at bit 363 of ref0.
const ESCROW_OP = 0xc0a5f0d9
const ESCROW_OWNER_BIT_OFFSET = 289
const ESCROW_MIN_OUT_REF = 0
const ESCROW_MIN_OUT_BIT_OFFSET = 363
const USDT_UNIT = 1000000 // 6 decimals
const STOCK_UNIT = 100000000 // 8 decimals
/// Test floors: 2 USDT per TON for Convert, 0.001 stock (1e5 units) per USDT for Round.
const FLOOR_USDT_PER_TON = 2 * USDT_UNIT
const FLOOR_STOCK_PER_USDT = STOCK_UNIT / 1000

struct World {
    admin: Treasury
    keeper: Treasury
    minterOp: Treasury
    issuer: Treasury
    /// Plays the DeDust native vault (the only TON destination of a Convert).
    dex: Treasury
    /// Plays the whitelisted DeDust TON/USDT pool.
    pool: Treasury
    escrow: Treasury
    usdt: JettonMinter
    stock0: JettonMinter
    stock1: JettonMinter
    pot: Pot
    collection: DeskCollection
}

fun jettonMetadata(name: string): cell {
    var metadata: OnchainMetadataReply = { contentDict: [] };
    metadata.contentDict.set("uri".sha256(), name.prefixWith00());
    return metadata.toCell();
}

fun deployJetton(issuer: Treasury, name: string): JettonMinter {
    val minter = JettonMinter.fromStorage({
        totalSupply: 0,
        adminAddress: issuer.address,
        nextAdminAddress: null,
        metadata: jettonMetadata(name),
    });
    expect(minter.sendDeploy(issuer.address, { value: ton("1") })).toHaveSuccessfulDeploy({ to: minter.address });
    return minter;
}

fun defaultWhitelist(dex: address, pool: address, escrow: address): PotWhitelist {
    var dexPools: map<address, bool> = createEmptyMap();
    dexPools.set(pool, true);
    return {
        dexVault: dex,
        dexPools,
        escrowMinter: escrow,
        escrowOp: ESCROW_OP,
        escrowOwnerBitOffset: ESCROW_OWNER_BIT_OFFSET,
        escrowMinOutRef: ESCROW_MIN_OUT_REF,
        escrowMinOutBitOffset: ESCROW_MIN_OUT_BIT_OFFSET,
    };
}

fun defaultParams(usdtWallet: address?, whitelist: PotWhitelist): PotParams {
    return {
        usdtWallet,
        reserve: ton("1"),
        threshold: ton("5"),
        maxConvertTon: ton("50"),
        floorUsdtPerTon: FLOOR_USDT_PER_TON,
        maxRoundUsdt: 5000 * USDT_UNIT,
        pendingTimeout: 600,
        whitelist: whitelist.toCell(),
    };
}

/// Smallest `minUsdt` the Pot accepts for a Convert of `spend` TON under the test floor.
fun floorUsdtFor(spend: coins): coins {
    return spend * FLOOR_USDT_PER_TON / 1000000000;
}

/// Smallest `minOut` the Pot accepts for a Round of `spendUsdt` under the test floor.
fun floorStockFor(spendUsdt: coins): coins {
    return spendUsdt * FLOOR_STOCK_PER_USDT / USDT_UNIT;
}

/// Fixed emulation clock: without it Acton mixes wall-clock and mocked `now`,
/// which sporadically yields `now < last_paid` ("cannot create storage phase").
const WORLD_T0: uint32 = 1800000000

fun setupWorld(cap: uint32 = 5000): World {
    testing.setNow(WORLD_T0);
    val admin = testing.treasury("admin");
    val keeper = testing.treasury("keeper");
    val minterOp = testing.treasury("minter-op");
    val issuer = testing.treasury("issuer");
    val dex = testing.treasury("dex");
    val pool = testing.treasury("dex-pool");
    val escrow = testing.treasury("escrow");

    val usdt = deployJetton(issuer, "USDT");
    val stock0 = deployJetton(issuer, "AAPLx");
    val stock1 = deployJetton(issuer, "NVDAx");

    // Pot first (collection unknown yet -> placeholder), then Collection, then wire roles/params.
    val pot = Pot.fromStorage({
        liveDesks: 0,
        rotationNext: 0,
        slotCount: 0,
        roundNo: 0,
        totalTonIn: 0,
        totalTonSpent: 0,
        usdtBudget: 0,
        roles: PotRoles { admin: admin.address, keeper: keeper.address, collection: admin.address, deskItemCode: build("DeskItem") }.toCell(),
        params: defaultParams(null, defaultWhitelist(dex.address, pool.address, escrow.address)).toCell(),
        slots: createEmptyMap(),
        pending: null,
    });
    expect(pot.deploy(admin.address, { value: ton("2"), bounce: false })).toHaveSuccessfulDeploy({ to: pot.address });

    val collection = DeskCollection.fromStorage({
        admin: admin.address,
        minter: minterOp.address,
        pot: pot.address,
        nextSerial: 0,
        cap,
        content: CollectionContent { collectionMetadata: createEmptyCell(), commonContent: "https://meta.test/desk/" }.toCell(),
        deskItemCode: build("DeskItem"),
        royalty: RoyaltyParams { numerator: 500, denominator: 10000, royaltyAddress: pot.address }.toCell(),
    });
    expect(collection.deploy(admin.address, { value: ton("0.5"), bounce: false })).toHaveSuccessfulDeploy({ to: collection.address });

    expect(pot.sendSetPotRoles(
        admin.address,
        0,
        PotRoles { admin: admin.address, keeper: keeper.address, collection: collection.address, deskItemCode: build("DeskItem") },
        { value: ton("0.05") },
    )).toHaveSuccessfulTx<SetPotRoles>({ to: pot.address });

    expect(pot.sendSetPotParams(
        admin.address,
        0,
        defaultParams(usdt.getWalletAddress(pot.address), defaultWhitelist(dex.address, pool.address, escrow.address)),
        { value: ton("0.05") },
    )).toHaveSuccessfulTx<SetPotParams>({ to: pot.address });

    expect(pot.sendAddSlot(admin.address, 0, 0, stock0.address, stock0.getWalletAddress(pot.address), FLOOR_STOCK_PER_USDT, { value: ton("0.05") }))
        .toHaveSuccessfulTx<AddSlot>({ to: pot.address });
    expect(pot.sendAddSlot(admin.address, 0, 1, stock1.address, stock1.getWalletAddress(pot.address), FLOOR_STOCK_PER_USDT, { value: ton("0.05") }))
        .toHaveSuccessfulTx<AddSlot>({ to: pot.address });

    return { admin, keeper, minterOp, issuer, dex, pool, escrow, usdt, stock0, stock1, pot, collection };
}

/// Deploys the next desk for `owner` through the collection (as the minter would) and
/// checks it ended up initialized with stamps.
fun mintDesk(w: World, owner: address): DeskItem {
    val serial = w.collection.getCollectionData().nextItemIndex;
    val res = w.collection.sendDeployDesk(w.minterOp.address, 0, serial, owner, { value: ton("0.2"), bounce: true });
    expect(res).toHaveSuccessfulTx<DeployDesk>({ from: w.minterOp.address, to: w.collection.address });
    val desk = DeskItem.fromAddress(w.collection.getNftAddressByIndex(serial));
    expect(res).toHaveSuccessfulDeploy({ from: w.collection.address, to: desk.address });
    expect(res).toHaveSuccessfulTx<RegisterDesk>({ from: w.collection.address, to: w.pot.address });
    expect(res).toHaveSuccessfulTx<StampsInit>({ from: w.pot.address, to: desk.address });
    expect(desk.getDeskData().stampsReady).toBeTrue();
    return desk;
}

fun stockOf(w: World, slot: int): JettonMinter {
    return slot == 0 ? w.stock0 : w.stock1;
}

/// Stock for `slot` lands in the Pot's jetton wallet (simulates an escrow fill or a donation).
fun arriveStock(w: World, slot: int, amount: int): SendResultList {
    val res = stockOf(w, slot).sendMint(w.issuer.address, w.pot.address, amount, ton("0.05"), ton("0.3"));
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: w.pot.address });
    return res;
}

fun arriveUsdt(w: World, amount: int): SendResultList {
    val res = w.usdt.sendMint(w.issuer.address, w.pot.address, amount, ton("0.05"), ton("0.3"));
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: w.pot.address });
    return res;
}

fun potStockWallet(w: World, slot: int): JettonWallet {
    return stockOf(w, slot).walletOf(w.pot.address);
}

fun deskStockWallet(w: World, slot: int, desk: DeskItem): JettonWallet {
    return stockOf(w, slot).walletOf(desk.address);
}

fun stampOf(desk: DeskItem, slot: int): int {
    val found = desk.getDeskData().stamps.get(slot as uint8);
    return found.isFound ? found.loadValue() : 0;
}

fun sweep(w: World, desk: DeskItem, owner: address, slotsMask: int, value: coins = ton("0.3")): SendResultList {
    return desk.sendSweep(owner, 0, slotsMask, { value, bounce: true });
}

/// Topic encoded in an `ExtOutLogBucket` external address (addr_extern$01 · len 256 · 0x00 · topic 248).
fun topicOf(dest: any_address): int {
    var s = beginCell().storeAddressAny(dest).endCell().beginParse();
    s.skipBits(2 + 9 + 8);
    return s.loadUint(248);
}

/// Number of external log messages emitted by `from` on `topic` across the whole trace.
fun countEvents(res: SendResultList, from: address, topic: int): int {
    var n = 0;
    var txIdx = 0;
    repeat (res.size()) {
        val externals = res.at(txIdx).externals;
        var i = 0;
        repeat (externals.size()) {
            val ext = (externals.get(i) as Cell<TlbMessage<RemainingBitsAndRefs, TlbExternalOutMessageInfo>>).load();
            if (ext.info.src == from && topicOf(ext.info.dest) == topic) {
                n += 1;
            }
            i += 1;
        }
        txIdx += 1;
    }
    return n;
}

/// First external log message emitted by `from` on `topic`, decoded as `T`.
fun findEvent<T>(res: SendResultList, from: address, topic: int): T? {
    var txIdx = 0;
    repeat (res.size()) {
        val externals = res.at(txIdx).externals;
        var i = 0;
        repeat (externals.size()) {
            val ext = (externals.get(i) as Cell<TlbMessage<RemainingBitsAndRefs, TlbExternalOutMessageInfo>>).load();
            if (ext.info.src == from && topicOf(ext.info.dest) == topic) {
                return T.fromSlice(ext.loadBody());
            }
            i += 1;
        }
        txIdx += 1;
    }
    return null;
}

/// Synthetic Omniston escrow payload mirroring the real layout: op, filler, owner address at bit 289,
/// trailing data; ref0 = escrow params with the resolver min-out (Coins) at bit 363.
fun escrowPayloadFor(owner: address, minOut: coins = 0): cell {
    return beginCell()
        .storeUint(ESCROW_OP, 32)
        .storeUint(0, 256)
        .storeUint(0, ESCROW_OWNER_BIT_OFFSET - 32 - 256)
        .storeAddress(owner)
        .storeUint(0xdead, 64)
        .storeRef(escrowParamsWithMinOut(minOut))
        .storeRef(beginCell().storeUint(1, 8).endCell())
        .endCell();
}

fun escrowParamsWithMinOut(minOut: coins): cell {
    return beginCell()
        .storeUint(0, 256)
        .storeUint(0, ESCROW_MIN_OUT_BIT_OFFSET - 256)
        .storeCoins(minOut)
        .storeUint(0, 16)
        .endCell();
}
