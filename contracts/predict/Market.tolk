import "@gen/BetPosition.code"
import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/predict/predict-messages"
import "@contracts/predict/predict-types"

contract Market {
    author: "GRAMDESKS"
    version: "1.1.0"
    description: "Parimutuel prediction market on GRAM. Holds the YES/NO pools, enforces the betting window and oracle-gated resolution, pays the house fee to the immutable Ledger wallet, and lets winners claim trustlessly through their BetPosition."
    storage: MarketStorage
    incomingMessages: AllowedMessageToMarket
}

type AllowedMessageToMarket =
    | PlaceBet
    | LockOpen
    | Resolve
    | ForceVoid
    | ClaimPayout
    | SweepHouse

// Economics, in one place:
//   - The house fee (feeBps of the pot) is taken at resolution, whatever route a bet came in through. A partner cut
//     (partnerBps of a partner bet's gross) is taken on entry and paid at once; the net joins the common pool.
//   - "Self-partnering" — a bettor naming their own wallet as `partner` — is deliberately allowed and harmless: they
//     pay PARTNER_GAS to get partnerBps of their own stake back, their net stake is smaller, the pot and the house fee
//     are computed on nets exactly as for a native bet. The house never loses a nano to it; the off-chain partner
//     registry only governs API keys, CORS and the dashboard, never the money.
//   - Every payout is sent with SEND_MODE_BOUNCE_ON_ACTION_FAIL: a payment that cannot leave rolls the whole
//     transaction back (a Resolve whose HousePayout fails is not "resolved", a ClaimPayout whose WinPayout fails
//     bounces to the position which clears `claiming`). The market can never owe more than it holds: it pays only
//     from the pot it recorded, forward fees come from its reserve (deployValue + gas left by messages).
//   - Budgets (BET_GAS, MARKET_GAS, PARTNER_GAS, the oracle's message value, the position's claim gas) are checked
//     against the emulator's fees with 25% headroom in tests/predict-gas.test.tolk.
//
// v1.1 (pre-mainnet audit):
//   - PlaceBet keeps MARKET_GAS (0.005) in the market: its own compute + the BetPlacedEvent no longer eat the reserve.
//   - The oracle is refused as `partner`, like the house and the market itself (BadPartner).
//   - LockOpen is refused on a resolved market (AlreadyResolved): a late lock after ForceVoid cannot touch storage.
//   - BetPosition returns everything above POSITION_RESERVE to its owner after RecordBet and ClaimAck (no stuck gas).

/// Gas kept from a PlaceBet value to deploy/record the bettor's position (the rest of the value is the stake).
const BET_GAS = ton("0.02")
/// Gas a PlaceBet leaves in the market for its own compute and the BetPlacedEvent (neither forwarded nor refunded).
const MARKET_GAS = ton("0.005")
/// Extra gas a PARTNER bet leaves in the market: it pays the forward fee of the PartnerPayout sent on the spot, so
/// integrations never drain the reserve that funds everyone's payouts (the bettor pays for the route they chose).
const PARTNER_GAS = ton("0.005")
/// Allowed distance (seconds) between an oracle price's publishTime and the market's open/resolve instants.
const ORACLE_EPS = 300
/// After resolvesAt + this, anyone may ForceVoid a market the oracle never resolved (full refunds).
const VOID_GRACE = 3600

fun positionCode(): cell {
    return betPositionCompiledCode();
}

fun emitEvent<T>(topic: int, body: T) {
    val ev = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: topic as uint248 },
        body,
    });
    ev.send(SEND_MODE_REGULAR);
}

fun onInternalMessage(in: InMessage) {
    var storage = lazy MarketStorage.load();
    val msg = lazy AllowedMessageToMarket.fromSlice(in.body);

    match (msg) {
        PlaceBet => {
            val cfg = lazy storage.config.load();
            assert (!storage.resolved) throw Errors.AlreadyResolved;
            // an up/down window needs its reference locked first; a price target compares to its fixed threshold
            assert (storage.openSet || cfg.kind == KIND_HIT) throw Errors.OpenNotLocked;
            assert (blockchain.now() < cfg.closesAt) throw Errors.BettingClosed;
            val lim = lazy cfg.limits.load();
            val kept = msg.partner != null ? BET_GAS + MARKET_GAS + PARTNER_GAS : BET_GAS + MARKET_GAS;
            assert (in.valueCoins > kept) throw Errors.InsufficientValue;
            val gross = (in.valueCoins - kept) as coins;

            // Integration surcharge: the partner's cut leaves the stake here, the net joins the common pool, so every
            // bettor faces the same odds whatever app they came from.
            var partnerFee: coins = 0;
            if (msg.partner != null) {
                assert (
                    msg.partner! != cfg.house && msg.partner! != contract.getAddress() &&
                    msg.partner! != cfg.oracle
                ) throw Errors.BadPartner;
                partnerFee = partnerFeeOf(gross, cfg.partnerBps as int);
            }
            val stake = (gross - partnerFee) as coins;
            assert (stake >= lim.minBet) throw Errors.BetTooSmall;
            assert (lim.maxBet == 0 || stake <= lim.maxBet) throw Errors.BetTooLarge;
            val newTotal = storage.poolYes + storage.poolNo + stake;
            assert (lim.maxPool == 0 || newTotal <= lim.maxPool) throw Errors.PoolCapReached;

            if (msg.isYes) {
                storage.poolYes += stake;
            } else {
                storage.poolNo += stake;
            }
            storage.save();

            // The stake stays in the pot (we send BET_GAS out and keep MARKET_GAS); forward it to deploy/record the position.
            val rec = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: calcDeployedBetPosition(
                    contract.getAddress(),
                    in.senderAddress,
                    positionCode(),
                ),
                value: BET_GAS,
                body: RecordBet {
                    queryId: msg.queryId,
                    isYes: msg.isYes,
                    amount: stake,
                },
            });
            rec.send(SEND_MODE_REGULAR);

            var cut: Cell<PartnerCut>? = null;
            if (msg.partner != null) {
                cut = PartnerCut {
                    partner: msg.partner!,
                    fee: partnerFee,
                }.toCell();
                if (partnerFee > 0) {
                    // Exact amount to the partner; the forward fee comes from PARTNER_GAS the bettor just left here.
                    // Bounce-on-fail: if this cannot be paid, the whole bet reverts rather than pooling an unpaid cut.
                    val pay = createMessage({
                        bounce: BounceMode.NoBounce,
                        dest: msg.partner!,
                        value: partnerFee,
                        body: PartnerPayout {
                            queryId: msg.queryId,
                            amount: partnerFee,
                        },
                    });
                    pay.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
                }
            }

            emitEvent(
                EVENT_TOPIC_BET_PLACED,
                BetPlacedEvent {
                    owner: in.senderAddress,
                    isYes: msg.isYes,
                    amount: stake,
                    poolYes: storage.poolYes,
                    poolNo: storage.poolNo,
                    partner: cut,
                },
            );
        }

        LockOpen => {
            val cfg = lazy storage.config.load();
            assert (in.senderAddress == cfg.oracle) throw Errors.NotFromOracle;
            assert (!storage.resolved) throw Errors.AlreadyResolved;
            assert (!storage.openSet) throw Errors.OpenAlreadyLocked;
            assert (
                msg.publishTime + ORACLE_EPS >= cfg.openAt &&
                msg.publishTime <= cfg.openAt + ORACLE_EPS
            ) throw Errors.StaleOraclePrice;
            storage.openPrice = msg.price;
            storage.openSet = true;
            storage.proof = MarketProof {
                openPublishTime: msg.publishTime,
                closePublishTime: 0,
                openAttestation: msg.attestation,
                closeAttestation: 0,
            }.toCell();
            storage.save();
            emitEvent(
                EVENT_TOPIC_MARKET_OPENED,
                MarketOpenedEvent {
                    openPrice: msg.price,
                    publishTime: msg.publishTime,
                    attestation: msg.attestation,
                },
            );
        }

        Resolve => {
            val cfg = lazy storage.config.load();
            assert (in.senderAddress == cfg.oracle) throw Errors.NotFromOracle;
            assert (!storage.resolved) throw Errors.AlreadyResolved;
            val now = blockchain.now();
            var outcome = OUTCOME_VOID;
            if (cfg.kind == KIND_HIT) {
                if (now < cfg.resolvesAt) {
                    // Early resolution = a touch: only a price at/above the target, published about now, inside the window.
                    assert (msg.price >= cfg.threshold) throw Errors.TargetNotReached;
                    assert (
                        msg.publishTime + ORACLE_EPS >= now && msg.publishTime <= now + ORACLE_EPS
                    ) throw Errors.StaleOraclePrice;
                    assert (
                        msg.publishTime + ORACLE_EPS >= cfg.openAt
                    ) throw Errors.StaleOraclePrice;
                } else {
                    // Deadline: the price at the deadline decides (a touch the oracle never posted does not count).
                    assert (
                        msg.publishTime + ORACLE_EPS >= cfg.resolvesAt &&
                        msg.publishTime <= cfg.resolvesAt + ORACLE_EPS
                    ) throw Errors.StaleOraclePrice;
                }
                if (!oneSided(storage.poolYes, storage.poolNo)) {
                    outcome = msg.price >= cfg.threshold ? OUTCOME_YES : OUTCOME_NO;
                }
            } else {
                assert (now >= cfg.resolvesAt) throw Errors.NotYetResolvable;
                assert (
                    msg.publishTime + ORACLE_EPS >= cfg.resolvesAt &&
                    msg.publishTime <= cfg.resolvesAt + ORACLE_EPS
                ) throw Errors.StaleOraclePrice;
                // A real, two-sided game with a locked reference and a strict move decides YES/NO; anything else refunds.
                if (
                    storage.openSet && !oneSided(storage.poolYes, storage.poolNo) &&
                    msg.price != storage.openPrice
                ) {
                    outcome = msg.price > storage.openPrice ? OUTCOME_YES : OUTCOME_NO;
                }
            }
            storage.closePrice = msg.price;
            storage.outcome = outcome as uint8;
            storage.resolved = true;
            // Extend the audit trail with the close-price proof (the open proof was written at LockOpen).
            var pr = storage.proof != null
                ? storage.proof.load()
                : MarketProof {
                    openPublishTime: 0,
                    closePublishTime: 0,
                    openAttestation: 0,
                    closeAttestation: 0,
                };
            pr.closePublishTime = msg.publishTime;
            pr.closeAttestation = msg.attestation;
            storage.proof = pr.toCell();
            storage.save();

            val fee = houseFeeOf(
                storage.outcome,
                cfg.feeBps as int,
                storage.poolYes,
                storage.poolNo,
            );
            if (fee > 0) {
                // Straight to the Ledger, exact amount (gas paid from the market's headroom, not from the pot owed).
                // Bounce-on-fail: a resolution whose fee cannot leave is rolled back whole (never "resolved, fee stuck").
                val pay = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: cfg.house,
                    value: fee,
                    body: HousePayout {
                        queryId: msg.queryId,
                        amount: fee,
                    },
                });
                pay.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
                emitEvent(
                    EVENT_TOPIC_HOUSE_PAID,
                    HousePaidEvent {
                        amount: fee,
                        to: cfg.house,
                    },
                );
            }
            emitEvent(
                EVENT_TOPIC_MARKET_RESOLVED,
                MarketResolvedEvent {
                    outcome: storage.outcome,
                    openPrice: storage.openPrice,
                    closePrice: storage.closePrice,
                    poolYes: storage.poolYes,
                    poolNo: storage.poolNo,
                    fee,
                    publishTime: msg.publishTime,
                    attestation: msg.attestation,
                },
            );
        }

        ForceVoid => {
            val cfg = lazy storage.config.load();
            assert (!storage.resolved) throw Errors.AlreadyResolved;
            assert (
                blockchain.now() >= cfg.resolvesAt + VOID_GRACE
            ) throw Errors.VoidGraceNotElapsed;
            storage.outcome = OUTCOME_VOID as uint8;
            storage.resolved = true;
            storage.save();
            emitEvent(
                EVENT_TOPIC_MARKET_RESOLVED,
                MarketResolvedEvent {
                    outcome: storage.outcome,
                    openPrice: storage.openPrice,
                    closePrice: storage.closePrice,
                    poolYes: storage.poolYes,
                    poolNo: storage.poolNo,
                    fee: 0,
                    publishTime: blockchain.now() as uint32,
                    attestation: 0,
                },
            );
        }

        ClaimPayout => {
            val cfg = lazy storage.config.load();
            assert (storage.resolved) throw Errors.NotResolved;
            val expected = calcBetPositionAddress(contract.getAddress(), msg.owner, positionCode());
            assert (in.senderAddress == expected) throw Errors.NotFromPosition;

            val payout = payoutForPosition(
                storage.outcome,
                cfg.feeBps as int,
                storage.poolYes,
                storage.poolNo,
                msg.yes,
                msg.no,
            );
            // Pay the winner the exact amount from the pot (gas from headroom); the rest of the pot stays for others.
            // Bounce-on-fail: if the reserve cannot pay the forward fee, the ClaimPayout bounces back to the position,
            // which clears `claiming` so the owner can retry once the market is topped up (never a lost claim).
            if (payout > 0) {
                val pay = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: msg.owner,
                    value: payout,
                    body: WinPayout {
                        queryId: msg.queryId,
                        amount: payout,
                    },
                });
                pay.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
            }
            // Return the position's own gas so it can mark itself claimed.
            val ack = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: ClaimAck { queryId: msg.queryId },
            });
            ack.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);

            emitEvent(
                EVENT_TOPIC_CLAIMED,
                ClaimedEvent {
                    owner: msg.owner,
                    payout,
                },
            );
        }

        SweepHouse => {
            val cfg = lazy storage.config.load();
            assert (storage.resolved) throw Errors.NotResolved;
            assert (
                blockchain.now() >= cfg.resolvesAt + cfg.claimWindowSec
            ) throw Errors.ClaimWindowOpen;
            reserveToncoinsOnBalance(MIN_STORAGE_RESERVE, RESERVE_MODE_AT_MOST);
            val sweep = createMessage({
                bounce: BounceMode.NoBounce,
                dest: cfg.house,
                value: 0,
                body: HousePayout {
                    queryId: msg.queryId,
                    amount: 0,
                },
            });
            // SAFETY: SweepHouse runs only after the claim window (asserted above) on a resolved market, and the pot
            // it drains is exactly the unclaimed remainder plus the deploy reserve, sent to the immutable house wallet.
            sweep.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }

        else => {
            // Deployment and plain TON top-ups (empty body) are accepted; any unknown opcode bounces.
            assert (in.body.isEmpty()) throw 0xFFFF;
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    var storage = lazy MarketStorage.load();
    in.bouncedBody.skipBouncedPrefix();
    val op = in.bouncedBody.loadUint(32);
    // A RecordBet could not be delivered/deployed: roll the stake back out of the pool so it equals what is claimable.
    // The stray TON stays in the market and is later swept to the house (documented edge; needs ample BET_GAS).
    if (op == 0x50440010) {
        in.bouncedBody.skipBits(64); // queryId
        val isYes = in.bouncedBody.loadBool();
        val amount = in.bouncedBody.loadCoins();
        if (isYes) {
            storage.poolYes = (storage.poolYes - amount) as coins;
        } else {
            storage.poolNo = (storage.poolNo - amount) as coins;
        }
        storage.save();
    }
}

get fun get_market_data(): MarketDataReply {
    val storage = lazy MarketStorage.load();
    return {
        poolYes: storage.poolYes,
        poolNo: storage.poolNo,
        openPrice: storage.openPrice,
        closePrice: storage.closePrice,
        openSet: storage.openSet,
        resolved: storage.resolved,
        outcome: storage.outcome,
        config: storage.config.load(),
        proof: storage.proof != null ? storage.proof.load() : null,
    };
}

/// Flat scalars only (no nested/nullable structs): what the keeper polls every pass through a plain RPC stack read.
get fun get_market_state(): MarketStateReply {
    val storage = lazy MarketStorage.load();
    return {
        poolYes: storage.poolYes,
        poolNo: storage.poolNo,
        openSet: storage.openSet,
        resolved: storage.resolved,
        outcome: storage.outcome,
    };
}

get fun get_position_address(owner: address): address {
    return calcBetPositionAddress(contract.getAddress(), owner, positionCode());
}
