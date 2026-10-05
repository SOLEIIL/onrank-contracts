import "creator-fee-storage"
import "dedust-pool"
import "../common/errors"
import "../launcher-v2/fee-splitter-messages"
import "../vendor/jetton/messages"

// Future factory only. The DeDust creator fee is native GRAM. This contract forwards that
// GRAM as FeeIn and does nothing else. Not deployed.

/// Native GRAM in. `amount` is the creator fee. Gas on top is not part of the fee.
struct (0x43550021) CreatorFeeIn {
    queryId: uint64
    amount: coins
}

/// Keeper -> this contract. The pool, the recipient and the excess address are not in the body.
struct (0x43550022) AskCreatorClaim {
    queryId: uint64
}

/// Forwarded to the pool. Measured claim that cleared a 0.3996004 GRAM fee.
const CLAIM_FORWARD = ton("0.5")
/// What the keeper attaches: the forward, plus gas for this contract.
const CLAIM_ATTACH = ton("0.55")

/// FeeSplitter spends 0.03 on the split. This contract keeps the rest of the attached gas.
const CREATOR_FEE_ATTACH = ton("0.05")
/// Same bar as the splitter. Below this, a payout stays here. One send when the pile is large enough.
const CREATOR_FEE_MIN = ton("0.1")

contract CreatorFee {
    author: "GRAMDESKS"
    version: "3.0.0"
    description: "Forwards one native GRAM creator fee to the coin FeeSplitter as FeeIn. Future factory only. Not deployed."
    storage: CreatorFeeStorage
}

fun onBouncedMessage(in: InMessageBounced) {
    // A refused claim returns the 0.5 GRAM. Do not parse it and do not throw.
    if (in.bouncedBody.remainingBitsCount() >= 0) {
        return;
    }
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }
    val opcode = in.body.preloadUint(32);
    if (opcode == 0x43550022) {
        val storage = lazy CreatorFeeStorage.load();
        assert (in.senderAddress == storage.keeper) throw Errors.NotFromKeeper;
        assert (in.valueCoins >= CLAIM_ATTACH) throw Errors.InsufficientValue;
        val ask = AskCreatorClaim.fromSlice(in.body);
        val claim = createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            dest: calcDedustPool(storage.master, contract.getAddress()),
            value: CLAIM_FORWARD,
            body: DedustClaimCreatorFees {
                queryId: ask.queryId,
                to: contract.getAddress(),
                excessesTo: storage.keeper,
            },
        });
        claim.send(SEND_MODE_PAY_FEES_SEPARATELY);
        return;
    }
    if (opcode == 0x3216ca09) {
        // Opcode actually read on the pool's creator-fee payout (trace body starts at 0x190b6504).
        var storage = CreatorFeeStorage.load();
        storage.accrued += in.valueCoins;
        if (
            storage.accrued >= CREATOR_FEE_MIN &&
            contract.getOriginalBalance() >= storage.accrued + ton("0.03")
        ) {
            val fee = storage.accrued;
            storage.accrued = 0;
            storage.save();
            val out = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: storage.splitter,
                value: fee + ton("0.03"),
                body: FeeIn {
                    queryId: 0,
                    amount: fee,
                },
            });
            out.send(SEND_MODE_PAY_FEES_SEPARATELY);
        } else {
            storage.save();
        }
        return;
    }
    if (opcode == 0x43550021) {
        val storage = lazy CreatorFeeStorage.load();
        val msg = CreatorFeeIn.fromSlice(in.body);
        assert (msg.amount > 0) throw Errors.BudgetExceeded;
        assert (in.valueCoins >= msg.amount + CREATOR_FEE_ATTACH) throw Errors.InsufficientValue;
        val fee = createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            dest: storage.splitter,
            value: msg.amount + ton("0.03"),
            body: FeeIn {
                queryId: msg.queryId,
                amount: msg.amount,
            },
        });
        fee.send(SEND_MODE_PAY_FEES_SEPARATELY);
        return;
    }
    if (opcode == 0xd372158c) {
        return;
    }
    throw 0xFFFF;
}

struct CreatorFeeData {
    splitter: address
    accrued: coins
}

get fun get_creator_fee_data(): CreatorFeeData {
    val storage = lazy CreatorFeeStorage.load();
    return { splitter: storage.splitter, accrued: storage.accrued };
}
