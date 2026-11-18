# Fix: callback amount must equal net delivery

## Problem

On Home, `HomeOmnibridge._handleTokens` deducts the `FOREIGN_TO_HOME_FEE` and releases only `valueToBridge = _value - fee` to the recipient. The three `*AndCall` handlers in `BasicOmnibridge` then called:

```solidity
_handleTokens(token, isNative, _recipient, _value);
_receiverCallback(_recipient, token, _value, _data); // gross amount
```

So `onTokenBridged` and the `ReceiverCallbackFailed` event reported the **gross** `_value`, but the recipient received the **net** amount. When the fee is nonzero, a receiver that acts on the reported amount (for example, forwarding or depositing `_value`) either reverts or pays the difference out of its existing balance.

Affected entry points: `deployAndHandleBridgedTokensAndCall`, `handleBridgedTokensAndCall` and `handleNativeTokensAndCall`. Foreign isn't affected in practice because it charges no fee, but it uses the same code path.

## Fix

`_handleTokens` now returns the amount it actually delivered, and the callback uses that return value.

```solidity
// BasicOmnibridge
function _handleTokens(address _token, bool _isNative, address _recipient, uint256 _value)
    internal
    virtual
    returns (uint256);

uint256 delivered = _handleTokens(_token, true, _recipient, _value);
_receiverCallback(_recipient, _token, delivered, _data);
```

- **`HomeOmnibridge`** returns `valueToBridge` (net of the fee) after emitting `TokensBridged`.
- **`ForeignOmnibridge`** returns `_value`, since it charges no fee.

What doesn't change:

- **Fee calculation:** the fee is still computed once, inside `_handleTokens`.
- **Limits and accounting:** daily limits and collateral accounting still use the gross amount (`addTotalExecutedPerDay(_token, ..., _value)` and `_releaseTokens(..., valueToBridge, _value)`).
- **Handlers without a callback:** `deployAndHandleBridgedTokens`, `handleBridgedTokens` and `handleNativeTokens` ignore the return value.

## Notes for integrators

- **Receivers on Home:** `onTokenBridged(token, value, data)` now gets the net amount, which equals the balance increase. When the fee is zero the value is the same as before.
- **Indexers:** `ReceiverCallbackFailed.value` is also the net amount now, consistent with `TokensBridged.value`.
