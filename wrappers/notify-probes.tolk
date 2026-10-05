// Hand-written the same way `acton wrapper` emits wrappers. Test sinks only.
import "@acton/build"
import "@acton/emulation/network"
import "@acton/testing/assert"
import "@contracts/test/NotifyProbe"
import "@contracts/test/StrictNotify"

struct NotifyProbe {
    address: address
    stateInit: ContractState? = null
}

fun NotifyProbe.fromStorage(
    storage: NotifyProbeStorage,
    toShard: AddressShardingOptions? = null,
): NotifyProbe {
    val stateInit = ContractState {
        code: build("NotifyProbe"),
        data: storage.toCell(),
    };
    val address = AutoDeployAddress { stateInit, toShard }.calculateAddress();
    return NotifyProbe { address, stateInit };
}

fun NotifyProbe.deploy(self, from: address, config: SendParams = {}): SendResultList {
    if (self.stateInit == null) {
        Assert.fail("Cannot deploy NotifyProbe without state init");
    }
    return net.send(
        from,
        createMessage({ bounce: config.bounce, value: config.value, dest: {
                stateInit: self.stateInit,
            } }),
    );
}

fun NotifyProbe.getNotifyProbe(self): (uint32, coins) {
    return net.runGetMethod(self.address, "get_notify_probe");
}

struct StrictNotify {
    address: address
    stateInit: ContractState? = null
}

fun StrictNotify.fromStorage(
    storage: StrictNotifyStorage,
    toShard: AddressShardingOptions? = null,
): StrictNotify {
    val stateInit = ContractState {
        code: build("StrictNotify"),
        data: storage.toCell(),
    };
    val address = AutoDeployAddress { stateInit, toShard }.calculateAddress();
    return StrictNotify { address, stateInit };
}

fun StrictNotify.deploy(self, from: address, config: SendParams = {}): SendResultList {
    if (self.stateInit == null) {
        Assert.fail("Cannot deploy StrictNotify without state init");
    }
    return net.send(
        from,
        createMessage({ bounce: config.bounce, value: config.value, dest: {
                stateInit: self.stateInit,
            } }),
    );
}

fun StrictNotify.getStrictNotify(self): (uint32, coins) {
    return net.runGetMethod(self.address, "get_strict_notify");
}
