// Loads the real DeDust CPMM v2 library. No broadcast, no fork, no homemade pool.
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/launcher-dex/dedust-pool"

struct SimulationPoolData {
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

get fun `test dedust pool: the library loads and the base fee is 10 bps`() {
    loadDedustLibraries();
    val from = testing.treasury("dedust-pool-from");
    val minter = testing.treasury("dedust-pool-minter");
    val creator = testing.treasury("dedust-pool-creator");
    val pool = calcDedustPool(minter.address, creator.address);
    val res = net.send(
        from.address,
        createMessage({
            bounce: true,
            value: ton("0.5"),
            dest: pool,
            body: DedustInit {
                queryId: 1,
                customPayload: null,
            },
        }),
    );
    expect(res).toHaveSuccessfulTx<DedustInit>({ to: pool.calculateAddress() });
    val data = net.runGetMethod<SimulationPoolData>(pool.calculateAddress(), "get_pool_data");
    expect(data.baseFeeBPS).toEqual(DEDUST_BASE_FEE_BPS as int);
    var cfg = buildDedustPoolConfig(minter.address, creator.address).beginParse();
    cfg.loadUint(2);
    cfg.loadAddress();
    cfg.loadAddress();
    expect(cfg.loadUint(16)).toEqual(DEDUST_BASE_FEE_BPS as int);
    expect(cfg.loadUint(16)).toEqual(DEDUST_CREATOR_FEE_BPS as int);
}
