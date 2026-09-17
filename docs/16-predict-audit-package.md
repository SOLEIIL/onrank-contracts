# 16 — Predict : dossier d'audit externe (contrats v1.1)

Dossier remis à l'auditeur. Complète docs/15 (pré-audit interne, doutes K1–K13) ; ne remplace ni docs/14 (production) ni
docs/07 § 7g (runbook). Archive autonome : `contracts/predict-audit-v1.1.zip` (§ f). Bug bounty : docs/17.

## a. Périmètre

Contrats (Tolk, immuables une fois déployés ; tout changement de `MarketConfig` ou du code change **toutes** les adresses) :

| Fichier | Rôle |
|---|---|
| `contracts/contracts/predict/Market.tolk` | pools YES/NO, fenêtre de mise, résolution par l'oracle, fee maison, claims, sweep |
| `contracts/contracts/predict/BetPosition.tolk` | position déterministe par (marché, parieur) : cumul des mises, claim unique |
| `contracts/contracts/predict/predict-messages.tolk` | opcodes `0x504400xx`, événements `0x5044E00x` |
| `contracts/contracts/predict/predict-types.tolk` | storage, `MarketConfig`, `MarketProof`, maths parimutuel (`payoutForPosition`, `houseFeeOf`, `partnerFeeOf`), adresse de position |
| `contracts/contracts/common/errors.tolk` | exit codes ; plage Predict 500–519 (+ 402 `NotFromOwner`, 410 `InsufficientValue`) |
| `contracts/contracts/common/consts.tolk` | `MIN_STORAGE_RESERVE` = 0,05 TON (seule constante utilisée par Predict, dans `SweepHouse`) |

Hashes de code v1.1 (à recalculer par l'auditeur : `acton build` → `build/Market.json`, `build/BetPosition.json`) :

| Contrat | hex | base64 |
|---|---|---|
| Market | `2aead32d0ef3afbd7ebe4c3c4859767dbf58add41bbefb42bbb1cd7159b531a7` | `KurTLQ7zr71+vkw8SFl2fb9YrdQbvvtCu7HNcVm1Mac=` |
| BetPosition | `8dad64bd903f69b972bb9d3b983f4c5af9bf54b7d13b624027aba07d3afd5d66` | `ja1kvZA/ablyu507mD9MWvm/VLfRO2JAJ6ugfTr9XWY=` |

Toolchain : Acton **1.1.0** (`contracts/Acton.toml` `[toolchain] acton = "1.1.0"` ; binaire local `acton 1.1.0 (9cf4d1f 2026-05-22)`), compilateur Tolk embarqué.
Tests et scripts : `contracts/tests/predict-market.test.tolk` (22 tests), `contracts/tests/predict-gas.test.tolk` (2 tests),
`contracts/scripts/predict-emulation.tolk`, wrappers générés `contracts/wrappers/Market.gen.tolk`, `BetPosition.gen.tolk`
(`acton wrapper Market` / `acton wrapper BetPosition`).

Hors périmètre contrat mais dans le périmètre du bounty (docs/17) : oracle/keeper `app/src/workers/keeper/predict*.ts`,
miroir TS `app/src/lib/predict/onchain.ts` + `parimutuel.ts`, preuves `proof.ts`, API `app/src/app/api/predict/**` et
`api/partner/v1/**`, widget `app/src/app/embed/predict/[id]`.

## b. Architecture

1. Un `Market` par fenêtre (Up/Down : `openAt`/`closesAt`/`resolvesAt`) ou par cible de prix (`KIND_HIT`, `threshold`). Adresse = f(code, `MarketConfig`) ; le keeper le déploie, personne ne l'administre (aucun admin, aucun `set_code`).
2. `MarketConfig` (ref immuable) : `oracle`, `house`, bornes de temps, `feeBps`, `kind`, `threshold`, `partnerBps`, `claimWindowSec`, `limits` (`minBet`/`maxBet`/`maxPool`).
3. Une `BetPosition` par (marché, parieur), adresse déterministe (`calcDeployedBetPosition`, shard `fixedPrefixLength: 8` proche du parieur), déployée par le premier `RecordBet`. Elle ne détient aucun fonds de pool : seulement les compteurs `yes`/`no` et les drapeaux `claimed`/`claiming`.
4. `PlaceBet` : valeur − (`BET_GAS` 0,02 + `MARKET_GAS` 0,005 [+ `PARTNER_GAS` 0,005]) = brut ; cut partenaire = floor(brut × `partnerBps`/10000) payée sur-le-champ ; net ajouté au pool et enregistré dans la position via `RecordBet` (valeur `BET_GAS`).
5. Oracle = wallet du keeper (`cfg.oracle`) : `LockOpen` (prix de référence, une fois, `publishTime` ∈ `openAt` ± 300 s) puis `Resolve` (prix de clôture, `publishTime` ∈ `resolvesAt` ± 300 s ; cible : touche anticipée si prix ≥ seuil et `publishTime` ≈ maintenant).
6. Preuve : chaque prix posté porte `attestation` = sha256 de la preuve publiée (snapshot multi-venues ou TWAP) ; stockée dans `MarketProof` (`openAttestation`, `closeAttestation`, `publishTime`s), émise dans les événements, servie par `/api/predict/proof/<attestation>` et re-hachée côté client sur `/predict/<id>/verify`.
7. Résolution : Up/Down `close > open` → YES, `<` → NO, `=` ou pool unilatéral ou open jamais verrouillé → VOID. Cible : prix ≥ seuil → YES (touche ou deadline), sinon NO à la deadline ; unilatéral → VOID.
8. Fee maison = floor(pot × `feeBps`/10000) envoyée à `cfg.house` (Ledger) dans la tx de `Resolve`, seulement si YES/NO et deux camps ; jamais sur VOID.
9. Claim : `Claim` (propriétaire → position, ≥ 0,03 TON) → `ClaimPayout` (position → marché, authentifié en recalculant l'adresse depuis `owner`) → `WinPayout` (floor pro-rata, ou remboursement du net si VOID) + `ClaimAck` → position `claimed = true`, excédent au-dessus de 0,01 TON rendu au propriétaire.
10. `ForceVoid` par quiconque après `resolvesAt` + 3600 s si non résolu ; `SweepHouse` par quiconque après `resolvesAt` + `claimWindowSec` sur un marché résolu : tout le solde sauf 0,05 TON va à `cfg.house`.

## c. Invariants à prouver

| # | Invariant | Où |
|---|---|---|
| I1 | Conservation : à tout instant balance(Market) ≥ poolYes + poolNo − Σ payés − fee ; après résolution Σ `payoutForPosition` + fee ≤ pot, poussière < nombre de gagnants (2 gagnants → < 2 nano) | `payoutForPosition`, `houseFeeOf` ; test « rounding » |
| I2 | Fee maison unique, prélevée une seule fois, dans `Resolve`, uniquement si `outcome` ∈ {YES, NO} et `poolYes > 0 && poolNo > 0` ; 0 sur VOID, unilatéral, `ForceVoid` | `Resolve`, `houseFeeOf` |
| I3 | Cut partenaire = floor(brut × `partnerBps`/10000) retirée **avant** le pool, payée dans la même transaction (`PartnerPayout`, `BOUNCE_ON_ACTION_FAIL`) ; `minBet`/`maxBet`/`maxPool` s'appliquent au **net** ; `partner` ∉ {house, market, oracle} | `PlaceBet` |
| I4 | VOID (void, unilatéral, égalité, open non verrouillé, `ForceVoid`) = remboursement intégral du **net** de chaque position, fee 0 ; la cut partenaire déjà payée n'est pas remboursée | `payoutForPosition` |
| I5 | Claim idempotent : une position paie au plus une fois (`claimed`), jamais plus que `payoutForPosition(yes, no)` ; un `ClaimPayout` forgé (mauvais expéditeur, montants gonflés) est refusé (`NotFromPosition`) ; un `ClaimPayout` refusé ou un `WinPayout` impayable rebondit et remet `claiming = false` | `Claim`, `ClaimPayout`, `onBouncedMessage` |
| I6 | `SweepHouse` seulement si `resolved` et `now ≥ resolvesAt + claimWindowSec`, destination = `cfg.house` uniquement, garde `MIN_STORAGE_RESERVE` | `SweepHouse` |
| I7 | `LockOpen` et `Resolve` : expéditeur = `cfg.oracle` ; chacun une seule fois (`openSet`, `resolved`) ; `LockOpen` refusé après résolution ; `publishTime` dans ± `ORACLE_EPS` (300 s) de l'instant de référence | `LockOpen`, `Resolve` |
| I8 | `ForceVoid` : sans permission, seulement si `!resolved` et `now ≥ resolvesAt + VOID_GRACE` (3600 s) ; n'écrit ni prix ni preuve ; exclusif avec `Resolve` (l'un rend l'autre `AlreadyResolved`) | `ForceVoid` |
| I9 | `PlaceBet` : `value > kept` (`BET_GAS + MARKET_GAS [+ PARTNER_GAS]`) ; `!resolved` ; `openSet || kind == HIT` ; `now < closesAt` ; `minBet ≤ net ≤ maxBet` (0 = illimité) ; `poolYes + poolNo + net ≤ maxPool` (0 = illimité) ; une mise refusée ne modifie rien et ne déploie pas de position | `PlaceBet` ; tests « value guards », « betting window » |
| I10 | Réserve (balance − pot) non décroissante par `PlaceBet` : `MARKET_GAS` reste au marché, `BET_GAS` part entier vers la position, la cut part sur `PARTNER_GAS` ; 200 mises → réserve ≥ initiale | test gas « headroom » |
| I11 | `PositionExcess` : après `RecordBet` et `ClaimAck`, la position rend tout au-dessus de `POSITION_RESERVE` (0,01 TON) à `owner` ; aucun TON ne reste bloqué dans une position | `refundExcess` |
| I12 | `RecordBet` rebondi : le pool est décrémenté du montant exact (`Only256BitsOfBody` suffit : 32 + 64 + 1 + ≤ 124 bits) ; la mise reste dans le marché (balayée à la maison) — voir Q3 | `Market.onBouncedMessage` |
| I13 | Opcode inconnu : `throw 0xFFFF`, aucune écriture, valeur rebondie ; corps vide accepté comme recharge de réserve (Market et BetPosition) | branches `else` |
| I14 | Aucun paiement (`PartnerPayout`, `HousePayout`, `WinPayout`) sans `SEND_MODE_BOUNCE_ON_ACTION_FAIL` : un envoi qui échoue en phase d'action annule toute la transaction (un `Resolve` dont la fee ne part pas n'est pas résolu) | `Market.tolk` |
| I15 | Adresse de position : `get_position_address(owner)` = l'adresse que le marché recalcule dans `ClaimPayout` = l'adresse déployée par `RecordBet` ; identique au miroir TS (`onchain.ts`, xcheck) | `calcDeployedBetPosition` |
| I16 | Pas de dépassement : `pot × feeBps`, `winnerAmount × distributable` ≤ 2^120 × 2^120 < 2^256 ; casts `as coins` jamais négatifs (I12 : le montant rebondi a été ajouté par la même transaction du marché) | `predict-types.tolk` |

## d. Hypothèses de confiance

Ce que le contrat **vérifie** : expéditeur de `LockOpen`/`Resolve` = oracle ; bornes de temps (± 300 s, grâce 1 h, fenêtre de claim) ; arithmétique et conservation ; authenticité d'un claim (adresse recalculée) ; immuabilité de `house`, `oracle`, `feeBps`, `limits`.

Ce que le contrat **ne vérifie pas** (à faire figurer dans le rapport comme hypothèses, pas comme findings) :

1. **Prix et attestation** sont des entrées de confiance : l'oracle peut poster n'importe quel `price` daté dans ± `ORACLE_EPS` ; l'`attestation` n'est pas vérifiée on-chain (sha256 stocké, pas de signature). La vérification est off-chain : `/api/predict/proof/<attestation>` sert la preuve, le client la re-hache et compare aux `MarketProof` on-chain (`get_market_data`). Un oracle malhonnête est **détectable** (preuve absente ou ne correspondant pas, `publishTime` choisi dans la fenêtre), pas **empêché**.
2. **Vivacité du keeper** : si aucun `Resolve` n'arrive dans l'heure suivant `resolvesAt`, quiconque peut `ForceVoid` → remboursement des nets, fee 0. Un `Resolve` en retard de plus d'une heure est donc en course avec un `ForceVoid` d'un perdant (griefing rationnel : le perdant préfère un remboursement). Accepté ; le runbook impose un keeper dédié, NTP, alertes `predict_clock_skew`, `inGrace`.
3. **Fenêtre de 300 s** : la politique du keeper (`predict-policy.ts`) est plus stricte que le contrat (lock tardif refusé au-delà d'un quart de fenêtre, resolve avec un tick stocké de la fenêtre) ; le contrat ne connaît que ± 300 s.
4. **Maison** : `cfg.house` est un wallet (Ledger) ; les paiements partent en `NoBounce`. Si `house` est un contrat qui rejette, la fee reste chez lui (non perdue pour le marché, mais hors du pot).
5. **Gas** : budgets `BET_GAS` 0,02 / `MARKET_GAS` 0,005 / `PARTNER_GAS` 0,005 / `POSITION_CLAIM_GAS` 0,03 / `ORACLE_MSG_VALUE` 0,05 mesurés avec 25 % de marge en émulation (marge réelle ×23 à ×146) ; une hausse du prix du gas mainnet est absorbée par le keeper (top-up de réserve, docs/07 § 7g).
6. **Fenêtre de claim** : un gagnant qui ne réclame pas avant `resolvesAt + claimWindowSec` (7 / 30 / 90 j) perd au profit de la maison au sweep ; règle affichée dans l'app (`predict_rule_claim_window`).
7. **Rebond d'une mise refusée** : un parieur envoyant `PlaceBet` en `bounce: false` depuis un wallet qui ne le permet pas ne récupère pas la valeur d'une mise refusée (elle reste au marché, balayée). Comportement TON standard ; l'app construit toujours `bounce: true`.

## e. Questions ouvertes pour l'auditeur

| # | Origine | Question |
|---|---|---|
| Q1 | K2 | Aucun test ne force l'échec d'un paiement. Construire en émulation : (a) un `Resolve` dont le `HousePayout` échoue en phase d'action (réserve insuffisante pour le forward) → confirmer que `resolved` reste `false` et que le message oracle rebondit ; (b) un `ClaimPayout` dont le `WinPayout` échoue → `claiming = false` (test « claim after the sweep » couvre ce cas ; le confirmer sur un marché non balayé mais à réserve épuisée) ; (c) un `PlaceBet` partenaire dont le `PartnerPayout` échoue → rien n'est poolé. Un destinataire qui **rejette** (contrat qui `throw`) ne fait pas échouer la phase d'action : confirmer que c'est acceptable pour `house`, `partner` et `owner`. |
| Q2 | K4 | L'oracle choisit librement le prix dans ± 300 s autour de `openAt` / `resolvesAt`, et pour une touche autour de `now`. Chiffrer l'avantage maximal (Up/Down 24 h avec un mouvement de 300 s ; cible touchée à la marge) et juger si la détectabilité off-chain (preuve publiée, `publishTime` on-chain) suffit ou s'il faut une borne plus étroite / un oracle multi-signature avant mainnet. |
| Q3 | K6 | `RecordBet` rebondi : le pool est corrigé mais la mise reste au marché et finit à la maison. Évaluer la probabilité réelle (position non déployable : gas, adresse gelée, code invalide) avec `BET_GAS` 0,02 (mesuré 0,000136) ; le cas d'une position **gelée** faute de rent après un long marché (`POSITION_RESERVE` 0,01 TON, marché 1 an + 90 j de claim) ; et le coût d'un remboursement automatique (renvoi de `amount` à l'expéditeur dans `onBouncedMessage`) plutôt qu'un edge documenté. |
| Q4 | K12 | Cadences courtes (5m / 15m, désactivées au lancement mais code présent) : ± 300 s est la borne du contrat ; la politique off-chain (`lockLateSec`, tick stocké de la fenêtre) est-elle suffisante, ou la borne doit-elle dépendre de la cadence dans `MarketConfig` ? |
| Q5 | K3 | `ClaimAck` perdu (gas insuffisant côté marché, `CARRY_ALL_REMAINING_MESSAGE_VALUE` avec valeur nulle) : la position reste `claiming = true` alors que le `WinPayout` est parti. Pas de double paiement ; confirmer qu'aucun chemin ne débloque le drapeau à tort, et qu'un `WinPayout` parti + `ClaimAck` non délivré ne permet pas un second `Claim` payé. |
| Q6 | nouveau | `Market.onBouncedMessage` ne filtre pas l'expéditeur du rebond : un rebond d'op `0x50440010` ne peut provenir que d'un message émis par le marché (flag `bounced` posé par les validateurs). Confirmer qu'aucun message sortant du marché autre que `RecordBet` ne peut produire un rebond avec ce préfixe. |
| Q7 | nouveau | `Resolve` sur une cible avant `resolvesAt` accepte `publishTime ≤ now + 300` (prix « du futur » de 5 min) et `publishTime + 300 ≥ openAt` (prix antérieur à `openAt` jusqu'à 5 min). Ces marges sont-elles exploitables (touche à la marge posée avec un tick d'avant l'ouverture) ? |
| Q8 | nouveau | Up/Down : `LockOpen` peut arriver tard (jusqu'à la résolution) tant que `publishTime` ≈ `openAt` ; aucune mise n'est acceptée avant. La réduction de la fenêtre de mise est-elle un vecteur (l'oracle observe la trajectoire puis choisit d'ouvrir ou non) ? Le keeper refuse un lock au-delà d'un quart de fenêtre ; le contrat non. |
| Q9 | nouveau | Sharding : `toShard: { fixedPrefixLength: 8, closeTo: owner }` — vérifier que le miroir TS (`onchain.ts`) et `calcBetPositionAddress` produisent la même adresse pour toute paire (market, owner), y compris les adresses `owner` hors basechain (refusées ?). |
| Q10 | nouveau | Rent : un `Market` déployé avec 0,6 TON pour 1 an + 90 j, une `BetPosition` avec 0,01 TON sur la même durée. Calculer la storage fee (taille réelle des cellules) et confirmer qu'aucun compte ne passe `frozen` avant le sweep / le claim ; sinon quelles conséquences (claim impossible, `RecordBet` rebondi → Q3). |
| Q11 | nouveau | `SweepHouse` déclenchable par quiconque : le déclencheur perd sa valeur jointe (balayée). Nuisance seulement ? Un sweep pendant la fenêtre de claim est bien impossible (I6) — confirmer qu'aucun décalage `resolvesAt` (cible résolue par touche bien avant la deadline) ne raccourcit la fenêtre effective : pour une cible touchée à J, la fenêtre court de `resolvesAt` (deadline) + `claimWindowSec`, donc plus longue, jamais plus courte. |
| Q12 | nouveau | Événements externes (`ExtOutLogBucket`) : leur coût est-il couvert par `MARKET_GAS` sur tous les chemins (`Resolve` émet jusqu'à 2 événements sur `ORACLE_MSG_VALUE`) ; un événement non émis n'affecte que l'indexer, jamais les fonds — confirmer. |
| Q13 | K7 | Reproduire `predict-gas.test.tolk` et chercher le chemin le plus cher : claim sur un marché à réserve minimale après un long stockage, prix du gas ×2, 255 actions. |

Fermés en v1.1 (ne plus rapporter) : `partner = oracle` refusé on-chain (K5) ; `LockOpen` après `ForceVoid` refusé ; réserve qui décroissait par mise ; gas bloqué dans les positions.

## f. Build & test

Prérequis : Linux x86_64/ARM64 ou macOS ; sous Windows, WSL Ubuntu 22+. Installation officielle d'Acton
(https://github.com/ton-blockchain/acton, docs https://ton-blockchain.github.io/acton/docs/installation) :

```bash
curl -LsSf https://github.com/ton-blockchain/acton/releases/latest/download/acton-installer.sh | sh
acton --version          # attendu : acton 1.1.0 ; sinon : acton up 1.1.0
```

Alternative Docker : `docker run --rm -v "$PWD":/workspace -w /workspace ghcr.io/ton-blockchain/acton:1.1.0 build`.

Depuis le repo complet (`contracts/`) :

```bash
cd contracts
acton build                 # compile les 25 contrats du repo ; hashes dans build/Market.json, build/BetPosition.json
acton test                  # attendu : "183 passed in 25 files" (dont 24 Predict)
acton run predict-emul      # attendu : dernière ligne "predict emulation complete"
acton test tests/predict-market.test.tolk tests/predict-gas.test.tolk   # Predict seul
```

Depuis Windows PowerShell : `wsl -e bash -lc "cd /mnt/c/<chemin>/contracts && ~/.acton/bin/acton test 2>&1 | tail -5"`.

Depuis l'archive autonome `contracts/predict-audit-v1.1.zip` (dézipper, puis à la racine) :

```bash
acton build                 # 2 contrats : BetPosition, Market
acton test                  # attendu : "24 passed in 2 files"
acton run predict-emul      # attendu : "predict emulation complete"
```

Contenu de l'archive : `Acton.toml` (copie réduite aux deux contrats Predict — le vrai `Acton.toml` du repo référence 23 autres
contrats hors périmètre), `AGENTS.md`, `contracts/predict/*.tolk`, `contracts/common/consts.tolk` + `errors.tolk`,
`tests/predict-market.test.tolk` + `predict-gas.test.tolk`, `wrappers/Market.gen.tolk` + `BetPosition.gen.tolk`,
`scripts/predict-emulation.tolk`, `scripts/deploy-config.tolk` (copie réduite : deux constantes de nom de wallet ; l'original
planifie aussi les déploiements desk/launcher hors périmètre), `docs/16-predict-audit-package.md` (ce fichier).
`gen/` et `build/` sont régénérés par `acton build`. L'archive (≈ 44 Ko, 15 fichiers, chemins POSIX) est un artefact dérivé,
ignoré par git (`contracts/.gitignore`, comme `build/`) : la liste ci-dessus est la recette pour la reconstruire ; vérifiée le
17/09/2026 dézippée seule (build OK, 24 tests, émulation complète, hashes v1.1 identiques).

Vérifier les hashes : `acton build` puis lire le champ `hash` (hex majuscule) de `build/Market.json` et `build/BetPosition.json` ; côté app
`app/scripts/sync-predict-codes.mts` doit être sans diff.

## g. Tests existants

`tests/predict-market.test.tolk` (22) :

| Test | Ce qu'il prouve |
|---|---|
| layout cross-check — addresses for the TS builder test | imprime oracle/house/market pour le xcheck d'adresse du miroir TS (`onchain.test.ts`) |
| two-sided market pays the house fee to the Ledger and winners pro-rata | fee 2 % exacte à `house` dans la tx `Resolve` ; gagnant paie 29,4 sur pot 30 ; preuves open/close stockées ; `PositionExcess` rend le gas ; second claim `AlreadyClaimed` ; perdant peut « settle » sans payout |
| a lone bettor (one-sided) is refunded in full, no house fee | unilatéral → VOID, pas de `HousePayout`, remboursement intégral |
| open == close resolves to void and refunds both sides | égalité → VOID, pas de fee, remboursement des deux camps |
| betting window and oracle guards | `OpenNotLocked`, `NotFromOracle` (lock et resolve), `OpenAlreadyLocked`, `NotYetResolvable`, `BettingClosed` à `closesAt`, `AlreadyResolved` |
| ForceVoid only after the grace, then everyone is refunded | `VoidGraceNotElapsed` à `resolvesAt` ; void par un tiers à +3600 ; remboursement |
| hit: a touch before the deadline resolves YES right there and closes betting | `TargetNotReached` sous le seuil ; `StaleOraclePrice` pour un tick ancien ; touche → YES + fee ; mise refusée après (`AlreadyResolved`) |
| hit: no touch by the deadline resolves NO from the deadline price | mise acceptée à `RESOLVES − 1` ; resolve deadline exige `publishTime` ≈ deadline ; NO paie 20,58 ; prix deadline ≥ seuil → YES |
| hit: a one-sided target is void on a touch, everyone refunded, no fee | cible unilatérale touchée → VOID sans fee |
| partner: 3% of a partner bet goes to the partner on the spot, the net joins the common pool | `PartnerPayout` 0,6 immédiat ; pool net 19,4 ; position enregistre le net ; `BadPartner` pour house et oracle ; `BetTooSmall` sur le net ; conservation 10 + 20 = 0,6 + 0,588 + 28,812 |
| partner: a partner bet on a price target works the same | même règle sur `KIND_HIT` ; payout 19,012 |
| SweepHouse waits for the market's own claim window, then returns the remainder to the house | `ClaimWindowOpen` avant ; `HousePayout` au sweep après 7 j |
| a claim before resolution bounces and can be retried | `ClaimPayout` refusé `NotResolved` → rebond → `claiming = false` ; retry payé |
| value guards — gas only, below min, above max, pool cap (net stake is what counts) | `InsufficientValue` (value == kept, natif et partenaire, partenaire avec valeur native) ; `BetTooSmall` ; `BetTooLarge` ; max exact accepté ; `PoolCapReached` ; pools inchangés ; aucune position déployée pour une mise refusée |
| after resolution no bet is accepted; unknown opcodes bounce; empty top-ups are kept | opcode inconnu → 0xFFFF ; corps vide = recharge ; `AlreadyResolved` pour mise native, partenaire et `LockOpen` tardif |
| oracle time windows — LockOpen and Resolve refuse prices published outside ±ORACLE_EPS | ± 301 s refusé, ± 300 s accepté, pour lock et resolve, quelle que soit l'horloge |
| an up/down window whose open price was never locked resolves void; void and resolve exclude each other | open jamais verrouillé → VOID sans fee, preuve close stockée ; `ForceVoid` après `Resolve` refusé ; `Resolve` et `LockOpen` après `ForceVoid` refusés, storage intact ; remboursements au nano |
| access control — only the owner starts a claim, only the real position is paid | `NotFromOwner` ; `InsufficientValue` sur claim < 0,03 ; `NotFromPosition` pour `ClaimPayout` forgé (wallet, ou wallet tiers) ; `NotFromMarket` pour `RecordBet`/`ClaimAck` étrangers ; claim légitime intact |
| rounding — floor per winner, fee + payouts never exceed the pot, dust stays for the sweep | montants impairs : chaque part ≤ pro-rata exact ; Σ + fee ≤ pot ; poussière < 2 ; perdant = 0 ; balance ≥ poussière |
| a claim after the sweep bounces cleanly — the position is not locked and nothing else is lost | sweep laisse ≤ 0,05 ; second sweep ne bouge que la valeur jointe ; claim tardif : pas de `WinPayout`, pas de `ClaimAck`, `claiming = false`, `yes` intact ; perdant peut settle |
| several bets by one wallet accumulate in one position; mixed YES/NO pays only the winning side | cumul 4 + 6 YES, 5 NO ; payout 29,4 ; côté perdant forfait ; claim unique pour les deux côtés |
| partner: a disabled cut (partnerBps 0) pools the gross; self-partnering is harmless | `partnerBps` 0 → pas de `PartnerPayout`, brut poolé ; auto-partenariat : 0,3 rendu, net 9,7 poolé ; marché refusé comme partenaire |

`tests/predict-gas.test.tolk` (2) :

| Test | Ce qu'il prouve |
|---|---|
| BET_GAS, PARTNER_GAS, ORACLE_MSG_VALUE and POSITION_CLAIM_GAS cover their chains with headroom | frais réels × 1,25 ≤ budget pour `RecordBet`, `PlaceBet` compute + événement, `RecordBet + PartnerPayout`, `Resolve + HousePayout`, chaîne de claim ; réserve finale > 0,03 sur un deploy 0,06 |
| headroom never shrinks over 200 bets and the market still pays every claim | 200 mises : réserve (balance − pot) ≥ initiale ; resolve ; gagnant paie 196 ; perdant settle ; balance > 0 |

`scripts/predict-emulation.tolk` : vie complète d'une fenêtre Up/Down (deploy + lock en un message, mise native, mise
partenaire, resolve DOWN, claim) et d'une cible (deploy, deux mises, touche refusée sous le seuil, touche → YES, claim).

## h. Auditeurs

Vérifié le 17/09/2026 (sources en ligne ; prix et délais ne sont publiés par aucun d'eux : sur devis).

| Auditeur | Site / contact | Preuve d'activité TON | Remarques |
|---|---|---|---|
| Trail of Bits | https://www.trailofbits.com — formulaire de contact du site | audits TON Blockchain, TVM & Fift, TVM upgrade 2023 (docs.ton.org/audits) ; partenaire sécurité de TVM Ventures (blog 13/02/2025) ; STON.fi v2 (2025), PixelSwap (rapport public 12/2024) ; « Not So Smart Contracts — TON » | référence haut de gamme, délai et prix élevés ; FunC/Tact documentés, Tolk à confirmer |
| CertiK | https://www.certik.com — formulaire « Request a quote » | audit TON Blockchain + vérification formelle masterchain ; Tonstakers (11/2023) ; article « Tolk Security Explained » (checklist Tolk : `lazy`, unions, `BounceMode`, `onBouncedMessage`) | connaît Tolk explicitement ; livre un score Skynet public |
| Zellic | https://www.zellic.io — formulaire de contact | évaluation tonlib (docs.ton.org/audits) ; « TON Security Primer » (FunC, bounces, adresses) ; repo TON-study | pas d'audit Tolk public identifié |
| Hacken | https://hacken.io/services/blockchain-security/ton-smart-contract-audit/ — formulaire | page dédiée « TON Smart Contract Audit » (TVM, FunC, fuzzing, invariants) ; listé n° 2 sur ton.app/audit ; HackenProof pour le bounty | offre TON explicite ; pricing par ligne de code sur devis |
| Positive Web3 (Positive Security) | https://positive.com — audit@positive.com | checklist publique « ton-audit-guide » avec section Tolk (§ 13 : `lazy`, `BounceMode`, unions exhaustives) ; blog « Security audit of smart contracts in TON » ; listé sur ton.app/audit | seule équipe avec une checklist Tolk publiée ; taille adaptée à un petit protocole |
| TonTech (TON Tech) | https://ton.tech — formulaire du site | audits Hipo Finance v1 (10/2023, rapport public), Omniston escrow / STON.fi (2025) ; « supported by TON Foundation » ; pipelines FunC/Tact/Tolk | proche de l'écosystème ; rapports pas toujours publics |
| Quantstamp | https://quantstamp.com — formulaire | rapports publics FunC : TON locker contract (ton-blockchain), Hipo Finance v2 (04/2025), TAC bridges | FunC documenté ; Tolk à confirmer |

Non retenus / non vérifiés : Pessimistic (aucun audit TON public trouvé) ; Nowarp (Tact, outil Misti — pertinent si l'on veut une
analyse statique en complément) ; SlowMist (audit TON Blockchain, pas d'offre contrat applicatif identifiée).

Recommandation : demander 3 devis (Positive Web3, Hacken, TonTech) + 1 référence (CertiK ou Trail of Bits) ; exiger des auditeurs
ayant déjà lu du Tolk (`lazy`, `createMessage`, `BounceMode`, `AutoDeployAddress`/`toShard`).

## i. Modèle de demande de devis (anglais)

```text
Subject: Quote request — security audit of two Tolk smart contracts (TON), ~650 LoC

Hello,
ONRANK Predict is a parimutuel prediction-market protocol on TON (Telegram Mini App). We are requesting a fixed-price quote for an independent security review of two immutable Tolk contracts before mainnet: Market (~430 LoC) and BetPosition (~110 LoC), plus two shared type/message files (~370 LoC). No admin keys, no upgrade path; the oracle is our keeper wallet (trusted input, publicly verifiable proofs).
Toolchain: Acton 1.1.0 (acton build / acton test / acton run predict-emul), 24 Tolk tests and a full-life emulation script are included and pass. The package (sources, tests, audit brief with invariants, trust assumptions and 13 open questions) is attached as predict-audit-v1.1.zip; code hashes: Market 2aead32d…31a7, BetPosition 8dad64bd…5d66.
Deliverable expected: findings by severity with PoC (emulation or testnet), review of the listed invariants, a verdict on the trust assumptions, and a short re-review of fixes.
Please indicate: price, start date, duration, team size, prior Tolk/TON experience (report links welcome), and whether the report may be published.
Thank you,
ONRANK — Telegram @soleil
```
