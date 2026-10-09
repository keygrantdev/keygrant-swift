# KeyGrant for Swift

Client-side licensing for macOS apps (SwiftUI or AppKit), and Linux. A port of the reference
Electron SDK (`@keygrant/electron`), held to the same behaviour by the shared conformance vectors
(`conformance/vectors.json`). The full guide is at https://keygrant.dev/docs.

A licence is proven to the app by a signed lease (a JWT, EdDSA over Ed25519) that the app checks
**offline** against the product's public key. The app goes online only to activate, to renew a
lease near or past its end, to tell the server it runs a newer major version, to pick up a key
the customer bought from the app ([Buying from the app](#buying-from-the-app)), or, at most once
a day and in the background, to report a running trial's launch. Licensing fails
in favour of the paying customer: an outage, no network, a 5xx, a 429, an ambiguous 4xx or an
answer the SDK cannot use never takes away a lease that is still valid. Only an explicit verdict
from the server, or the lease's own end, does.

- Swift 6 language mode (strict concurrency), Swift 6 toolchain (Xcode 16 or later).
- macOS 12 or later, and Linux.
- One dependency: [`apple/swift-crypto`](https://github.com/apple/swift-crypto), which is
  CryptoKit itself on Apple platforms.

## Install

Add the package by its URL. In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/keygrantdev/keygrant-swift.git", from: "0.3.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "KeyGrant", package: "keygrant-swift")]),
]
```

In Xcode: File > Add Package Dependencies..., enter `https://github.com/keygrantdev/keygrant-swift.git`,
and add the `KeyGrant` library to the app target.

## Quick start (SwiftUI)

```swift
import KeyGrant
import SwiftUI

/// The product's public keys: the `keys` of
/// `GET https://api.keygrant.dev/v1/products/sluice/pubkey`, fetched when you build and shipped
/// with the app ("Embedding the public keys", below). Public: safe to ship.
let productKey = #"{"keys":[{"kty":"OKP","crv":"Ed25519","x":"<the x of your product's key>"}]}"#

@MainActor
final class Licensing: ObservableObject {
    @Published private(set) var status: LicenseStatus?
    @Published private(set) var activationError: LicenseError?
    /// Set when this build cannot check a licence at all: the key it embeds is not the product's.
    @Published private(set) var configError: LicenseConfigError?

    /// One License for the app.
    private let license: License?

    init() {
        do {
            license = try License(LicenseConfig(
                product: "sluice",
                apiBaseURL: URL(string: "https://api.keygrant.dev")!,
                publicJWK: productKey,
                major: 3  // the app's major version: set it, the server checks keys by it
            ))
        } catch let error as LicenseConfigError {
            // Not an Ed25519 public key: a mistake in the build, which its first run shows. Say
            // what is wrong rather than crash.
            license = nil
            configError = error
        } catch {
            // `License(_:)` throws nothing but `LicenseConfigError`.
            license = nil
        }
    }

    func check() async { status = await license?.status() }
    func tryAgain() async { status = await license?.refresh() }
    func startTrial() async { status = await license?.startTrial() }

    func activate(_ key: String) async {
        guard let license else { return }
        let result = await license.activate(key)
        activationError = result.error
        if result.isActivated { await check() }
    }
}

@main
struct SluiceApp: App {
    @StateObject private var licensing = Licensing()

    var body: some Scene {
        WindowGroup {
            Root()
                .environmentObject(licensing)
                .task { await licensing.check() }  // at launch: offline-first, usually instant
        }
    }
}

struct Root: View {
    @EnvironmentObject var licensing: Licensing

    var body: some View {
        if let error = licensing.configError {
            Text("This build cannot check its licence: \(error.description)")
        } else {
            switch licensing.status?.state {
            case .licensed?, .trial?, .unknown?:
                MainWindow()  // `.unknown`: the licence file could not be read just now. Keep running.
            case .expired?, .invalid?, .unlicensed?:
                ActivationView()  // say why from `status.reason` (below); offer activate / trial / buy
            case nil:
                ProgressView()
            }
        }
    }
}
```

AppKit is the same: call the methods from a `Task { ... }` and hop back to the main actor for the UI.
Every call is `async` and safe to call from any thread or actor.

## The API

| Call | Answers |
|---|---|
| `License(_ config:) throws` | throws `LicenseConfigError` only for a public key it cannot use |
| `status(forceOnline: Bool = false) async -> LicenseStatus` | never throws |
| `refresh() async -> LicenseStatus` | `status()` forced online: call it when the customer says they have paid, or on a "Try again" |
| `activate(_ key: String) async -> ActivateResult` | `.activated` or `.failed(LicenseError)`; never throws |
| `startTrial() async -> LicenseStatus` | never throws |
| `deactivate() async throws -> DeactivateResult` | releases the seat and drops the local licence (trial evidence kept); `released` says whether the seat is free (below) |
| `upgradeURL(paymentLink: URL) async -> URL?` | the payment link with this device's activation id as `client_reference_id` (never the key) |
| `purchaseURL(paymentLink: URL) async throws -> URL?` | the payment link a customer with no key buys through, picked up by the app with nothing typed ([Buying from the app](#buying-from-the-app)); nil while a key is held |

`deactivate()` drops the local licence whatever the server says, and answers `released: true`
only when KeyGrant confirmed the release (a 200), or when this device held no activation to
release. `released: false` (no answer, a 5xx, a 429, a proxy's page) means the seat may still be
held: say so, and point the customer to support (the dashboard can release it), rather than tell
them the seat is free. It never releases another device's seat: a state file copied or restored
from another PC (a roaming profile, a backup, a cloned disk) carries that PC's activation, and
when the lease stored is held to another machine (expired or not), or a device refusal stands
for this one, it only drops it here and asks nothing (`released: true`: this device held no
seat), so that PC is not locked out. It throws `LicenseCallError.previousCallUnfinished` behind a
call that has not finished (nothing is released or dropped then), and the storage's error when
the state cannot be saved (the local licence is kept then: call it again).

### `LicenseConfig`

| Field | Default | |
|---|---|---|
| `product` | | the product slug |
| `apiBaseURL` | | `https://api.keygrant.dev` |
| `publicJWK` | | the product's public keys: the key set of `GET /v1/products/<product>/pubkey` (`{"keys":[...]}`, or that whole answer), a JSON list of JWKs, or one key, a set of one: its JWK, or its bare `x` ([Embedding the public keys](#embedding-the-public-keys)) |
| `major` | `1` | the running app's major version, read as the server reads a version: a 0.x build sets `0` and runs as major 1 (as does anything below 1), so a lease for major 1 licenses it |
| `deviceName` | nil | a label for the device list (cut to 120 UTF-16 units). On a Mac, `SCDynamicStoreCopyComputerName(nil, nil) as String?` gives "Rae's MacBook Pro" without the DNS lookup `Host.current()` makes |
| `deviceHold` | `true` | below |
| `httpTimeout` | 15 s | how long any one request may take; the SDK holds every request to it itself |
| `adapters` | defaults | `LicenseAdapters(storage:registry:clock:fingerprinter:http:)`, any nil for the default |

### Statuses

| `state` | `reason` | What to show |
|---|---|---|
| `.licensed` | | the app. `isTest`: a TEST licence (refuse it in a release build if you like); `entitlements`: what it grants ([Entitlements](#entitlements)) |
| `.trial` | | the app; `trialDaysLeft`, `trialEndsAt` (ms: the end the trial lease was signed to), `trialEndDate`, `entitlements` |
| `.expired` | `.offline` | the lease ran out and the server could not be reached: "connect to renew" |
| `.expired` | `.trial` | the trial is over: buy (`purchaseURL`) |
| `.invalid` | `.revoked` | the key was revoked or has expired, or this device was released |
| `.invalid` | `.upgrade` | this build is newer than the key covers: buy an upgrade (`upgradeURL`) |
| `.invalid` | `.outdated` | this build is older than the key covers: update the app |
| `.invalid` | `.device` | the licence was activated on another device: activate again here |
| `.invalid` | `.tampered` | the lease is not for this licence at all: activate again |
| `.invalid` | `.unknownKey` | the lease is signed by a key this build does not carry; online, the server renews it with the key it signs with now. When it stays so online: update the app |
| `.unlicensed` | | nothing held: activate or start a trial |
| `.unknown` | `.storage` | the licence file could not be read just now: keep running, ask again shortly; never show the activation screen for it |

`isStalled`: an earlier call on this `License` has not finished (a storage adapter stuck, say), so
the answer comes from what is stored, with no ask and no write. A restart clears it.

### Activation errors

`invalidKey` (no such key, or text that cannot be one), `limit` (on as many devices as it
allows), `revoked`, `upgrade`, `outdated`, `network` (try again), `invalidLease` (the server's
lease does not verify with the embedded key: a configuration error), and `storage` (the licence
file could not be read or saved: try again). The key is trimmed and upper-cased before it is sent,
so a pasted key with a newline, or one typed in lower case, works.

## Buying from the app

A customer on a trial (or with nothing yet) buys through `purchaseURL(paymentLink:)`, and the app
picks the key up itself, for a product with "Converts in place" on: nothing to copy from an
email, nothing to type. Add to the quick start's `Licensing`:

```swift
/// The product's payment link, from the dashboard.
private let paymentLink = URL(string: "https://buy.stripe.com/test_abc")!
/// Whether a checkout this app opened may still be going on.
private var checkoutOpened = false

/// "Buy" on the trial or activation screen.
func buy() async {
    guard let license else { return }
    do {
        // nil while a key is held: an upgrade goes through `upgradeURL(paymentLink:)`.
        if let url = try await license.purchaseURL(paymentLink: paymentLink) {
            NSWorkspace.shared.open(url)
            checkoutOpened = true
        }
    } catch {
        // The state could not be saved just now (or the link is not an absolute URL): say so.
    }
}

/// When the customer is back (the app comes to the front, say), and only while a checkout is
/// open: `refresh()` on a licensed install validates online every time.
func customerReturned() async {
    guard let license, checkoutOpened, await license.status().state != .licensed else { return }
    status = await license.refresh()  // `.licensed` once the checkout has gone through
    if status?.state == .licensed { checkoutOpened = false }
}
```

- **The link** carries a reference, `kgp_` and a hash of a one-time secret this install keeps:
  256 random bits from the system's secure generator, never the device's fingerprint. The secret
  stays on the device and is sent only when the app asks for the key, so a link that leaks
  (browser history, a screenshot) claims nothing. It is made the first time, kept, and every later
  call hands out the same secret's link, so the key bought through either link is picked up
  (paying twice buys two keys; the second comes by email). The link's own parameters and fragment
  are kept; a `client_reference_id` already on it is replaced.
- **The pickup:** once the checkout has minted the key, `refresh()` or `startTrial()` asks for it
  at once, activates this device on it exactly as `activate(_:)` would, and answers `.licensed`.
  `status()` asks on its own too, at most once every 5 minutes for a day after the link, bounded
  as any check it makes (5 s), so a customer who simply returns to the app finds it licensed;
  after that day only `refresh()` and `startTrial()` ask, so an abandoned checkout costs no launch
  a request. `status()` and `refresh()` ask only under the device's own fingerprint (a machine
  whose id did not read this time is asked nothing, and asks at the next call); `startTrial()`,
  which reads the device once for both its asks, may use the host name. Each ask also sends every
  fingerprint the run read (the first four the server takes), so a key bought earlier is answered
  again to this device even when it was read differently since. "Not bought yet", no
  network, or a server that cannot say keeps the secret for the next ask; an answer that the key
  will never come this way (another device took it, the product has "Converts in place" off, an
  activation refused) lets the secret go, and the customer types the key from the delivery email
  as before.
- **The secret goes** once a key bought with it is picked up, when any key is activated here or
  this device is deactivated, and 30 days after the last `purchaseURL(paymentLink:)`. Letting it
  go is this device's alone: it revokes nothing on the server.
- **It throws** `InvalidPaymentLink` for a link that is not an absolute URL (before anything is
  read), the storage's error when the state cannot be read or the secret cannot be saved (a link
  whose secret was not kept could never be picked up), and
  `LicenseCallError.previousCallUnfinished` behind a call that has not finished while no secret
  is held (one held gives its link as it is).
- **Turn the product's "Converts in place" switch on** once your app uses
  `purchaseURL(paymentLink:)`: it is off by default, and until it is on every pickup is refused
  and the customer types the key from the delivery email. Know the trade before you do: whoever
  opens a checkout owns its pickup. Your Payment Link is public, so anyone can add a
  `client_reference_id` of their own to it and get buyers to pay through their copy of the link;
  the key bought that way is picked up by the link's maker, not the buyer. A link from the app is
  the buyer's own; a leaked one claims nothing, as it carries only a hash of the app's secret. A
  planted pickup shows in the key's history, and you can free the seat for the buyer.

## Embedding the public keys

The product's public keys are the `keys` of
`GET https://api.keygrant.dev/v1/products/<product>/pubkey`, which is public and needs no API key,
and the dashboard's Signing key tab copies the same set (Copy key set). Fetch them when you build
and ship them with the app:

```sh
curl -s https://api.keygrant.dev/v1/products/sluice/pubkey | jq -c '{keys}'
# {"keys":[{"kty":"OKP","crv":"Ed25519","x":"...","kid":"..."}]}
```

Embed the set as a string (a raw string literal, as in the quick start), or ship it as a bundled
resource and read it at launch. One key alone, its JWK or its bare `x`, still works: a set of one.
They are public: anyone may see them. A JWK that holds the PRIVATE key (`d`) is refused at once:
never ship that.

**Why a set.** A lease names the key that signed it (`kid` in its header, the key's RFC 7638
thumbprint, which the SDK computes from the key itself). It is verified by that key; a lease that
names none (every lease signed before key sets) by each key in turn; and one naming a key the build
does not carry is refused (`.unknownKey`). When the product rotates its signing key, it first
*stages* the next key, published beside the current one while every lease is still signed with the
current key. Ship builds carrying both; once they are out, the product *switches*, and those builds
verify every lease signed after it. Embed the whole set each time you build. Each activation,
validate and claim reports the ids of the keys the build carries (`kids`), so the dashboard can
count the devices still on builds without the staged key before you switch.

`License(_:)` checks the key at once and throws `LicenseConfigError` for one it cannot use. Read
from a resource, the key can be wrong in a shipped build (a stale or missing file), so handle the
error as the quick start does. Only when the key is a **literal in the source** is a `try!` fine:
a key it cannot use then fails the first run, the developer's, and never a customer's.

```swift
// The key is a literal in the source: a bad one stops the first run, never a customer's.
let license = try! License(LicenseConfig(
    product: "sluice", apiBaseURL: URL(string: "https://api.keygrant.dev")!, publicJWK: productKey, major: 3
))
```

## Holding a licence to its device

A lease names the device it was activated on, by a hash of its fingerprint. The default
fingerprint is the operating system's machine id, hashed so it never leaves the machine:

- **macOS:** the platform expert's `IOPlatformUUID`, read in-process through IOKit (no
  `/usr/sbin/ioreg` subprocess, which a sandboxed Mac App Store app cannot launch). It is the
  same UUID the Electron SDK reads, so a Mac has the same fingerprint under either SDK.
- **Linux:** `/etc/machine-id`, else `/var/lib/dbus/machine-id`; an id on a filesystem in memory
  (tmpfs, ramfs) or written at this boot counts as none.

A machine with no id falls back to its host name. A device is never refused because a read was
slow: a read that does not finish in time means "cannot tell", and nothing is judged. The id is
read once per process, whatever number of `License`s it has.

`deviceHold: false` is for non-persistent pooled VDI, where every session may be another
machine: no lease is then judged by its device and the server is told no fingerprints (the device
limit still counts seats). A custom `Fingerprinter` that only implements `get()` is never held to
its device; implement `identify(timeout:)` and report `kind: .machine` for a stable machine id.

## Test licences

A test licence (from the dashboard's scenarios, a `kg_test_` API key, or a Stripe test-mode
checkout) licenses the app like any other and says so: `status.isTest == true`. A release build
that wants nothing to do with them checks it.

## Entitlements

A licence can grant more than the base product: an edition, a number of seats, an add-on. Its
lease signs them (the `ent` claim), and the status that rests on the lease hands them to the app
as `entitlements`, read offline like everything else on the lease:

```swift
let status = await license.status()
let isPro = status.entitlements["edition"] == .string("pro")
let seats = status.entitlements["seats"]?.numberValue ?? 1
```

- **Type:** `[String: Entitlement]`. An `Entitlement` is `.bool(Bool)`, `.number(Double)` or
  `.string(String)`; `boolValue`, `numberValue` and `stringValue` read one as that kind (nil for
  another), and a literal stands for one (`status.entitlements["edition"] == "pro"`). Numbers are
  doubles, read correctly rounded as JSON and JavaScript read them: `5` and `5.0` are the same
  entitlement. A text is compared unit for unit, as JavaScript compares it
  ([Parity](#parity-with-the-reference)). Names are the dictionary's keys, which Swift compares by
  canonical equivalence (an "é" composed and one decomposed are one key); KeyGrant signs names
  only in Unicode's composed form (NFC), so no two names a lease carries are ever taken for one.
  The dictionary is the app's own copy: changing it changes nothing the SDK holds, nor the next
  status.
- **When there are some:** on a `.licensed` status, from the licence's lease (offline, after an
  activation, a renewal or a `refresh()`, and behind a call that has not finished), and on a
  `.trial` status, from the trial's lease, when that lease grants at least one.
- **When it is empty:** on every other status (`.expired`, `.invalid` for any reason, a stored
  refusal included, `.unlicensed`, `.unknown`), and when the lease grants none, so a product that
  grants no entitlements sees no difference: a lookup reads nil either way.
- **A malformed claim never costs the licence:** a member that is not a flag, a number or a text
  is left out, and an `ent` that is not an object at all reads as none. The SDK enforces none of
  the caps the server holds entitlements to (how many, how long): the signature is what it trusts.

To ask whether the licence grants an entitlement, name its code:

```swift
if await license.has("cloud_sync") { enableCloudSync() }
try await license.require("export") // throws MissingEntitlement(entitlement: "export")
```

`has(_:)` is true for a flag that is on, a number that is not zero, or a text that is not empty;
false for anything else, and for a code the lease does not grant (a dictionary key, so compared by
canonical equivalence, as above). It is answered offline from the stored lease only, as `status()`
would answer from what is stored, with no request and no write: a licence that does not license
this build, or none at all, grants nothing; a running trial grants what its trial lease does.
`require(_:)` throws `MissingEntitlement`, naming the code, when `has(_:)` would be false.
`grants(status.entitlements, code)` answers the same of a status already in hand.

## Where the state is kept

One JSON file per product, per user, on this machine:

- **macOS:** `~/Library/Application Support/KeyGrant/<product>.json`. In a **sandboxed** app the
  home folder is the app's container, so the file is
  `~/Library/Containers/<bundle id>/Data/Library/Application Support/KeyGrant/<product>.json`.
  That is fine: it is still per user and machine-local. (A non-sandboxed Mac app uses the same
  path the Electron SDK does, so an app moving from Electron to Swift keeps its licence; a
  sandboxed one cannot see that file.)
- **Linux:** `$XDG_CONFIG_HOME/keygrant/<product>.json`, else `~/.config/keygrant/<product>.json`.

The home folder is `$HOME` as the process has it when the `License` is made, else the user's
home folder. The file has the same field names as every KeyGrant SDK's, so it is portable between
them. It is written atomically (a temp file flushed to the disk, `F_FULLFSYNC` on macOS, then
renamed over the file), readable by this user only; two instances of the app saving at once
never lose each other's fields (a revision stamp is checked just before the rename and the save
merged again). Only a missing file is "no state", and even then the newest whole temp file left
beside it (a write that finished but was never renamed in) is read first. Any other read failure
is tried again for about a second, then `status()` answers `.unknown`/`.storage`. A file that
does not parse is set aside as `<file>.<ms>.corrupt` (the newest three kept) and an empty state
written in its place. A call running read-only (`isStalled`) writes nothing at all.
`FileStorage(path: migratingFrom:)` puts the file elsewhere, copying the state an app kept at an
older path the first time.

A custom `StorageAdapter` (the Keychain, say) implements `read(readOnly:)`, which must write
nothing at all when `readOnly` is true, and `write(_:)`; `update(_:)` is optional (the default
reads, merges and writes). Encode `StoredState` with `JSONEncoder`/`JSONDecoder`.

## Trials and the Keychain

`startTrial()` asks the server for this device's trial; the trial start only ever moves earlier.
Call it when the customer starts the trial; there is no need to call it on every launch. A running
trial reports its launch itself: `status()` answering `.trial` (with no key held) sends the server
this device's trial, at most once a day and in the background, so the dashboard's trial funnel
sees the trial come back. It saves the day's stamp first (and sends nothing when it cannot), then
sends from a task of its own: `status()` never waits for that report, and a report that fails
(offline, say) costs nothing; its answer is not read, so a change to the trial's length or
entitlements reaches a running trial at its next `startTrial()`. A `startTrial()` counts as that
day's report.

A trial runs only while its trial lease is valid: KeyGrant signs it to the trial's own end, so an
honest trial holds a valid one for every day it runs, offline included, and `trialEndsAt` is the
end it was signed to. The end stored beside it in the state file is not signed: editing it
changes nothing.

A trial whose lease does not verify while its stored end is still ahead (a lease signed before the
product's key was rotated, on a build that ships the new key; one signed to end short of the trial's
end) is asked for again by `status()`, bounded as any check `status()` makes (5 s). A trial it can
verify is the answer. Otherwise the trial reads as expired, and `status()` waits before asking
again: a minute when nothing answered, an hour when the server did. `refresh()` asks whatever the
wait; a call behind one that has not finished never asks.

To make a reinstall unable to restart a trial, give a registry stash that outlives the app:

```swift
adapters: LicenseAdapters(registry: KeychainTrialStash(product: "sluice"))
```

`KeychainTrialStash` keeps the start in a generic-password Keychain item, which survives the app
being deleted. By default it uses the data protection keychain, which never prompts but needs an
app with an application identifier (any App Store app, or one with a provisioning profile);
`keychain: .login` works for any app but may prompt when a differently signed build (an ad-hoc
development build) reads the item. It writes only on what it read: it adds the item when there
is none, replaces it only with an earlier start, and leaves alone an item it cannot read (a
locked keychain), whose start nobody could see. A stash that cannot be read or written costs
nothing: the trial falls back on the server's record and the state file.

## Networking and the App Sandbox

The default HTTP adapter is `URLSession` (an ephemeral session: no cookies, no cache). A
**sandboxed** app needs the outgoing-connections entitlement (`com.apple.security.network.client`,
"Outgoing Connections (Client)" in Xcode). Without it every request fails: a valid lease keeps the
app licensed offline, but activation answers `network`.

## Concurrency

`License` is a `Sendable` final class: create one and share it. Calls on one `License` run one at a
time, so `status()` from several places at once asks the server once and never writes back a stale
state. A call waits for the one before it, but at most that call's HTTP bound plus 15 seconds
(plus 5 more after a `startTrial()`, which may ask twice: for a bought key, then for the trial);
then it runs read-only (`isStalled`). Every call runs in a task of its own: cancelling the task
that awaits it (a SwiftUI `.task` whose view went away) does not cut a licence check, or its save,
short; it finishes within its bounds. The file reads and writes run on a thread of their own at
the quality of service of the task waiting on them, never below user-initiated: a check made from
a background task would otherwise hold up, behind its throttled I/O, the activation a customer
is waiting on. Results come back on whatever executor you awaited from; update UI state on the
main actor.

## Testing your integration

Every piece of I/O is an adapter: give your tests a `LicenseClock`, an `HTTPAdapter` that answers
from a script (a `LicenseHTTPResponse` with a `LicenseJSON` body), a `StorageAdapter` in memory
and a fixed `Fingerprinter`. This package's own tests (`Tests/KeyGrantTests/Support`) have
examples of each.

## Building and testing this package

```sh
swift build
swift test
```

The tests read `conformance/vectors.json`, the answers every KeyGrant SDK must give, generated from
the reference SDK. The edges of the SDK's own time bounds are tested on a clock the test moves by
hand, not raced against a real one. Every suite has a time limit of a minute (on Linux, and on
macOS 13 or later: Swift Testing keeps none on macOS 12); since a limit ends only what heeds
cancellation, the tests' own waits on the SDK also fail after 20 seconds of real time rather than
hang.

## Parity with the reference

Every group of the conformance vectors is reproduced, every answer, but for two kinds of vector: the
Windows cases of `machineIds`, which pin `reg.exe` output parsing (this SDK has no Windows reader),
and the `majors` with a fraction (marked `jsOnly`), which the reference's JavaScript number can hold
and `LicenseConfig.major` (an `Int`) cannot; a major below zero is reproduced (it runs as 1). The
decisions the vectors pin are the functions the SDK itself calls (`renewalOutcome`,
`asksOnValidLease`, `deviceFrom`, `identityOf`, `savedLastSeen`, `claimOutcome`, `claimRequest`,
`referencedLink` among them), and answers are compared exactly: text unit for unit, and in a patch a
field cleared (`null`) apart from one left alone (absent). Where this SDK differs from the reference
Electron SDK, and why:

- **`activate(_:)` never throws.** When the state file cannot be read or saved, the reference
  rejects; this answers `.failed(.storage)` (a `LicenseError` case the reference does not have),
  so the app can say what is wrong and retry. `deactivate()` throws, as the reference's rejects,
  and answers `DeactivateResult` (`released`) as the reference's answers `{released}`; its
  result may be discarded.
- **`upgradeURL(paymentLink:)`** takes a `URL` and answers nil when the state cannot be read just
  now, or the link is not an absolute URL (the reference rejects both).
- **`purchaseURL(paymentLink:)`** takes a `URL` and throws `InvalidPaymentLink` for one that is
  not an absolute URL (the reference rejects with a `TypeError`). Both links are built by the
  reference's one rule (`referencedLink`), but from the link as `URL` holds it: the reference's
  URL parser writes a link in its normal form first (a lower-case scheme and host, a `/` for an
  empty path), which this SDK leaves as given. The purchase secret comes from
  `SystemRandomNumberGenerator` (`arc4random_buf` on Apple platforms, `getrandom` on Linux), the
  reference's from Node's `randomBytes`.
- **The launch report** is sent from a task of its own that nothing awaits (the reference's
  promise that nothing awaits); `status()` answers before its device read and its request.
- **`License(_:)` throws `LicenseConfigError`** for a public key it cannot use, at once. The
  reference fails later, at the first lease it verifies.
- **Naming:** `LicenseClock`, not `Clock` (a public `Clock` would shadow the standard library's
  `Clock` in every file that imports KeyGrant); `LicenseJSON` and `LicenseHTTPResponse`, formerly
  `JSONValue` and `HTTPResponse` (names many modules use: those remain as deprecated aliases, so
  code written against them still builds, until a major version removes them); `HTTPAdapter`,
  `publicJWK`, `apiBaseURL`, `httpTimeout` (seconds); `LicenseStatus.isTest` and `isStalled` are
  `Bool` (the reference's `test` and `stalled` are present only when true), and
  `LicenseStatus.entitlements` is empty when the lease grants none (the reference's is absent
  then). `trialEndDate` is added.
- **`Fingerprinter.identify`** is a protocol requirement with a default implementation, which
  stands for the reference's optional method: a fingerprinter that does not implement it is read
  through `get()` with the status bound, exactly as in the reference.
- **The machine id on macOS** is read through IOKit in-process rather than by running `ioreg`
  (the same `IOPlatformUUID`), bounded by the status or activation bound itself (the reference
  adds half a second for its subprocess). There is no Windows reader: the Windows cases of the
  `machineIds` vectors are not replayed; the macOS ones are, through the IOKit-shaped source.
- **The host-name fingerprint** uses Node's names for the platform and architecture this binary
  runs as (`darwin`, `linux`, `openbsd`...; `x64`, `arm64`, `ppc64`, `s390x`, `riscv64`...), as
  Node's `os.arch()` does for its process: a native Apple-silicon build says `arm64` where an x64
  Electron build under Rosetta says `x64`. That fingerprint is only an alternate beside the
  machine id, so a seat is not affected.
- **No default migration** from `<working directory>/.keygrant/<product>.json`, the legacy location
  older Electron SDK versions used. `FileStorage(path:migratingFrom:)` does it for an app that asks.
- **The state file** is created readable by this user only (`0600`; the reference leaves it to the
  umask, usually `0644`): it holds the licence key.
- **Numbers in the state file** are whole: a fraction is cut toward zero, a value past
  ±(2^53 - 1) or of the wrong type is left out, and a JSON value that is no object is no state
  (the reference carries whatever JSON holds). Fields this SDK does not know are kept and written
  back (`StoredState.otherFields`). A server's trial start or end with a fraction is cut the same
  way.
- **JSON is read as `JSON.parse` reads it** (a server's body and a lease's payload decoded as
  `TextDecoder` decodes them, the state file as Node's `readFile` gives it), and written as
  `JSON.stringify` writes it, but for what a Swift value cannot hold: an escaped lone surrogate
  (`"\ud800"`) reads as U+FFFD; two member names that are only canonically equivalent (an "é"
  composed and one decomposed) are one member, with the last value (an entitlement's name never
  meets this: KeyGrant signs names only in NFC); nesting deeper than 1,000
  levels does not parse (a Swift value that deep is released recursively, and a macOS thread's
  512 KB stack holds about 2,000 levels of that); and members are written sorted, not in the
  order they were added. `LicenseJSON`'s `Codable` conformance goes through Foundation's coders,
  with their limits; the SDK itself does not use it.
- **A call is never cut short by cancellation.** The reference has no cancellation; here each call
  runs in its own task, so a cancelled caller still gets (and saves) its answer within the bounds.
- **The default HTTP adapter bounds the whole request** itself (`URLRequest.timeoutInterval` is an
  idle timeout, and Linux's `URLSession` does not keep even that). The product slug is
  percent-encoded in the path (no change for a slug).
- **`KeychainTrialStash`** (the macOS analogue of the Windows registry stash an Electron app
  injects) only ever moves the stashed start earlier, and writes nothing over an item it cannot
  read.
- **Strings are compared unit for unit**, as JavaScript's `===` does, not by Swift's canonical
  equivalence, so a key, product or activation id matches exactly when the reference's would, and
  an `Entitlement` text equals another exactly when the reference's would.
