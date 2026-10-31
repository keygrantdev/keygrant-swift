# KeyGrant for Swift

Client-side licensing for macOS apps (SwiftUI or AppKit), iPhone and iPad apps (SwiftUI or UIKit),
Mac Catalyst apps, and Linux. A port of the reference
Electron SDK (`@keygrant/electron`), held to the same behaviour by the shared conformance vectors
(`conformance/vectors.json`). The full guide is at https://keygrant.dev/docs.

A licence is proven to the app by a signed lease (a JWT, EdDSA over Ed25519) that the app checks
**offline** against the product's public key. The app goes online only to activate, to renew a
lease near or past its end, to tell the server it runs a newer major version, to spend a metered
use or report the uses the device spent while it got no answer (with its next `status()`, validate
or `deactivate()`), or, at most once a day and in the background, to report a running trial's launch.
Licensing fails in favour of the paying customer: an outage, no network, a 5xx, a 429, an ambiguous 4xx or an
answer the SDK cannot use never takes away a lease that is still valid. Only an explicit verdict
from the server, or the lease's own end, does.

- Swift 6 language mode (strict concurrency), Swift 6 toolchain (Xcode 16 or later).
- macOS 12 or later, iOS and iPadOS 15 or later ([iPhone and iPad](#iphone-and-ipad)), Mac Catalyst 15 or
  later, and Linux.
- One dependency: [`apple/swift-crypto`](https://github.com/apple/swift-crypto), which is
  CryptoKit itself on Apple platforms.

## Install

Add the package by its URL. In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/keygrantdev/keygrant-swift.git", from: "1.0.0"),
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
                MainWindow()  // `.unknown`: the state file could not be read just now. Keep running.
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
| `activate(_ key: String, email: String? = nil, code: String? = nil) async -> ActivateResult` | `.activated` or `.failed(LicenseError)`; never throws. `email` and `code` are what a person typed for a user-locked key ([User-locked keys](#user-locked-keys)) |
| `startTrial() async -> LicenseStatus` | never throws |
| `deactivate() async throws -> DeactivateResult` | releases the seat and drops the local licence (trial evidence kept); `released` says whether the seat is free (below) |
| `importLicenseFile(_ content: Data, email: String? = nil, code: String? = nil) async throws -> ImportLicenseFileResult` | takes a licence file's content (or `String` text), verified offline: an offline file is stored and licenses the app with no network; a key file's key is activated as `activate(_:email:code:)` would, with the same `email` and `code` ([Licence files](#licence-files-drag-and-drop)) |
| `removeLicenseFile() async throws` | drops the stored offline licence file; a key the device holds keeps working |
| `use(_ meter: String, _ n: Int = 1) async -> UseResult` | spends `n` uses of a meter the key's licence model counts, exact online and from an offline allowance with no answer; never throws. `UseResult { ok, left, offline, error }` ([Metered uses](#metered-uses-counting-what-a-key-may-do)) |
| `upgradeURL(paymentLink: URL) async -> URL?` | the payment link with this device's activation id as `client_reference_id` (never the key) |

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
| `revokedLicenseFiles` | `[]` | the ids of licence files this build refuses (an offline file that leaked), matched exactly |
| `adapters` | defaults | `LicenseAdapters(storage:registry:clock:fingerprinter:http:)`, any nil for the default |

### Statuses

| `state` | `reason` | What to show |
|---|---|---|
| `.licensed` | | the app. `isTest`: a TEST licence (refuse it in a release build if you like); `entitlements`: what it grants ([Entitlements](#entitlements)); `meters`: what it counts ([Metered uses](#metered-uses-counting-what-a-key-may-do)). With `source` `.file`, a stored offline licence file licenses it: show `licensedTo` |
| `.trial` | | the app; `trialDaysLeft`, `trialEndsAt` (ms: the end the trial lease was signed to), `trialEndDate`, `entitlements` |
| `.expired` | `.offline` | the lease ran out and the server could not be reached: "connect to renew" |
| `.expired` | `.trial` | the trial is over: buy ([Buying from the app](#buying-from-the-app)) |
| `.invalid` | `.revoked` | the key was revoked or has expired, or this device was released |
| `.invalid` | `.upgrade` | this build is newer than the key covers: buy an upgrade (`upgradeURL`). From a licence file, newer than the file covers: a file (or a key) for this version |
| `.invalid` | `.outdated` | this build is older than the key (or the file) covers: update the app |
| `.invalid` | `.device` | the licence was activated on another device: activate again here |
| `.invalid` | `.tampered` | the lease is not for this licence at all: activate again. From a licence file, the stored file is not one (the state file was edited): import it again, or remove it |
| `.invalid` | `.unknownKey` | the lease is signed by a key this build does not carry; online, the server renews it with the key it signs with now. When it stays so online: update the app. From a licence file, no renewal comes: update the app, or ask for the same licence's file signed again |
| `.invalid` | `.revokedFile` | the stored offline licence file is one this build lists as revoked (`source` `.file`) |
| `.unlicensed` | | nothing held: activate or start a trial |
| `.unknown` | `.storage` | the state file could not be read just now: keep running, ask again shortly; never show the activation screen for it |

`isStalled`: an earlier call on this `License` has not finished (a storage adapter stuck, say), so
the answer comes from what is stored, with no ask and no write. A restart clears it.

### Activation errors

`invalidKey` (no such key, or text that cannot be one), `limit` (on as many devices as it
allows), `revoked`, `upgrade`, `outdated`, `network` (try again), `invalidLease` (the server's
lease does not verify with the embedded key: a configuration error), the seven errors of a
user-locked key ([below](#user-locked-keys)), and `storage` (the state file could not be read or
saved: try again). The key is trimmed and upper-cased before it is sent, so a pasted key with a
newline, or one typed in lower case, works.

## Licence files: drag and drop

A licence can come as a file (`.kglicense`) the customer drops onto the app or opens from its licence
screen. A **key file** carries their key: importing it activates the key online, exactly as typing it
would. An **offline licence file** licenses the app with no network at all, for good, on machines that
never connect; it has no seat limit and cannot be revoked, so the only way to stop one that leaked is an
app update that lists its id (`LicenseConfig(..., revokedLicenseFiles: ["lf_8Hq2"])`).

```swift
import SwiftUI
import UniformTypeIdentifiers
import KeyGrant

let licenseFileType = UTType(filenameExtension: String(licenseFileExtension.dropFirst())) ?? .data

struct LicenseScreen: View {
    let license: License
    @State private var choosing = false
    @State private var message = ""

    var body: some View {
        VStack {
            Text(message)
            Button("Open license file...") { choosing = true }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [licenseFileType]) { result in
            if case .success(let url) = result { Task { await importFile(at: url) } }
        }
        // macOS 13 and later; on macOS 12, `.onDrop(of: [.fileURL], ...)` gives the same URL.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "kglicense" }) else { return false }
            Task { await importFile(at: url) }
            return true
        }
    }

    func importFile(at url: URL) async {
        // A file the app was handed from outside its sandbox: read it while access is granted.
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            // The content, never the path, and never more than a licence file can be: a larger one is
            // refused unread past its bound.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let content = try handle.read(upToCount: maxLicenseFileBytes + 1) ?? Data()
            switch try await license.importLicenseFile(content) {
            case .imported(_, let licensedTo): message = "Licensed to \(licensedTo.name ?? licensedTo.email ?? "you")"
            case .refused(let error): message = "This license file was not taken (\(error.rawValue))."
            case .notActivated(let error): message = "The key in this file did not activate (\(error.rawValue))."
            }
        } catch {
            // Unreadable, not saved, or a licence call still running: try again.
            message = "Try again."
        }
    }
}
```

`importLicenseFile(_:)` takes the file's content (`Data`, or a `String` for pasted text), never its path,
and verifies it offline: signed by a key of `publicJWK`, for this product, and, for an offline file,
covering this build's major. It answers `.imported(kind, licensedTo:)` (`kind` `.key` or `.offline`);
`.refused(LicenseFileError)` (`.malformed`, `.notALicenseFile`, `.badSignature`, `.unknownKey`,
`.wrongProduct`, `.revokedFile`, `.upgrade`, `.outdated`), nothing stored; or, for a key file whose key
did not activate, `.notActivated(LicenseError)`, what `activate(_:)` answers. It throws
`LicenseCallError.previousCallUnfinished` behind a call that has not finished, and the storage's error
when the state cannot be read or the file (or a key file's activation) cannot be saved. `.unknownKey`
means the file was signed by a key this build does not carry: a newer one, after the product rotated its
key, which an update of the app carries. A key file's notes print its key, which can be typed meanwhile.

An offline file is kept and checked again on every `status()`, which then answers `.licensed` with
`source` `.file`, the `key`, `licensedTo` and the file's `entitlements`, never asking the server,
`refresh()` included. Show "Licensed to Ada Lovelace" from `licensedTo`. A status from a file has no
seat to deactivate: offer `removeLicenseFile()` instead (`deactivate()` leaves the file alone). If the
device also holds a key, a file that covers this build wins, and the key keeps working once the file is
removed, revoked or outgrown. A file that does not cover this build answers only when no key and no
running trial does.

**Keep every key that signed a file in your builds.** A file names the key that signed it and never
expires, so a key that has signed one stays in the product's key set, and in `publicJWK`, after it stops
signing leases. A build without it reads such a file as `.invalid` / `.unknownKey`.

## User-locked keys

A licence model can let only the person a key was sold to activate a NEW device on it: the activation
names the address on the key and, for a key that mails a code to that address, the code too. Only a
new device is ever asked; `status()`, `refresh()`, a renewal, a seat the key already holds and
everything offline are as they were, so an app that is activated keeps running through a KeyGrant or
mail outage.

`activate(_:email:code:)` carries what the person typed (each is optional, and neither is ever stored):

```swift
switch await license.activate(key, email: emailField, code: codeField) {
case .activated:
    break
case .failed(.userEmailRequired), .failed(.userEmailMismatch):
    askForTheAddress()      // then activate again with it
case .failed(.userCodeRequired), .failed(.userCodeInvalid):
    askForTheCode()         // a code was just mailed to the address
case .failed(.tooManyCodes), .failed(.tooManyAttempts):
    askToTryLater()
case .failed(.tryAgain):
    askToRetry()            // nothing was activated
case .failed:
    showTheOtherErrors()
}
```

| `LicenseError` | Means | The app |
|---|---|---|
| `userEmailRequired` | the key is locked and no address came | ask for the address |
| `userEmailMismatch` | not the key's address (nothing is said of the real one) | ask again |
| `userCodeRequired` | the address was right and a code was just mailed to it | ask for the code |
| `userCodeInvalid` | the code is wrong, expired (10 minutes) or used, or the key's codes are void for the hour after five wrong ones | ask again, or activate with the address alone for a new code |
| `tooManyCodes` | three codes were mailed for the key this hour | wait, or use the code sent |
| `tooManyAttempts` | ten wrong addresses this hour, or the key's codes void | try again later |
| `tryAgain` | the code could not be mailed: nothing was activated | retry; the one error here that is nobody's mistake |

The address is trimmed (it is compared without regard to case) and a blank is none. The code has its
ends trimmed and its spaces dropped (`123 456` is `123456`), and must be exactly six ASCII digits. An
address longer than 254 UTF-16 units, or a code that is not six digits, answers `userEmailMismatch` or
`userCodeInvalid` at once, for any key, asking the server nothing and so costing the key none of its
wrong tries; the key is judged first, then the address, then the code. A key that is not locked ignores
both once they reach the server. `importLicenseFile(_:email:code:)` passes them on to a key file's key.
`deactivate()`, `refresh()` and `startTrial()` take neither.

## Restoring a licence without the key (App Store builds)

A build that may not take a typed licence key (an App Store build) restores a web buyer's licence by the
address the key was sold to. The product's **Key pickup** must be on. The app asks for a code, the customer
types the code that comes to that address, and the SDK activates the key that fits this build:

```swift
// 1. Mail a code to the address the key was sold to (the answer is the same whether or not the address holds a key).
let sent = await license.pickUp(email: emailField)

// 2. The customer types the code; restore.
switch await license.restoreByEmail(email: emailField, code: codeField) {
case .restored:
    break                                                    // licensed: read status()
case .failed(.pickup(let refusal)):
    switch refusal.error {
    case .wrongCode: askAgain()
    case .codeExpired: _ = await license.pickUp(email: emailField)   // a new code
    case .tooManyAttempts, .tryAgain: waitSeconds(refusal.retryAfter)
    default: showTheError()
    }
case .failed(.noKey):
    showNoKeyUnderThatAddress()
case .failed(.license(.upgrade)):
    offerAnUpgrade()                                         // the keys are for an older major
case .failed(.license(.outdated)):
    askToUpdateTheApp()                                      // the keys start at a later major
case .failed(.license):
    showTheOtherErrors()                                     // activate's own, e.g. .limit
}
```

`pickUp(email:code:)` hands back the address's keys instead (`PickUpKeysResult.pickedKeys`: show them by
`modelName`, never the key) for an app that lets the customer choose; activate one with
`activate(picked.key, email: address, code: picked.activationCode)`. `restoreByEmail` chooses for the
customer, among the keys that cover this build's major: the key this device already holds a seat on, else one
with a free seat, else the first.

| `PickupError` | Means | The app |
|---|---|---|
| `invalidEmail` | the address is blank or longer than any | ask again |
| `wrongCode` | not six digits, or not the address's live code | ask again |
| `codeExpired` | no live code (expired after 10 minutes, used, burnt by its fifth wrong try, or never asked for) | `pickUp(email:)` again |
| `tooManyAttempts` | thirty wrong codes for the address this hour, or too many asks or confirms from this network | wait `retryAfter` seconds |
| `pickupDisabled` | the product's Key pickup is off | offer another way (support) |
| `tryAgain` | a count could not be made | retry |
| `network` | no answer, or an answer that is not a pickup's | retry |

A restore's refusal is a `RestoreError`: `.pickup` (the code was not taken), `.noKey` (the address holds no
key of the product) or `.license` with a `LicenseError`: `.upgrade` (the keys are for an older major than this
build) or `.outdated` (their lowest version is newer), activating nothing; then `activate`'s own errors
(`.limit`, `.revoked`, ...) as they come, and `.network` behind a call that has not finished. The address and the
code are prepared as an activation's are (trimmed, a code's spaces dropped) and refused at once, asking
nothing, when the address is blank or the code is not six digits, so a mistyped code costs the address none of
its wrong tries. `retryAfter` is read from the server's answer. The first confirm spends the code, so the keys it
answered are kept in memory for 10 minutes (a code's life) by the address and code as sent: a confirm or a
restore with the same pair answers from them and asks nothing, so a restore whose activation got no answer can
be retried with the same code, and a restore after `pickUp(email:code:)` needs no new one. A restore that
activates drops them. Nothing about a pickup is stored (not the address, the code, the keys or a refusal): the
two `pickUp` calls write nothing and run beside any call, and `restoreByEmail` stores only the activation, as
`activate` does, and runs one at a time with it. A pickup never takes a licence away. The rules are in the SDK
contract's section on key pickup, which the conformance vectors `pickupAsks`, `pickupRefusals`, `pickedKeys`
and `pickupChoices` hold this package to.

## Buying from the app

Give a customer who holds no key a Buy button that opens your Stripe Payment Link. The checkout
emails them their key, and they type it into the app. Add to the quick start's `Licensing`:

```swift
/// The product's payment link, from the dashboard.
private let paymentLink = URL(string: "https://buy.stripe.com/test_abc")!

/// "Buy" on the trial or activation screen; then the customer enters the key from the email
/// (`activate(_:)`).
func buy() {
    NSWorkspace.shared.open(paymentLink)
}
```

On iPhone and iPad, and in a Mac Catalyst app (which has UIKit, not AppKit),
`UIApplication.shared.open(paymentLink)` opens it, where the App Store's rules let an app link to a
purchase made outside it; a build that may not restores a web buyer's licence by
[key pickup](#restoring-a-licence-without-the-key-app-store-builds) instead.

For a customer who already holds a key, `upgradeURL(paymentLink:)` adds this install's activation to
the link, so an upgrade sale finds the key it upgrades.

Selling through Paddle? Pass your own checkout page's address instead of a payment link: the page reads `client_reference_id` from its address and gives it to Paddle.js as custom data (`customData: { client_reference_id }`), which is where KeyGrant reads it. KeyGrant's docs page "Selling through Paddle" has the page.

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
validate reports the ids of the keys the build carries (`kids`), so the dashboard can
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
  same UUID the Electron SDK reads, so a Mac has the same fingerprint under either SDK. A Mac
  Catalyst app reads it too: it runs on a Mac, and in everything the SDK decides (its
  fingerprint, its state file, its defaults) it is a Mac app. A native Mac build and a Catalyst
  build of one product on one Mac are one device: one seat and one trial, so releasing the seat
  from either releases it for both. An iOS app running unmodified on a Mac ("Designed for iPad")
  is an iOS app, identified by its install id.
- **iOS and iPadOS:** an app may read no id of the device, so the SDK keeps an install id of its
  own in the Keychain (service `dev.keygrant.install`, account the product slug), written at the
  first launch from `identifierForVendor`. It is kept on this device only: neither iCloud Keychain
  nor a backup restored onto another device carries it. It survives the app being deleted and
  installed again, so a reinstall is the same device and takes no second seat.
- **Linux:** `/etc/machine-id`, else `/var/lib/dbus/machine-id`; an id on a filesystem in memory
  (tmpfs, ramfs) or written at this boot counts as none.

A Mac or Linux machine with no id falls back to its host name; an iPhone or iPad, which has no host
name worth the name, never does. A device is never refused because a read was slow: a read that does
not finish in time means "cannot tell", and nothing is judged. The id is read once per process,
whatever number of `License`s it has (once per product on iOS and iPadOS).

`deviceHold: false` is for non-persistent pooled VDI, where every session may be another
machine: no lease is then judged by its device and the server is told no fingerprints (the device
limit still counts seats). A custom `Fingerprinter` that only implements `get()` is never held to
its device; implement `identify(timeout:)` and report `kind: .machine` for a stable machine id. One
that wraps the default makes it with `DefaultFingerprinter(product:)` (on iOS and iPadOS,
`DefaultFingerprinter()` is unavailable: the install id is the product's).

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
  activation, a renewal or a `refresh()`, and behind a call that has not finished) or from a
  stored offline licence file (its `ent`), and on a `.trial` status, from the trial's lease, when
  that lease or file grants at least one.
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
canonical equivalence, as above). It is answered offline from the stored lease or stored offline
licence file only, as `status()` would answer from what is stored, with no request and no write: a
licence that does not license this build, or none at all, grants nothing; a running trial grants
what its trial lease does.
`require(_:)` throws `MissingEntitlement`, naming the code, when `has(_:)` would be false.
`grants(status.entitlements, code)` answers the same of a status already in hand.

## Metered uses: counting what a key may do

A licence model can count uses of what it sells: 1,000 exports for good, or 50 renders each billing
period. The app spends them with `use(_:_:)`, before the work they count, and does the work only when
the spend is `ok`:

```swift
let spent = await license.use("exports")  // use("exports", 40) spends forty at once, whole or none
if spent.ok {
    runExport()  // spent.left: what is left now, net of this device's unsynced spends
} else {
    switch spent.error {
    case .usedUp?:
        offerMoreExports(left: spent.left)  // the server's word: fewer left than asked (nil when it gave no number)
    case .offlineLimit?:
        askToConnect()  // KeyGrant could not be reached, and this is past what this device may spend without it
    default:
        showMeterProblem(spent.error)  // .noMeter, .notLicensed, .revoked, .device, .upgrade, .outdated, .storage, .invalidAmount
    }
}

let status = await license.status()  // offline, from the lease
status.meters["exports"]  // MeterStatus(left: 950, total: 1000, offline: 100, unsynced: 0, resets: false)
```

- **Online it is exact.** The server takes `n` only while the meter has room for all of it. Two calls are
  two spends; the SDK's own retries and reports never count one twice.
- **With no answer it spends from an allowance.** No network, a timeout, a 5xx, a 429 or an answer the SDK
  cannot use: the device spends from its offline allowance for that meter (set on the licence model; a
  tenth of the meter by default, 0 for online only), never past what it last heard is left, answers
  `offline: true`, and reports the spend with its next request. Past either, `.offlineLimit`. A spend the
  allowance would refuse asks the server first, whatever the last outage left behind, so a customer who is
  back online is not refused for it (once a minute while KeyGrant stays out of reach); one the allowance
  covers is not asked again for a minute after an outage, growing to an hour. The unsynced spends are kept
  with the licence (`StoredState.spends`), so they survive a restart and a second instance of the app, and
  a spend the SDK cannot save yet is kept in memory: the customer always gets the use they were told they
  had, and it is reported once it has been saved. A `status()` on a valid lease reports the journal too,
  once its own wait is over, so a device back online gives its allowance back.
- **It needs a key's lease** that licenses this build on this device (`.notLicensed` otherwise, without
  asking). A device trial and an offline licence file have no meters.
- **`deactivate()` clears the unsynced spends with the licence.** It sends them with the release (and the
  device's fingerprints, so the server holds them to the seat's device), but clears them locally even when
  KeyGrant could not be reached (`released` is then false), so what the server did not hear is lost: at
  most the offline allowance of each meter. Activating another seat drops the old seat's spends unreported
  the same way.
- **It never throws for an outcome**: every one is in the `UseResult`, behind a call that has not finished
  too (nothing is then saved: an offline spend is kept in memory and saved by the next call that can), and
  a state that cannot be read just now is `.storage`. A `use` request waits at most 5 seconds for the server
  (less when `httpTimeout` is shorter). Calls on one `License` run one at a time, this one among them, and a
  call whose task is cancelled still runs to its bounded answer, as every call does: a spend that was made
  is the customer's, so read the result even from a task you cancelled.
- **`n` is an `Int`**: anything outside 1 to `maxMeterUses` (1,000,000,000) is `.invalidAmount`, and a meter
  code that is not 1 to 32 UTF-16 units is `.noMeter`, both without asking anything. A code is matched
  exactly, case included, as an entitlement's is (see the note on dictionary keys under
  [Entitlements](#entitlements)).
- **`status.meters`** is there on a `.licensed` status from a key's lease that names meters, and empty on
  every other status: `left` is net of this device's unsynced spends, `total` is what the key holds (for
  good, or this period), `offline` is this device's allowance, `unsynced` what it has spent and not reported,
  and `resets` is true for a meter that comes back each billing period.
- **A meter never takes the licence away.** Nothing reads one to decide whether the app is licensed: a meter
  that is used up refuses spends, never the app.
- An app built with an SDK from before meters licenses a metered key as any other and cannot spend.

## Where the state is kept

One JSON file per product, per user, on this machine:

- **macOS:** `~/Library/Application Support/KeyGrant/<product>.json`. In a **sandboxed** app the
  home folder is the app's container, so the file is
  `~/Library/Containers/<bundle id>/Data/Library/Application Support/KeyGrant/<product>.json`.
  That is fine: it is still per user and machine-local. (A non-sandboxed Mac app uses the same
  path the Electron SDK does, so an app moving from Electron to Swift keeps its licence; a
  sandboxed one cannot see that file.)
- **iOS and iPadOS:** the same path, in the app's container:
  `Library/Application Support/KeyGrant/<product>.json`.
- **Linux:** `$XDG_CONFIG_HOME/keygrant/<product>.json`, else `~/.config/keygrant/<product>.json`.

The home folder is `$HOME` as the process has it when the `License` is made, else the user's
home folder; on iOS and iPadOS it is always the app's container (`NSHomeDirectory()`, the
container in the Simulator too). The file has the same field names as every KeyGrant SDK's, so it is portable between
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
reads, merges and writes). Encode `StoredState` with `JSONEncoder`/`JSONDecoder`. The journal of unsynced
[metered](#metered-uses-counting-what-a-key-may-do) spends (`spends`) and the newest figures a spend was
answered with (`meterFigures`) are fields of it: a storage that keeps the whole state keeps them, one that
drops a field loses the report of what that field held.

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

To make a reinstall unable to restart a trial, give a registry stash that outlives the app (on iOS
and iPadOS it is the default, kept on this device only):

```swift
adapters: LicenseAdapters(registry: KeychainTrialStash(product: "sluice"))
```

`KeychainTrialStash` keeps the start in a generic-password Keychain item, which survives the app
being deleted. By default it uses the data protection keychain, which never prompts but needs an
app with an application identifier (any App Store app, or one with a provisioning profile);
`keychain: .login` works for any native Mac app but may prompt when a differently signed build (an
ad-hoc development build) reads the item. A Mac Catalyst app has only the data protection keychain,
whichever you pass, so there the stash needs an application identifier, and without one it stores
nothing. It writes only on what it read: it adds the item when there is none, replaces it only
with an earlier start, and leaves alone an item it cannot read (a locked keychain), whose start
nobody could see. A stash that cannot be read or written costs
nothing: the trial falls back on the server's record and the state file.

## iPhone and iPad

The API is the same on iOS and iPadOS 15 and later. The same app built for the Mac with Mac
Catalyst is a Mac to the SDK: who the device is, the state file and trials below are a Mac's for
it, and the selling and privacy manifest notes apply to it as to an iPad. What
differs on iPhone and iPad:

- **Who the device is:** an install id the SDK keeps in the Keychain
  ([Holding a licence to its device](#holding-a-licence-to-its-device)), never a host name. When it
  cannot be read (the Keychain is shut until the first unlock after the device restarts), the run
  cannot tell who it is: a valid lease keeps the app licensed, and an activation answers `network`,
  to try again once the device is unlocked.
- **The state file** is in the app's container ([Where the state is kept](#where-the-state-is-kept))
  and goes into the device's backups. Restored onto another iPhone, it names a seat held to the old
  one: `status()` answers `.invalid`/`.device`, and the customer activates again there (with the key,
  or by key pickup). The old seat is released from the customer portal or the dashboard. Before the
  first unlock after a restart the file cannot be read either: `status()` answers
  `.unknown`/`.storage`, never `.unlicensed`.
- **Trials:** the Keychain stash is the default ([Trials and the Keychain](#trials-and-the-keychain)).
- **App extensions:** a widget, share or intents extension is a process of its own, with a
  Keychain of its own: a `License` made there reads an install id of its own and takes a seat of
  its own. Check the licence in the app and hand the answer to its extensions (through an app
  group, say).
- **Selling:** an App Store build that may not take a typed licence key restores a web buyer's
  licence by [key pickup](#restoring-a-licence-without-the-key-app-store-builds).
- **The privacy manifest:** the package ships `PrivacyInfo.xcprivacy`, which Xcode puts in the
  app's privacy report: no tracking; a device id, an email address when the app passes one (a
  user-locked key, key pickup), and product interaction (a running trial's daily launch report,
  for the trial figures; metered uses spent), sent for the app's licensing and linked to the
  licence; and the reasons it reads file dates (its own state files, C617.1) and the time since the
  device started (its time bounds, 35F9.1). A `deviceName` the app passes is the app's to declare,
  and your App Store privacy answers cover what your app sends as a whole.

## Networking and the App Sandbox

The default HTTP adapter is `URLSession` (an ephemeral session: no cookies, no cache). A
**sandboxed** app needs the outgoing-connections entitlement (`com.apple.security.network.client`,
"Outgoing Connections (Client)" in Xcode). Without it every request fails: a valid lease keeps the
app licensed offline, but activation answers `network`.

## Concurrency

`License` is a `Sendable` final class: create one and share it. Calls on one `License` run one at a
time, so `status()` from several places at once asks the server once and never writes back a stale
state. A call waits for the one before it, but at most that call's HTTP bound plus 15 seconds;
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
the reference SDK, and replay the metered-uses and key-pickup groups among them. Beside them, a seeded property
test runs 1,500 sequences of spends, check-ins and releases from two processes of the app over one
state file, against a server whose answers are lost, late, refused or lost after it recorded the
spend, with a disk that refuses its writes and a clock that jumps (`PROPERTY_RUNS` and
`PROPERTY_SEED` choose how many and from which seed). The edges of the SDK's own time bounds are tested on a clock the test moves by
hand, not raced against a real one. Every suite has a time limit of a minute (on Linux, and on
macOS 13 or later: Swift Testing keeps none on macOS 12); since a limit ends only what heeds
cancellation, the tests' own waits on the SDK also fail after 20 seconds of real time rather than
hang.

The tests run on macOS and Linux. The iOS rules are tested there on stand-ins for the Keychain; the
code that calls the Keychain and UIKit itself compiles only for iOS:

```sh
xcodebuild build -scheme KeyGrant -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

On a Mac, the suite also runs as a Mac Catalyst test process (not in a sandboxed app):

```sh
xcodebuild test -scheme KeyGrant -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGN_IDENTITY=-
```

## Parity with the reference

Every group of the conformance vectors is reproduced, every answer, but for two kinds of vector: the
Windows cases of `machineIds`, which pin `reg.exe` output parsing (this SDK has no Windows reader),
and the `majors` with a fraction (marked `jsOnly`), which the reference's JavaScript number can hold
and `LicenseConfig.major` (an `Int`) cannot; a major below zero is reproduced (it runs as 1). Of the
metered-uses groups, the two `useAmounts` vectors that give `use` a fraction and a text (marked `jsOnly`)
are not replayed: an `Int` holds neither. The
decisions the vectors pin are the functions the SDK itself calls (`renewalOutcome`,
`asksOnValidLease`, `deviceFrom`, `identityOf`, `savedLastSeen`, `referencedLink`, and for licence
files `licenseFileToken`, `verifyLicenseFile`, `checkLicenseFile` and `licenseFileStatus`, and for a
user-locked key `typedFor`, and for a key pickup `pickupAsk`, `pickupRefusal`, `pickedKeysOf` and `chosenKey`, among them), and answers are compared exactly: text unit for unit, and in a patch a field cleared (`null`)
apart from one left alone (absent). Where this SDK differs from the reference Electron SDK, and why:

- **`activate(_:)` never throws.** When the state file cannot be read or saved, the reference
  rejects; this answers `.failed(.storage)` (a `LicenseError` case the reference does not have),
  so the app can say what is wrong and retry. `deactivate()` throws, as the reference's rejects,
  and answers `DeactivateResult` (`released`) as the reference's answers `{released}`; its
  result may be discarded.
- **`activate(_:email:code:)` and `importLicenseFile(_:email:code:)`** take the address and code as
  two labelled parameters that default to nil, where the reference takes an options object; a code is
  text here, where the reference also reads a code kept as a number.
- **`pickUp(email:)`, `pickUp(email:code:)` and `restoreByEmail(email:code:)`** are the reference's `pickUp(email)`,
  `pickUp(email, code)` and `restoreByEmail(email, code)`, as labelled methods. A pickup's refusal is a
  `PickupRefusal` (the `PickupError` and `retryAfter`) where the reference resolves `{ ok: false, error, retryAfter? }`,
  and a restore's a `RestoreError` (`.pickup`, `.noKey` or `.license`) where the reference's one `error` holds any of
  the words. None throws; a restore whose state cannot be read or saved answers `.license(.storage)`, as `activate` does.
- **`importLicenseFile(_:)`** answers a refusal as `.refused` and a key file's failed activation as
  `.notActivated`, where the reference resolves `{ ok: false, error }` with either word, and throws
  where the reference rejects. A stored `licenseFile` that is not text is no file here (a field of the
  wrong type is left out, as every field is), where the reference reads it as `.invalid`/`.tampered`:
  either way it licenses nothing.
- **`upgradeURL(paymentLink:)`** takes a `URL` and answers nil when the state cannot be read just
  now, or the link is not an absolute URL (the reference rejects both). The link is built by the
  reference's rule (`referencedLink`), but from the link as `URL` holds it: the reference's URL
  parser writes a link in its normal form first (a lower-case scheme and host, a `/` for an empty
  path), which this SDK leaves as given.
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
  then; so is `meters`, which is empty when a lease names none). `trialEndDate` is added.
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
  `JSON.stringify` writes it (a licence file's payload as a lease's is), but for what a Swift value
  cannot hold: an escaped lone surrogate
  (`"\ud800"`) reads as U+FFFD; two member names that are only canonically equivalent (an "é"
  composed and one decomposed) are one member, with the last value (an entitlement's name never
  meets this: KeyGrant signs names only in NFC); nesting deeper than 1,000
  levels does not parse (a Swift value that deep is released recursively, and a macOS thread's
  512 KB stack holds about 2,000 levels of that); and members are written sorted, not in the
  order they were added. `LicenseJSON`'s `Codable` conformance goes through Foundation's coders,
  with their limits; the SDK itself does not use it.
- **A call is never cut short by cancellation.** The reference has no cancellation; here each call
  runs in its own task, so a cancelled caller still gets (and saves) its answer within the bounds.
  That holds for `use(_:_:)` too: a spend whose caller was cancelled is made as it would have been, and
  its result should be read.
- **`use(_:_:)`** takes `n` as an `Int` (the reference's JavaScript number may also be a fraction or a
  text, which are `invalid-amount` there), answers a `UseResult` with `ok`, `left`, `offline` and
  `error` (a `UseError` whose raw values are the reference's words) where the reference resolves
  `{ ok, left?, offline?, error? }`, and never throws. A stored journal entry or figure of another
  shape is dropped when the state is read, and the next save writes the state without it (the
  reference drops it only when a change to the journal lands, and keeps a valid entry's unknown
  members). A figure out of a double's range (`1e400`) reads as infinity and drops its meter, in a
  lease and in an answer, as it does in the reference. Meter codes, like entitlement names, are
  dictionary keys, compared by canonical equivalence.
- **The default HTTP adapter bounds the whole request** itself (`URLRequest.timeoutInterval` is an
  idle timeout, and Linux's `URLSession` does not keep even that). The product slug is
  percent-encoded in the path (no change for a slug).
- **`KeychainTrialStash`** (the Apple analogue of the Windows registry stash an Electron app
  injects) only ever moves the stashed start earlier, and writes nothing over an item it cannot
  read.
- **iOS and iPadOS** have no reference (Electron runs on neither): the SDK follows the SDK
  contract's rules for phones and tablets, which the Dart SDK's Flutter plugin follows on iOS too
  (the same Keychain items, the same `machine-id|ios:<id>` fingerprint). They have no conformance
  vectors; this package's suite pins them.
- **Strings are compared unit for unit**, as JavaScript's `===` does, not by Swift's canonical
  equivalence, so a key, product or activation id matches exactly when the reference's would, and
  an `Entitlement` text equals another exactly when the reference's would.
