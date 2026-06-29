# Contract: RefineKeyDecoder (pure)

`BarkCore/Refine/RefineKeyDecoder.swift` — pure left-option detection, unit-tested. `HotkeyManager`
feeds it the fields of a `.flagsChanged` event; the decoder decides whether a refine turn opens or
closes. Keeps the OS-specific keycode constant in one tested place (constitution II).

## Shape

```swift
public enum RefineKeyEvent: Sendable, Equatable { case refineStart, refineEnd }

public enum RefineKeyDecoder {
    public static let leftOptionKeycode: Int64 = 58   // kVK_Option (right option = 61, ignored)

    /// - alternateOn: does the event's flags now contain the alternate (option) mask?
    /// - keycode:     the .flagsChanged event's keyboardEventKeycode field
    /// - fnHeld:      is the push-to-talk modifier currently held?
    /// - auxHeld:     is a refine turn currently open?
    public static func decide(
        alternateOn: Bool, keycode: Int64, fnHeld: Bool, auxHeld: Bool
    ) -> RefineKeyEvent?
}
```

## Behavioral contract

| # | alternateOn | keycode | fnHeld | auxHeld | → result |
|---|---|---|---|---|---|
| 1 | true | 58 | true | false | `.refineStart` |
| 2 | false | 58 | true | true | `.refineEnd` |
| 3 | true | 61 (right) | true | false | `nil` (right option ignored) |
| 4 | true | 58 | false | false | `nil` (no active fn session) |
| 5 | true | 58 | true | true | `nil` (already open — no re-trigger) |
| 6 | false | 58 | true | false | `nil` (release with nothing open) |
| 7 | true | 54 (other key) | true | false | `nil` |

## Notes

- The decoder is **edge-aware via `auxHeld`**: the caller tracks whether a turn is open and passes it
  in, so the decoder never double-fires.
- `fnHeld` gating (rows 4) ensures left option outside a dictation session is a normal modifier
  (Edge Case: "left-option with no active fn session → ignored").
- Right-option discrimination (row 3) is SC-004.
- Runtime keycode delivery is the documented best-effort residual; this decoder is the unit-tested
  evidence and an integration smoke test exercises the live tap.
