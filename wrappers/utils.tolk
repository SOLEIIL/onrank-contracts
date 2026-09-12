// Hand-written helpers on top of the generated wrappers (kept in sync manually).
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@contracts/vendor/jetton/jetton-utils"
import "@contracts/vendor/jetton/messages"
import "@contracts/vendor/jetton/storage"
import "JettonMinter.gen"
import "JettonWallet.gen"

/// The generated deploy() sends an empty body; the minter expects TopUpTons.
fun JettonMinter.sendDeploy(self, from: address, params: SendParams): SendResultList {
    val outMessage = createMessage({
        bounce: false,
        value: params.value,
        dest: { stateInit: self.stateInit! },
        body: TopUpTons {},
    });
    return net.send(from, outMessage);
}

/// Mint `jettonAmount` to `recipient`; the recipient's wallet notifies its owner when
/// `forwardTonAmount > 0` (this is how tests simulate stock / USDT arriving at the Pot).
fun JettonMinter.sendMint(
    self,
    from: address,
    recipient: address,
    jettonAmount: int,
    forwardTonAmount: int,
    totalTonAmount: int,
    customPayload: cell? = null,
): SendResultList {
    val forwardPayload = beginCell().storeMaybeRef(customPayload).endCell().beginParse();
    val outMessage = createMessage({
        bounce: false,
        value: totalTonAmount + ton("0.015"),
        dest: self.address,
        body: MintNewJettons {
            queryId: 0,
            mintRecipient: recipient,
            tonAmount: totalTonAmount,
            internalTransferMsg: InternalTransferStep {
                queryId: 0,
                jettonAmount,
                transferInitiator: null,
                sendExcessesTo: self.address,
                forwardTonAmount,
                forwardPayload,
            }.toCell(),
        },
    });
    return net.send(from, outMessage);
}

fun JettonMinter.getTotalSupply(self): int {
    return self.getJettonData().totalSupply;
}

fun JettonMinter.walletOf(self, owner: address): JettonWallet {
    return JettonWallet { address: self.getWalletAddress(owner) };
}

fun JettonWallet.getJettonBalance(self): coins {
    if (!scripts.isContractDeployed(self.address)) {
        return 0;
    }
    val result: JettonWalletDataReply = net.runGetMethod(self.address, "get_wallet_data");
    return result.jettonBalance;
}

/// Standard transfer; forward payload wrapped in a ref (Either right).
fun JettonWallet.sendTransfer(
    self,
    from: address,
    value: int,
    jettonAmount: int,
    recipient: address,
    responseAddress: address,
    customPayload: cell?,
    forwardTonAmount: int,
    forwardPayload: cell?,
): SendResultList {
    val outMessage = createMessage({
        bounce: true,
        value,
        dest: self.address,
        body: AskToTransfer {
            queryId: 0,
            jettonAmount,
            transferRecipient: recipient,
            sendExcessesTo: responseAddress,
            customPayload,
            forwardTonAmount,
            forwardPayload: beginCell().storeMaybeRef(forwardPayload).endCell().beginParse(),
        },
    });
    return net.send(from, outMessage);
}
