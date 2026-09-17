import "@contracts/common/errors"
import "@contracts/predict/predict-messages"
import "@contracts/predict/predict-types"

contract BetPosition {
    author: "GRAMDESKS"
    version: "1.1.0"
    description: "Deterministic per-bettor position for a parimutuel Market: accumulates the owner's YES/NO stakes and authorises a single, trustless claim. Holds no pool funds — the Market does."
    storage: BetPositionStorage
    incomingMessages: AllowedMessageToBetPosition
}

type AllowedMessageToBetPosition =
    | RecordBet
    | Claim
    | ClaimAck

/// Gas the owner must attach to a Claim: it funds the ClaimPayout to the market, the payout send and the ack back.
const POSITION_CLAIM_GAS = ton("0.03")
/// Storage reserve the position keeps for rent; anything above it is returned to the owner after each market write.
const POSITION_RESERVE = ton("0.01")

/// Send everything above POSITION_RESERVE back to the owner. Nothing the market forwards us (BET_GAS on RecordBet,
/// the claim's leftover on ClaimAck) stays stuck here. Ignore-errors: a refund too small for its forward fee is skipped.
fun refundExcess(owner: address, queryId: uint64) {
    reserveToncoinsOnBalance(POSITION_RESERVE, RESERVE_MODE_AT_MOST);
    val back = createMessage({
        bounce: BounceMode.NoBounce,
        dest: owner,
        value: 0,
        body: PositionExcess { queryId },
    });
    back.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

fun onInternalMessage(in: InMessage) {
    var storage = lazy BetPositionStorage.load();
    val msg = lazy AllowedMessageToBetPosition.fromSlice(in.body);

    match (msg) {
        // The market is the single source of truth for stakes: it computes the stake from the value it received and
        // tells us. Only the market can write here.
        RecordBet => {
            assert (in.senderAddress == storage.market) throw Errors.NotFromMarket;
            if (msg.isYes) {
                storage.yes += msg.amount;
            } else {
                storage.no += msg.amount;
            }
            storage.save();
            refundExcess(storage.owner, msg.queryId);
        }

        Claim => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            assert (!storage.claimed) throw Errors.AlreadyClaimed;
            assert (!storage.claiming) throw Errors.ClaimInFlight;
            assert (in.valueCoins >= POSITION_CLAIM_GAS) throw Errors.InsufficientValue;
            storage.claiming = true;
            storage.save();
            // The market recomputes our address from `owner` to authenticate these amounts; they cannot be forged.
            val req = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: storage.market,
                value: 0,
                body: ClaimPayout {
                    queryId: msg.queryId,
                    owner: storage.owner,
                    yes: storage.yes,
                    no: storage.no,
                },
            });
            req.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        ClaimAck => {
            assert (in.senderAddress == storage.market) throw Errors.NotFromMarket;
            storage.claimed = true;
            storage.claiming = false;
            storage.save();
            refundExcess(storage.owner, msg.queryId);
        }

        else => {
            // Deployment and plain TON top-ups (empty body) are accepted; any unknown opcode bounces.
            assert (in.body.isEmpty()) throw 0xFFFF;
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    var storage = lazy BetPositionStorage.load();
    in.bouncedBody.skipBouncedPrefix();
    val op = in.bouncedBody.loadUint(32);
    // The market refused the claim (e.g. not resolved yet): clear the in-flight flag so the owner can retry.
    if (op == 0x50440005) {
        storage.claiming = false;
        storage.save();
    }
}

get fun get_bet_position_data(): BetPositionDataReply {
    val storage = lazy BetPositionStorage.load();
    return {
        market: storage.market,
        owner: storage.owner,
        yes: storage.yes,
        no: storage.no,
        claimed: storage.claimed,
        claiming: storage.claiming,
    };
}
