// Gas station for future coins. Already-launched coins do not pay it.
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@tests/fixtures"
import "@tests/gas-station-fixtures"
import "@wrappers/CreatorFee.gen"
import "@wrappers/FeeSplitterV2.gen"
import "@wrappers/GasStation.gen"
import "@contracts/common/errors"
import "@contracts/launcher-dex/creator-fee-storage"
import "@contracts/launcher-dex/gas-station-types"
import "@contracts/launcher-v2/fee-splitter-types"
import "@contracts/vendor/jetton/messages"

const T0 = 1800000000

fun fresh(adminName: string, keeperName: string, value: coins): (GasStation, address, address) {
    testing.setNow(T0);
    val admin = testing.treasury(adminName);
    val keeper = testing.treasury(keeperName);
    val station = deployGasStation(admin.address, admin.address, keeper.address, value);
    return (station, admin.address, keeper.address);
}

get fun `test gas station: 0.015 legs stack, and only the excess over 30 goes to the ledger`() {
    val (station, admin, _keeper) = fresh("float-admin", "float-keeper", ton("0.05"));
    val ledger = admin;
    val ledgerBefore = testing.getAccountBalance(ledger);
    var i = 0;
    while (i < 3) {
        expect(
            station.sendAny(admin, createEmptyCell(), { value: ton("0.015"), bounce: false }),
        ).toHaveSuccessfulTx({ to: station.address });
        i = i + 1;
    }
    expect(testing.getAccountBalance(ledger) == ledgerBefore).toBeTrue();
    expect(testing.getAccountBalance(station.address) < ton("30")).toBeTrue();
    val topUp = ton("30");
    expect(
        station.sendAny(admin, createEmptyCell(), { value: topUp, bounce: false }),
    ).toHaveTx<TopUpTons>({ from: station.address, to: ledger });
    val left = testing.getAccountBalance(station.address);
    expect(left <= ton("30")).toBeTrue();
    expect(left > ton("29.99")).toBeTrue();
    expect(testing.getAccountBalance(ledger) - ledgerBefore > 0).toBeTrue();
}

get fun `test gas station: pull sends 10 once a day`() {
    val (station, _admin, keeper) = fresh("pull-admin", "pull-keeper", ton("25"));
    val first = station.sendAny(
        keeper,
        PullGas { queryId: 1 }.toCell(),
        { value: ton("0.05"), bounce: true },
    );
    expect(first).toHaveTx<TopUpTons>({ from: station.address, to: keeper, value: ton("10") });
    val second = station.sendAny(
        keeper,
        PullGas { queryId: 2 }.toCell(),
        { value: ton("0.05"), bounce: true },
    );
    expect(
        second,
    ).toHaveFailedTx<PullGas>({ to: station.address, exitCode: Errors.PendingNotExpired });
    testing.setNow(T0 + 86400);
    val third = station.sendAny(
        keeper,
        PullGas { queryId: 3 }.toCell(),
        { value: ton("0.05"), bounce: true },
    );
    expect(third).toHaveTx<TopUpTons>({ from: station.address, to: keeper, value: ton("10") });
}

get fun `test gas station: a stranger is rejected and the body has no destination`() {
    val (station, admin, keeper) = fresh("stranger-admin", "stranger-keeper", ton("20"));
    val stranger = testing.treasury("stranger-wallet");
    expect(
        station.sendAny(
            stranger.address,
            PullGas { queryId: 1 }.toCell(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveFailedTx<PullGas>({ to: station.address, exitCode: Errors.NotFromKeeper });
    val body = PullGas { queryId: 7 }.toCell();
    val ok = station.sendAny(keeper, body, { value: ton("0.05"), bounce: true });
    expect(ok).toHaveTx<TopUpTons>({ from: station.address, to: keeper, value: ton("10") });
}

get fun `test gas station: 0.12 does not pay below the reserve or under 0.1`() {
    val (station, _admin, keeper) = fresh("dust-admin", "dust-keeper", ton("0.12"));
    val before = testing.getAccountBalance(station.address);
    val res = station.sendAny(
        keeper,
        PullGas { queryId: 1 }.toCell(),
        { value: ton("0.05"), bounce: true },
    );
    expect(res).toHaveFailedTx<PullGas>({ to: station.address, exitCode: Errors.BelowThreshold });
    val after = testing.getAccountBalance(station.address);
    expect(after > ton("0.05")).toBeTrue();
    expect(after < before + ton("0.05")).toBeTrue();
}

get fun `test gas station: refill pays 0.05 once a day and leaves fees untouched`() {
    testing.setNow(T0);
    val admin = testing.treasury("refill-admin");
    val keeper = testing.treasury("refill-keeper");
    val factory = testing.treasury("refill-factory");
    val vault = testing.treasury("refill-vault");
    val pot = testing.treasury("refill-pot");
    val buyback = testing.treasury("refill-buyback");
    val station = deployGasStation(admin.address, admin.address, keeper.address, ton("1"));
    bindFactory(station, admin.address, factory.address);
    val splitter = FeeSplitterV2.fromStorage({
        admin: admin.address,
        active: true,
        locked: 0,
        accrued: 0,
        totalIn: 0,
        minSplit: ton("0.1"),
        minProtocolBps: 1000,
        routes: FeeRoutes {
            protocol: station.address,
            pot: pot.address,
            buyback: buyback.address,
        }.toCell(),
        reward: RewardRoute {
            vault: vault.address,
            splits: {
                holdersBps: 7000,
                protocolBps: 1500,
                potBps: 1000,
                buybackBps: 500,
            },
        }.toCell(),
        proposal: null,
    });
    expect(
        splitter.deploy(admin.address, { value: ton("0.1"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: splitter.address });
    val creator = CreatorFee.fromStorage({
        splitter: splitter.address,
        accrued: 0,
        master: admin.address,
        keeper: keeper.address,
    });
    expect(
        creator.deploy(admin.address, { value: ton("0.05"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: creator.address });
    expect(
        station.sendAny(
            factory.address,
            RegisterCreator {
                queryId: 1,
                creator: creator.address,
            }.toCell(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveSuccessfulTx<RegisterCreator>({ to: station.address });
    val paid = station.sendAny(
        keeper.address,
        RefillCreator {
            queryId: 2,
            creator: creator.address,
        }.toCell(),
        { value: ton("0.05"), bounce: true },
    );
    expect(
        paid,
    ).toHaveTx<TopUpTons>({ from: station.address, to: creator.address, value: ton("0.05") });
    expect(creator.getCreatorFeeData().accrued == 0).toBeTrue();
    expect(splitter.getSplitterData().totalIn == 0).toBeTrue();
    expect(
        station.sendAny(
            keeper.address,
            RefillCreator {
                queryId: 3,
                creator: creator.address,
            }.toCell(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveFailedTx<RefillCreator>({ to: station.address, exitCode: Errors.PendingNotExpired });
    val unknown = testing.treasury("refill-unknown");
    expect(
        station.sendAny(
            keeper.address,
            RefillCreator {
                queryId: 4,
                creator: unknown.address,
            }.toCell(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveFailedTx<RefillCreator>({ to: station.address, exitCode: Errors.DestNotWhitelisted });
}

get fun `test gas station: pause stops a pull, and the ledger rotates the keeper`() {
    val (station, admin, keeper) = fresh("pause-admin", "pause-keeper", ton("20"));
    expect(
        station.sendAny(
            admin,
            SetGasPaused {
                queryId: 1,
                paused: true,
            }.toCell(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveSuccessfulTx<SetGasPaused>({ to: station.address });
    expect(
        station.sendAny(
            keeper,
            PullGas { queryId: 2 }.toCell(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveFailedTx<PullGas>({ to: station.address, exitCode: Errors.FactoryPaused });
    expect(
        station.sendAny(
            admin,
            SetGasPaused {
                queryId: 3,
                paused: false,
            }.toCell(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveSuccessfulTx<SetGasPaused>({ to: station.address });
    val next = testing.treasury("pause-next");
    expect(
        station.sendAny(
            admin,
            SetGasKeeper {
                queryId: 4,
                keeper: next.address,
            }.toCell(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveSuccessfulTx<SetGasKeeper>({ to: station.address });
    expect(
        station.sendAny(
            keeper,
            PullGas { queryId: 5 }.toCell(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveFailedTx<PullGas>({ to: station.address, exitCode: Errors.NotFromKeeper });
    expect(
        station.sendAny(
            next.address,
            PullGas { queryId: 6 }.toCell(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveTx<TopUpTons>({ from: station.address, to: next.address, value: ton("10") });
}

get fun `test gas station: raising the pull waits 48 hours, lowering it does not`() {
    val (station, admin, _keeper) = fresh("caps-admin", "caps-keeper", ton("1"));
    expect(
        station.sendAny(
            admin,
            ProposeGasCaps {
                queryId: 1,
                floatMax: ton("30"),
                pullAmount: ton("20"),
            }.toCell(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveSuccessfulTx<ProposeGasCaps>({ to: station.address });
    expect(
        station.sendAny(
            admin,
            ApplyGasCaps { queryId: 2 }.toCell(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveFailedTx<ApplyGasCaps>({ to: station.address, exitCode: Errors.PendingNotExpired });
    expect(station.getGasStationData().pullAmount == ton("10")).toBeTrue();
    expect(
        station.sendAny(
            admin,
            LowerGasPull {
                queryId: 3,
                pullAmount: ton("5"),
            }.toCell(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveSuccessfulTx<LowerGasPull>({ to: station.address });
    expect(station.getGasStationData().pullAmount == ton("5")).toBeTrue();
    testing.setNow(T0 + 172800);
    expect(
        station.sendAny(
            admin,
            ApplyGasCaps { queryId: 4 }.toCell(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveSuccessfulTx<ApplyGasCaps>({ to: station.address });
    expect(station.getGasStationData().pullAmount == ton("20")).toBeTrue();
    expect(station.getGasStationData().floatMax == ton("30")).toBeTrue();
}
