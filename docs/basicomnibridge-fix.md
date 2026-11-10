# Omnibridge — WETH Router Griefing Fix

Source: [`ForeignOmnibridge.sol`](../contracts/upgradeable_contracts/ForeignOmnibridge.sol) and
[`BasicOmnibridge.sol`](../contracts/upgradeable_contracts/BasicOmnibridge.sol) (`_receiverCallback`)

> A permissionless relayer could choose a gas limit that lets a WETH claim settle while starving the
> unwrap callback, leaving WETH stranded in [`WETHOmnibridgeRouter`](../contracts/helpers/WETHOmnibridgeRouter.sol)
> and the recipient with nothing. Fixed by requiring the callback to succeed **when the recipient is
> the WETH router**, so a failed unwrap reverts the whole message. For every other recipient a failed
> callback is still tolerated, for backward compatibility, and now emits `ReceiverCallbackFailed`.

## Affected path

A user bridging WETH back to Ethereum and asking for native ETH sets the message recipient to
`WETHOmnibridgeRouter`, with their own address as the 20-byte payload. HomeOmnibridge therefore emits
`handleNativeTokensAndCall(WETH, router, value, abi.encodePacked(recipient))`.

```
ForeignAMB.executeSignatures / safeExecuteSignaturesWithGasLimit
  └─ MessageProcessor.processMessage → executor.call.gas(_gas)(data)
       └─ ForeignOmnibridge.handleNativeTokensAndCall           [onlyMediator]
            ├─ _handleTokens → _releaseTokens                    ← WETH transferred to the ROUTER
            └─ _receiverCallback → router.onTokenBridged(...)    ← unwrap + forward ETH to the user
                 ├─ WETH.withdraw(value)
                 └─ AddressHelper.safeSendValue(recipient, value)
```

The two halves settle in different frames, and the second one was optional.

## Cause

`_receiverCallback` invoked the callback with a bare low-level call and discarded the result:

```solidity
if (Address.isContract(_recipient)) {
    _recipient.call(abi.encodeWithSelector(IERC20Receiver.onTokenBridged.selector, _token, _value, _data));
}
```

Three properties combine into an exploitable grief:

1. **Tokens move before the callback runs.** `_handleTokens` has already transferred WETH to the
   router by the time `onTokenBridged` is invoked, so a failed callback leaves a half-completed claim rather than no claim.
2. **The result is discarded**, so an out-of-gas callback is indistinguishable from success. The outer
   `handleNativeTokensAndCall` returns normally and the AMB marks the message executed.
3. **The caller picks the gas.** `executeSignatures` and `safeExecuteSignaturesWith*` are permissionless — the signatures
   authorise the claim, not the sender — so _anyone_ can relay a validly signed message with a gas
   limit of their choosing. `safeExecuteSignaturesWithGasLimit(data, sigs, _gas)` takes `_gas`
   directly; plain `executeSignatures` takes it from the message header.

EIP-150 gives the callback at most 63/64 of the gas remaining when it is invoked, so a relayer who
forwards enough for `_handleTokens` but not for `_handleTokens` + `onTokenBridged` lands in a window
where the claim settles to the router and the unwrap silently fails.

### Measured gas bands

100 WETH claim to a fresh (zero-balance) recipient, mainnet fork at ~block 25.72M, against the
deployed implementation `0x8eB3b7D8498a6716904577b2579e1c313d48E347`:

| gas forwarded to the mediator | outcome                                                         |
| ----------------------------- | --------------------------------------------------------------- |
| < 87,000                      | mediator itself runs out of gas → whole call fails              |
| **87,000 – 131,000**          | **grief** — WETH stranded in the router, recipient gets nothing |
| ≥ 131,250                     | correct: router unwraps and forwards 100 ETH                    |

## Impact

WETH equal to the claim amount is left in the router, and the recipient receives nothing. The router
holds no per-user accounting, so the funds are not attributable or withdrawable by the intended owner.

Severity depends on the relay entry point:

| entry point                             | attacker controls the gas via | result before the fix                                             |
| --------------------------------------- | ----------------------------- | ----------------------------------------------------------------- |
| `safeExecuteSignaturesWithGasLimit`     | the `_gas` argument           | WETH stranded; message consumed                                   |
| `executeSignatures`                     | the message header `gasLimit` | WETH stranded **and** the AMB records `messageCallStatus == true` |
| `safeExecuteSignaturesWithAutoGasLimit` | —                             | **not exploitable** (see below)                                   |

The second row is the worse one. `FailedMessagesProcessor.requestFailedMessageFix` requires
`!bridge.messageCallStatus(_messageId)`, so a message recorded as successful cannot be rolled back on
the Home side. There is no recovery path.

`safeExecuteSignaturesWithAutoGasLimit` is structurally immune, before and after the fix. It forwards
`0xffffffff`, so EIP-150 gives the mediator 63/64 of the remaining gas and the AMB retains only 1/64.
For the AMB to have enough left to finish its own bookkeeping, the mediator must have received about
63× that — always far above the grief band. The outcome is therefore binary: the whole transaction
reverts, or the claim completes correctly. Confirmed by sweeping the transaction gas budget from
200,000 to 3,000,000: zero grief windows, first success at 275,000.

## Fix

The check is split in two. `BasicOmnibridge` keeps the original tolerant call and only adds an event
([`BasicOmnibridge.sol:433`](../contracts/upgradeable_contracts/BasicOmnibridge.sol#L433)):

```solidity
function _receiverCallback(
  address _recipient,
  address _token,
  uint256 _value,
  bytes memory _data
) internal virtual {
  if (Address.isContract(_recipient)) {
    (bool success, ) =
      _recipient.call(abi.encodeWithSelector(IERC20Receiver.onTokenBridged.selector, _token, _value, _data));
    if (!success) {
      emit ReceiverCallbackFailed(_recipient, _token, _value, messageId());
    }
  }
}

```

`ForeignOmnibridge` overrides it and requires success only for the WETH router
([`ForeignOmnibridge.sol:212`](../contracts/upgradeable_contracts/ForeignOmnibridge.sol#L212)):

```solidity
// WETHOmnibridgeRouter on Ethereum mainnet
address internal constant WETH_OMNIBRIDGE_ROUTER = 0xa6439Ca0FCbA1d0F80df0bE6A17220feD9c9038a;

function _receiverCallback(address _recipient, address _token, uint256 _value, bytes memory _data)
    internal
    override
{
    if (_recipient == WETH_OMNIBRIDGE_ROUTER) {
        (bool success, ) = _recipient.call(
            abi.encodeWithSelector(IERC20Receiver.onTokenBridged.selector, _token, _value, _data)
        );
        require(success, "WETH router callback failed");
    } else {
        super._receiverCallback(_recipient, _token, _value, _data);
    }
}
```

The new event is declared in [`OmnibridgeInfo.sol`](../contracts/upgradeable_contracts/components/common/OmnibridgeInfo.sol):

```solidity
event ReceiverCallbackFailed(address indexed recipient, address indexed token, uint256 value, bytes32 indexed messageId);
```

**WETH router.** If `onTokenBridged` fails for any reason, out of gas included, `require(success)`
reverts the whole `handleNativeTokensAndCall` call. That also undoes the `_handleTokens` transfer
that ran just before it, so the claim either completes in full or does not happen at all. WETH can
no longer be left in the router with the unwrap skipped.

The check does not look at `gasleft()`, so it does not depend on the gas schedule. It works the same
before and after Glamsterdam, and after any later repricing.

It relies on `WETHOmnibridgeRouter.onTokenBridged` reporting its own failures, which it does: it
either unwraps and delivers the ETH, or reverts. `AddressHelper.safeSendValue` tries `send` and falls
back to force-sending through `Sacrifice`; if either step runs out of gas the router reverts, the
mediator sees `success == false`, and the message reverts.

**Every other recipient.** Behaviour is unchanged from before: a failed callback is ignored and the
tokens stay with the recipient. The only difference is the `ReceiverCallbackFailed` event, which
makes these failures visible to indexers and integrators. `_receiverCallback` is only reached from
the three `*AndCall` handlers, so plain transfers are unaffected, and EOA recipients never get a
callback.

### Behaviour after the fix

For a WETH claim through the router:

| entry point              | starved relay                                                                                      | honest relay     |
| ------------------------ | -------------------------------------------------------------------------------------------------- | ---------------- |
| `safeExecuteSignatures*` | whole transaction reverts; message stays replayable                                                | settles normally |
| `executeSignatures`      | recorded as a **failed** message; `requestFailedMessageFix` rolls the tokens back on the Home side | settles normally |

Either way the user's funds survive. A relayer can still make a message fail by under-funding it, but
that ends in a refund, not a loss.

A receiver whose own callback swallows an internal failure and returns success can still lose
funds. The bridge cannot see that; it is a bug in the receiver. The WETH router does not do this.

## Who's affected?

Only `*AndCall` messages (`handleNativeTokensAndCall`, `handleBridgedTokensAndCall`,
`deployAndHandleBridgedTokensAndCall`) to a recipient that has code. Plain transfers never call
`onTokenBridged`, and neither do `*AndCall` messages to an EOA.

For those messages, the outcome depends on the recipient and on what it does when called with
`onTokenBridged(token, value, data)`:

| recipient contract                                              | before                           | after                                      |
| --------------------------------------------------------------- | -------------------------------- | ------------------------------------------ |
| implements `onTokenBridged`, call succeeds                      | tokens delivered, callback ran   | same                                       |
| no `onTokenBridged`, but a `fallback` that accepts any call     | tokens delivered, fallback ran   | same                                       |
| **no `onTokenBridged` and no `fallback`** (or one that reverts) | tokens delivered, revert ignored | tokens delivered, `ReceiverCallbackFailed` |
| implements `onTokenBridged`, but it reverts                     | tokens delivered, revert ignored | tokens delivered, `ReceiverCallbackFailed` |
| callback runs out of gas                                        | tokens delivered, revert ignored | tokens delivered, `ReceiverCallbackFailed` |
| **WETH router**, callback fails (the grief)                     | WETH stranded in the router      | **message reverts**, retried or refunded   |

A recipient with no `onTokenBridged` and no fallback rejects the call: Solidity's function dispatcher
finds no matching selector and reverts. `receive()` does not help: it only handles calls with empty
calldata, and `onTokenBridged` always carries calldata. Safe accounts using the standard
`CompatibilityFallbackHandler` (the Safe{Wallet} default since v1.3.0) also reject the call, because
the handler has no `onTokenBridged` and no fallback and the Safe re-throws the handler's revert.
These recipients keep receiving their tokens; the event now records that the callback did not run.

A relayer can still starve the callback of any recipient other than the WETH router. The tokens still
reach the recipient, but whatever the callback was meant to do does not happen. The event records
this, but cannot say whether the cause was missing support, a revert, or running out of gas.
Integrators whose callback does essential work should make `onTokenBridged` safe to skip, or ask for
their contract to get the same strict treatment as the router.

A failed WETH router message is not lost, but the sender has to request the refund:

1. On Ethereum, anyone calls `requestFailedMessageFix(messageId)` on the Foreign Omnibridge. It
   requires the AMB to have recorded the message as failed (`messageCallStatus == false`).
2. The mediator sends a `fixFailedMessage(messageId)` message back to Gnosis.
3. Once that message is executed, the Home mediator returns the WETH to the original sender (the
   `_from` recorded when bridging started) on Gnosis.

## Previous fix: 63/64 gas check (deployed, superseded)

The implementations listed under [Upgrade](#upgrade) and covered by the [Audit](#audit) contain this
version. It is replaced by the router check above because it stops working after Glamsterdam.

```solidity
function _receiverCallback(
  address _recipient,
  address _token,
  uint256 _value,
  bytes memory _data
) internal {
  if (Address.isContract(_recipient)) {
    uint256 gasBefore = gasleft();
    (bool success, ) =
      _recipient.call(abi.encodeWithSelector(IERC20Receiver.onTokenBridged.selector, _token, _value, _data));
    // EIP-150 caps the callee at 63/64 of gasBefore, so an out-of-gas callee leaves ~1/64.
    // More than that means it reverted for its own reasons — keep the existing tolerance.
    if (!success) {
      require(gasleft() > gasBefore / 63, 'callback out of gas');
    }
  }
}

```

The check does not ask _"was there enough gas"_ — it asks _"did the callee burn everything it was
given"_, which is the EIP-150 signature of starvation:

- a callee that runs out consumes the full 63/64 it received, leaving ≈ `gasBefore / 64`, which is
  strictly less than `gasBefore / 63` → **revert**;
- a callee that reverts on its own returns the unspent remainder, leaving far more → **tolerated**,
  exactly as before.

### Why the bound is `/63` and not `/64`

A non-starved callee is only guaranteed to leave _more_ than `gasBefore / 64` — the amount EIP-150
withheld from it — and one that reverts on its own after burning nearly everything it was given
leaves just barely more. So the two verdicts sit this close together:

```
     gasBefore/64          gasBefore/63                                gasBefore
 ─────────┼───────────────────┼──────────────────────────────────────────────
          ^ out-of-gas lands  ^ threshold
          └──── reject ───────┴──────────────── accept ──────────────────────
```

A `gasleft() > gasBefore / 64` threshold would be decided by rounding noise — the two cases can
differ by a single gas unit. `/63` inserts a margin of `gasBefore / (63 * 64)`, about **1.5% of the
forwarded gas**, between them.

The cost is a false positive: a callee that deliberately burns its whole allowance and then reverts
(a gas-burning loop, or an `assert`/invalid-opcode revert) is rejected alongside a genuine
out-of-gas. From inside `_receiverCallback` the two are indistinguishable, and rejecting is the safe
direction — the message stays replayable, or recoverable via `requestFailedMessageFix`, instead of
settling with the tokens stranded in the receiver.

### Why it breaks after Glamsterdam

The check assumes that after a starved callee, nothing gives gas back before `gasleft()` is read.
Glamsterdam's gas changes (EIP-8037 state-gas reservoir, EIP-8038 repricing) break that assumption.
ChainSecurity's [Glamsterdam gas review](https://www.chainsecurity.com/blog/glamsterdam-gas/) lists
this exact pattern (`if (!ok && gasleft() < gasInitial / 64) revert`) as one that no longer holds:

- **Refund on clear.** A storage slot that was zero at the start of the transaction, set and then
  cleared in the same transaction, refunds its state-creation charge (up to 97,920 gas)
  immediately, instead of at the end of the transaction.
- **Refund on intermediate revert.** When a contract in the middle of the call chain reverts, the
  state-creation gas it paid from its normal gas is credited back to its caller.

The WETH path hits both. `_releaseTokens` sets `WETH.balanceOf[router]` from zero and
`WETH.withdraw` clears it, and when the send to a fresh recipient fails, the router reverts. A
starved callback can therefore return far more than `gasBefore / 63` (about 2,000 gas at the grief
band), so the check reads it as "reverted on its own" and lets the claim settle with the WETH
stranded. The bands measured above are also specific to the current gas schedule and will move.

The article's advice is to stop inferring the cause of a failure from leftover gas, and to make
failures propagate so a recovery path stays open. The router check does exactly that.

# Upgrade

The implementations below contain the [previous 63/64 fix](#previous-fix-6364-gas-check-deployed-superseded).
The WETH router fix described above is not deployed yet.

1. Why are there differences in deployed bytecode on explorer v.s. local build?

   The runtime bytecode shown on the explorer will never match `deployedBytecode.object` in
   `out/*.json` byte-for-byte, because `BasicOmnibridge` stores the bridged-token name suffix in two
   **immutables** ([`BasicOmnibridge.sol:43`](../contracts/upgradeable_contracts/BasicOmnibridge.sol#L43)):

   ```solidity
   uint256 private immutable SUFFIX_SIZE;
   bytes32 private immutable SUFFIX;
   ```

   Immutable values are not known at compile time. solc emits 32 zero bytes at each use site and
   records the offsets under `deployedBytecode.immutableReferences`; the constructor patches the real
   values — derived from its `_suffix` argument — into the runtime code as it is deployed. The local
   artifact is therefore a template, and the explorer shows the instantiated copy. Every differing
   byte falls inside those two slots:

   |                            | ForeignOmnibridge (Ethereum) | HomeOmnibridge (Gnosis)   |
   | -------------------------- | ---------------------------- | ------------------------- |
   | runtime size               | 23,586 bytes — equal         | 24,289 bytes — equal      |
   | differing bytes            | 11                           | 14                        |
   | all inside immutable slots | yes                          | yes                       |
   | `SUFFIX` slot              | `" from xDai"` @ 19913       | `" from Mainnet"` @ 19722 |
   | `SUFFIX_SIZE` slot         | `10` @ 20046                 | `13` @ 19855              |
   | trailing metadata hash     | identical                    | identical                 |

   Writing the two values into the artifact's placeholder slots reproduces the on-chain bytecode
   exactly, on both chains. The trailing CBOR metadata hash matching (`a264697066735822...` — the
   IPFS hash of the compiler metadata, which commits to the source files and settings) independently
   confirms both implementations were built from these sources with the settings in `foundry.toml`:
   solc 0.7.5, optimizer enabled, 200 runs, `istanbul`.

   Concretely, this is the entire mismatch between the local `forge build` output and the bytecode on
   the explorer:

   ```
   ForeignOmnibridge  @19913  SUFFIX
     local build : 0x0000000000000000000000000000000000000000000000000000000000000000
     explorer    : 0x2066726f6d207844616900000000000000000000000000000000000000000000   " from xDai"
   ForeignOmnibridge  @20046  SUFFIX_SIZE
     local build : 0x0000000000000000000000000000000000000000000000000000000000000000
     explorer    : 0x000000000000000000000000000000000000000000000000000000000000000a   10

   HomeOmnibridge     @19722  SUFFIX
     local build : 0x0000000000000000000000000000000000000000000000000000000000000000
     explorer    : 0x2066726f6d204d61696e6e657400000000000000000000000000000000000000   " from Mainnet"
   HomeOmnibridge     @19855  SUFFIX_SIZE
     local build : 0x0000000000000000000000000000000000000000000000000000000000000000
     explorer    : 0x000000000000000000000000000000000000000000000000000000000000000d   13
   ```

# Dev

Build

```
forge install foundry-rs/forge-std@v1.7.6
npx --yes yarn@1.22.22 install --ignore-engines --ignore-scripts
forge build
```

Test

```
FOUNDRY_PROFILE=e2e forge test --match-path test-e2e/BasicOmnibridgeFix.t.sol --fork-url https://ethereum-rpc.publicnode.com
```

# Verify

[`verify.sh`](../verify.sh) checks the two implementations above for you. From a fresh clone:

```
./verify.sh
```

Expect this, with `MATCH` on both and exit code 0:

```
=== ForeignOmnibridge (Ethereum)
  patching SUFFIX      @19913  " from xDai"
  patching SUFFIX_SIZE @20046  10
  local  : 23586 bytes  sha256(hex) f78beadad268c5747f5f25bac6f3e99b7857c20037b0586d91486897e5890529
  onchain: 23586 bytes  sha256(hex) f78beadad268c5747f5f25bac6f3e99b7857c20037b0586d91486897e5890529
  MATCH

=== HomeOmnibridge (Gnosis)
  patching SUFFIX      @19722  " from Mainnet"
  patching SUFFIX_SIZE @19855  13
  local  : 24289 bytes  sha256(hex) 1a4fd4f2d1b16add488dcfaec3b86d829e80ec19de8fdea201f6730daeb66b90
  onchain: 24289 bytes  sha256(hex) 1a4fd4f2d1b16add488dcfaec3b86d829e80ec19de8fdea201f6730daeb66b90
  MATCH

OK: both implementations match the local build.
```

The digest is over the `0x...` hex string, the same text the explorer and `out/*.json` show. To
cross-check one by hand, note there must be no trailing newline:

```
printf '%s' "0x6080..." | sha256sum   # Linux
printf '%s' "0x6080..." | shasum -a 256   # macOS
```

# Audit

[Audit report](./audit-tokenbridge-callback-gas-fix.pdf), [source](https://github.com/cducrest/audit-reports/blob/main/tokenbridge-callback-gas-fix.pdf)

# Acknowledgement

This bug is found by [heisenberg92](https://immunefi.com/profile/heisenberg92/) for the [Gnosis Chain's Immunefi Bug Bounty](https://docs.gnosischain.com/about/specs/bug-bounty).
