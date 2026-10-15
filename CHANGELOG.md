# Changelog

## 0.6.0

- User-locked keys: `License.activate(_:email:code:)` and `License.importLicenseFile(_:email:code:)`. A
  licence model can let only the person a key was sold to activate a new device on it, known by the
  address on the key (`email`), and, for a key that mails a code to that address, by the code too
  (`code`). Both are optional and default to nil, so every existing call is as it was and sends neither.
  Only a new device is ever asked: `refresh()`, `status()`, a renewal, a seat the key already holds and
  offline behaviour are unchanged. Nothing about the address or the code is stored.
- `LicenseError` has seven more cases, the refusals an app can act on: `.userEmailRequired` (ask for the
  address), `.userEmailMismatch`, `.userCodeRequired` (a code was just mailed: ask for it),
  `.userCodeInvalid`, `.tooManyCodes`, `.tooManyAttempts` and `.tryAgain` (the code could not be sent:
  nothing was activated, ask again). Their raw values are the server's words (`user-email-required`, ...).
  A `switch` over every `LicenseError` has seven more cases.
- An address longer than 254 UTF-16 units, or a code that is not exactly six ASCII digits (spaces inside
  it are dropped first), is refused by the SDK itself, for any key, before the server is asked
  (`.userEmailMismatch`, `.userCodeInvalid`). The conformance vectors' two new groups, `typedFor` and
  `userLockErrors`, hold this to the reference.

## 0.5.0

- Licence files: `License.importLicenseFile(_:)` takes a `.kglicense` file's content (`Data`, or a `String`;
  never a path) and verifies it offline. A key file activates its key, as `activate(_:)` would. An offline
  licence file is stored and licenses the app with no network, ever: `status()` answers it with `source`
  `.file` and `licensedTo`, before any key or trial, and `refresh()` asks nothing for it. It answers
  `ImportLicenseFileResult` (`.imported`, `.refused(LicenseFileError)`, `.notActivated(LicenseError)`) and
  throws behind a call that has not finished, or when the state cannot be read or saved.
  `removeLicenseFile()` drops it; `deactivate()` leaves it.
- `LicenseConfig.revokedLicenseFiles` lists the ids of files this build refuses: a stored one reads as
  `.invalid` with the new reason `.revokedFile`. A `switch` over every `LicenseReason` has one more case.
- `LicenseStatus` has `source` and `licensedTo` (nil on every status not from a file); `StoredState` has
  `licenseFile`, the stored offline file's token. `licenseFileExtension`, `licenseFileMediaType` and
  `maxLicenseFileBytes` give the format; `LicenseFileKind`, `LicenseFileError`, `LicenseSource` and
  `LicensedTo` are new. `LicenseCallError.previousCallUnfinished` is also what `importLicenseFile(_:)` and
  `removeLicenseFile()` throw behind a call that has not finished.

## 0.4.0

- `License.purchaseURL(paymentLink:)` and `InvalidPaymentLink` are removed, and the SDK no longer asks for
  a bought key at `status()`, `refresh()` or `startTrial()`. To sell from the app, open your Payment Link
  from your own Buy button; the customer types the key from the delivery email (`activate(_:)`). A purchase
  secret an earlier version stored is ignored, and left out the next time the SDK saves its state.
- `StoredState` no longer has `purchaseToken`, `purchaseTokenAt` or `claimAskedAt`, nor their `init`
  parameters: a storage adapter or test code that sets them stops compiling, and the same names among its
  `otherFields` are never written.

## 0.3.0

- Key sets: `LicenseConfig.publicJWK` takes the product's key set (`{"keys":[...]}`, as `/pubkey`
  answers it) or a list of JWKs, and one key as before (a set of one). A lease naming its key (`kid`)
  is verified by that key, one naming none by each key in turn.
- A lease signed by a key the build does not carry is `.invalid` with the new reason
  `LicenseReason.unknownKey`, rather than `.tampered`.
- Each activation, validate and claim sends the ids of the keys the build carries (`kids`).
- `License.has(_:)` and `License.require(_:)` answer, offline from the stored lease, whether the
  licence grants an entitlement; `require` throws `MissingEntitlement`. `grants(_:_:)` answers it of a
  status's entitlements.
- A public key's `x` is canonical base64url, as every KeyGrant SDK reads it: trailing padding is allowed;
  white space, the standard alphabet and stray bits are refused.
