// Local helper for the future gas station. Not used by the live factory.
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@wrappers/GasStation.gen"
import "@contracts/launcher-dex/gas-station-types"

fun deployGasStation(admin: address, ledger: address, keeper: address, value: coins): GasStation {
    var creators: map<address, uint32> = createEmptyMap();
    val station = GasStation.fromStorage({
        roles: GasStationRoles { ledger, keeper, admin }.toCell(),
        params: GasStationParams {
            floatMax: ton("30"),
            pullAmount: ton("10"),
            factory: null,
        }.toCell(),
        paused: false,
        lastPullAt: 0,
        proposal: null,
        creators,
    });
    expect(
        station.deploy(admin, { value, bounce: false }),
    ).toHaveSuccessfulDeploy({ to: station.address });
    return station;
}

fun bindFactory(station: GasStation, admin: address, factory: address) {
    expect(
        station.sendAny(
            admin,
            SetGasFactory {
                queryId: 1,
                factory,
            }.toCell(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveSuccessfulTx<SetGasFactory>({ to: station.address });
}
