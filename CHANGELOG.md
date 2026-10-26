# Changelog

## 0.9.0

- iPhone and iPad: the package builds for iOS and iPadOS 15 and later, with the same API. The device is an
  install id the SDK keeps in the Keychain (service `dev.keygrant.install`, account the product slug, on this
  device only), written at the first launch from `identifierForVendor` and kept across a reinstall; its
  fingerprint hashes `machine-id|ios:<id>`, as the Dart SDK's does on iOS. An iPhone or iPad never falls back to
  a host name, and offers none beside its id: when the Keychain cannot be read, the run cannot tell who it is,
  judges nothing, and an activation answers `.network`. Before the first unlock after a restart the state file
  cannot be read either: `status()` answers `.unknown`/`.storage` and an activation `.storage`.
- On iOS and iPadOS the state file is in the app container's `Library/Application Support/KeyGrant`, and the
  default registry stash is `KeychainTrialStash` (on this device only), so a reinstall cannot restart a trial.
  Elsewhere both defaults are as they were.
- Mac Catalyst 15 and later: an iPad app built for the Mac is a Mac to the SDK. It reads the Mac's
  `IOPlatformUUID`, as a Mac app does (no Keychain install id, which on a Mac would need a provisioning
  profile), keeps its state where a Mac app does, and has no default trial stash. A native Mac build and a
  Catalyst build of one product on one Mac are one device.
- `DefaultFingerprinter(product:)` is the default fingerprinter a `License` makes, and the one to wrap; on a Mac
  and on Linux it is the same as `DefaultFingerprinter()`, which iOS does not offer (the install id is the
  product's).
- The package ships a privacy manifest (`PrivacyInfo.xcprivacy`) for the App Store: no tracking; a device id,
  an email address when the app passes one, and product interaction (a running trial's launch report, metered
  uses), sent for the app's licensing and its trial figures; and why it reads file dates (C617.1) and the time
  since the device started (35F9.1).

## 0.8.1

- Documentation only, no code change: selling through Paddle, the upgrade link is your own checkout page,
  which reads `client_reference_id` from its address and gives it to Paddle.js as custom data under the
  same name. The README says how.

## 0.8.0

- Key pickup, for a build that may not take a typed licence key (an App Store build): a web buyer restores their
  licence by the address the key was sold to. `License.pickUp(email:)` mails a code to the address (`.sent` whether
  or not the address holds a key); `License.pickUp(email:code:)` hands back the address's keys of the product
  (`PickUpKeysResult.pickedKeys`, each a `PickedKey`: `key`, `model`, `modelName`, `state`, `entitlements`, `expiresAt`,
  `versions`, `deviceLimit`, `activeDevices`, `held`, `sale`, `activationCode`), each marked `held` when this device
  already holds a seat on it (the confirm names the device's fingerprints, as a validate does, when it can tell who it
  is); and `License.restoreByEmail(email:code:)` confirms the code and activates the key that fits this build (the one
  this device holds a seat on, else one with a free seat, else the first, of the keys that cover the build's major)
  as `activate(_:email:code:)` would, with the address and, for a code-locked key, the code the pickup handed back.
  The product's Key pickup must be on.
- The errors are `PickupError` (`invalidEmail`, `wrongCode`, `codeExpired`, `tooManyAttempts`, `pickupDisabled`,
  `tryAgain`, `network`) in a `PickupRefusal` with the server's `retryAfter` (seconds, from its answer's body), and
  `RestoreError` (`.pickup`, `.noKey`, and `.license` with a `LicenseError`: `.upgrade` or `.outdated` when none of the
  keys covers the build, then `activate`'s own). A blank address or a code that is not six digits (spaces inside it
  are dropped first) is refused by the SDK itself before the server is asked, so a mistyped code costs the address
  none of its wrong tries. A `switch` over every `LicenseError` is unchanged.
- The keys a confirm answered are kept in memory (never stored) for 10 minutes by the address and code as sent: a
  confirm or a restore with the same pair answers from them and asks nothing, since the first confirm spent the code,
  so a restore whose activation got no answer can be retried with the same code. A restore that activates drops them.
- Nothing else about a pickup is stored: not the address, the code or a refusal. The two `pickUp` calls write nothing
  and run beside any call; `restoreByEmail` runs one at a time with the rest, answers `.license(.network)` behind a
  call that has not finished (as `activate` does), and stores only the activation. A pickup never takes a licence
  away. The conformance vectors' four new groups, `pickupAsks`, `pickupRefusals`, `pickedKeys` and `pickupChoices`,
  hold it to the reference.

## 0.7.0

- Metered uses: `License.use(_:_:)` spends `n` uses (default 1) of a meter the key's licence model counts,
  before the work they count, and answers a `UseResult` (`ok`, `left`, `offline`, `error`). Online it is
  exact: the server takes `n` only while the meter has room for all of it (`.usedUp`, with `left`).
  With no answer (no network, a timeout, a 5xx, a 429 or an answer the SDK cannot use) the device spends
  from its offline allowance for the meter, never past what it last heard is left (`.offlineLimit`), and
  reports the spend with its next request. It never throws for an outcome, behind a call that has not
  finished too, and a call whose task is cancelled still runs to its bounded answer. `UseError` has the
  ten words every KeyGrant SDK uses (`.invalidAmount`, `.noMeter`, `.usedUp`, `.offlineLimit`, `.notLicensed`,
  `.storage`, `.revoked`, `.upgrade`, `.outdated`, `.device`), their raw values those words.
  `maxMeterUses` (1,000,000,000) is the most one spend may ask for.
- `LicenseStatus.meters` shows each meter of the lease that licenses the device (`MeterStatus`: `left`,
  `total`, `offline`, `unsynced`, `resets`), net of the uses this device spent and has not reported; it is
  empty on every other status. `LicenseStatus` takes `meters` in its initializer, its equality and its hash.
  No status reads a meter to decide whether the app is licensed.
- The journal of unsynced spends is kept in the state file (`StoredState.spends`, with the newest figures a
  spend was answered with in `StoredState.meterFigures`; `SpendEntry`, `SpendKind` and `MeterFigure` are
  new public types) and is sent with the next validate, `use` and `deactivate`; the server's confirmation
  drops an entry. It is capped at 64 entries and 16 voids (the take-back of a spend that was refused
  after its answer was lost; a new void past 16 takes the oldest one's place), an unreported entry is
  given up after 180 days, it is read leniently (an entry of another shape is left out when the state is
  read), and it never fails a renewal or a release. A spend the disk refuses is kept
  in memory, counted everywhere the state is read, and saved by the next call that can. A `deactivate()`
  that carries a report also names the device's fingerprints, as a validate does.
- `status()` on a valid lease also asks, once its own wait is over (a minute after an unanswered spend,
  doubling to an hour), when the journal holds an entry a request would report, so a device back online
  gives its allowance back. An answer to a validate that carried a report and confirmed none of it starts
  the wait of an answer without a lease.
- The lease's `met` claim is read leniently: a meter whose figures are not whole numbers from 0 to 2^53 - 1
  (a fraction, a negative, a figure out of a double's range such as `1e400`) is left out, never the lease or
  the meters beside it.
- The conformance vectors' twelve metered-uses groups are replayed (410 of their 412 vectors: the two that
  give `use` a fraction and a text are JavaScript's only), with the captured request bodies, behaviour
  tests, and a seeded property test of two processes over one state file (1,500 sequences).

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
