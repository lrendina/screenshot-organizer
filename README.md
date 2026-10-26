# Shotsort — iPhone screenshot organizer

Sorts your iPhone screenshots into categories. Pick the model in Settings:

| | On-device (default) | Jev (bring your own key) |
|---|---|---|
| Model | Apple's open-weights [MobileCLIP-S0](https://huggingface.co/apple/coreml-mobileclip), Core ML | [TypeSafe Jev](https://docs.typesafe.ai) |
| Runs | On the iPhone | TypeSafe's API |
| Sends data | Nothing | The text read from each screenshot (optionally a 768px image) |
| Cost | Free, one-time 108 MB download | Your TypeSafe usage |
| Signal | Screenshot image + on-screen text | On-screen text (+ image with a vision model) |

## Install on your iPhone

App Store coming soon. In the meantime follow the instructions below

**You need:** a Mac with [Xcode](https://apps.apple.com/app/xcode/id497799835), [Homebrew](https://brew.sh), an iPhone with iOS 17 or later, and a cable.

1. **Get the code**
   ```sh
   git clone https://github.com/lrendina/screenshot-organizer.git
   cd screenshot-organizer
   brew install xcodegen
   ```
2. **Sign in to Xcode with your Apple ID** (free): open Xcode, go to **Xcode → Settings → Accounts → + → Apple ID**. This creates a free "Personal Team".
3. **Connect your iPhone:** plug it in, unlock it, and tap **Trust**. Then turn on **Settings → Privacy & Security → Developer Mode** (the phone restarts and asks you to confirm).
4. **Build and install:**
   ```sh
   SHOTSORT_BUNDLE_ID=com.yourname.shotsort Tools/install-device.sh
   ```
   Use any bundle ID unique to you; free accounts can't reuse someone else's. The script finds your team and phone, then builds, signs and installs.
5. **Trust the app (first time only):** on the phone, open **Settings → General → VPN & Device Management**, tap your Apple ID, then **Trust**.
6. **Open Shotsort**, allow access to **All Photos**, and tap **Get model** (108 MB download). Your screenshots start sorting.

**Every 7 days** a free-account app stops opening. Plug the phone in and run step 4 again; your sorted screenshots are kept. A paid developer account ($99/yr) extends this to a year.

**Prefer Xcode's UI?** Run `SHOTSORT_BUNDLE_ID=com.yourname.shotsort xcodegen generate`, then open `ScreenshotOrganizer.xcodeproj`. Pick your Personal Team under the target's **Signing & Capabilities**, choose your iPhone as the destination, and press ⌘R.

**No Mac?** `Tools/build-ipa.sh` (run on a Mac) produces an unsigned `build/Shotsort.ipa`. [AltStore](https://altstore.io), [SideStore](https://sidestore.io) or Sideloadly can install it with your own Apple ID and renew it every 7 days automatically.

**Troubleshooting**
- *"No Apple team found"*: do step 2.
- *"No iPhone connected"*: unlock the phone, tap Trust, and check that Developer Mode is on.
- *Build fails with a provisioning error*: your bundle ID is taken. Pick a different `SHOTSORT_BUNDLE_ID`.
- *"Untrusted Developer" when opening the app*: do step 5.
- *Free accounts are limited to 3 sideloaded apps per phone*: delete one you don't use.

## How it works

1. Reads screenshots from Photos: anything tagged `photoScreenshot`, plus images whose pixel size matches this device's screen (imported or saved screenshots often lose the tag).
2. **Reads text on-device** (Vision OCR) for every screenshot. This works with no model and no key, and powers **search**.
3. **Sorts** each unsorted screenshot:
   - **On-device:** MobileCLIP embeds three square crops down the screenshot (top/middle/bottom), blends in an embedding of the OCR text (30%), and compares that against two prompts per category built from its name and description. A softmax over the similarities gives probabilities. "Other" isn't scored, because CLIP has no good embedding for "none of these". It wins when no category reaches 30%.
   - **Jev:** one `choice` question over `/v1/systemone`. The criteria are your categories and their descriptions.
4. Stores the category, confidence and probabilities in SwiftData, keyed by the Photos asset ID. Sorted screenshots are never re-sent.
5. Anything under the confidence threshold goes to **Review**. A category you pick by hand is never overwritten.

Failures never wipe a category. A Jev request is retried once; 4xx errors aren't retried. A rejected key stops the whole batch instead of flagging every screenshot. The error is saved on the screenshot and its previous category is kept.

## Features

- Home: progress card, recent strip, category cards with a fan of the latest screenshots
- Search across all on-screen text, and category names
- Detail pager: swipe between screenshots, category chips, top-3 probability bars, OCR text, share, pinch-zoom full screen
- Review tab for low-confidence results
- Editable categories. Both models read the descriptions, so wording matters
- Auto-sort new screenshots when the app opens
- Save categories as Photos albums (`Screenshots · <name>`)

## Setup

```sh
brew install xcodegen
xcodegen generate
open ScreenshotOrganizer.xcodeproj
```

Run on a device (set your signing team) or a simulator. On first launch, tap **Get model** to download MobileCLIP (108 MB from Hugging Face; compiled on-device). To use Jev instead, go to **Settings → Jev (your key)** and paste your TypeSafe key. It's stored in the Keychain. Debug builds also read `TYPESAFE_API_KEY` from the launch environment (`SIMCTL_CHILD_TYPESAFE_API_KEY=… xcrun simctl launch booted com.lrendina.ScreenshotOrganizer`).

> TypeSafe's docs recommend keeping API keys on a server. A Keychain key is fine for a personal build. Before shipping BYOK to other people, consider a proxy.

## TestFlight

One-time setup:
1. Join the [Apple Developer Program](https://developer.apple.com/programs/enroll/) ($99/yr). Your Team ID is under Membership details.
2. In [App Store Connect](https://appstoreconnect.apple.com/apps), create the app: **+ → New App**, iOS, bundle ID `com.lrendina.ScreenshotOrganizer` (register it at developer.apple.com → Identifiers first if it isn't in the list), SKU `shotsort`. The name has to be unique on the App Store.
3. Create an API key: App Store Connect → Users and Access → Integrations → **App Store Connect API** → Team Keys → +, role **App Manager**. Download the `.p8` file (you can only download it once) and note the Key ID and Issuer ID.

Each build:
```sh
SHOTSORT_TEAM_ID=XXXXXXXXXX ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8 Tools/testflight.sh
```
This archives a Release build (the build number is a timestamp), signs it automatically, and uploads it. After processing, the build appears under TestFlight. Internal testers (people on your App Store Connect team, up to 100) can install it right away. External testers need a one-time Beta App Review.

To build from Xcode instead, run `SHOTSORT_TEAM_ID=XXXXXXXXXX xcodegen generate`, then use Product → Archive → Distribute App → TestFlight & App Store.

## Development

```sh
# Unit tests (parser, retry rules, crops, tokenizer)
xcodebuild test -project ScreenshotOrganizer.xcodeproj -scheme ScreenshotOrganizer -destination 'platform=iOS Simulator,name=iPhone 17'

# Seed a booted simulator with real screenshots of the mock pages + a few live sites
(cd DevFixtures/mocks && python3 -m http.server 3000 --bind 127.0.0.1 &) && DevFixtures/capture.sh

# Score the on-device model on the labeled fixtures (downloads the model once to ~/.cache)
Tools/eval-local-model.sh          # optional arg: OCR text weight, default 0.3
```

Current fixture result: 12/12 (`Tools/eval-local-model.sh`). Twelve screenshots is a smoke test, not an accuracy number.

## Layout

```
ScreenshotOrganizer/
  App.swift                   entry, Photos permission, category seeding, auto-sort
  Models/Models.swift         ScreenshotRecord, CategoryDef (+ default categories)
  Services/
    Classifier.swift          sync → OCR → sort (Engine: .local | .jev), bounded concurrency
    TypeSafeClient.swift      POST /v1/systemone, Choice question, response parsing
    PhotoLibrary.swift        fetch screenshots, load images, save albums
    OCR.swift, Keychain.swift
  LocalModel/
    MobileCLIP.swift          zero-shot classifier (crops, prompts, softmax, fallback)
    LocalModelStore.swift     download from Hugging Face, compile, cache
    CLIPTokenizer.swift, GPT2ByteEncoder.swift   vendored from apple/ml-mobileclip (MIT)
  Resources/                  CLIP BPE vocab + merges
  Views/                      Library, Review, Detail pager, Settings
ScreenshotOrganizerTests/     unit tests
Tools/                        install-device, build-ipa, testflight, icon renderer, model eval
DevFixtures/                  mock pages, capture script, labeled screenshots
```

## Licenses

The app's code is MIT (see [LICENSE](LICENSE)); third-party code and models are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).


- Tokenizer code: `apple/ml-mobileclip` (MIT), adapted from Hugging Face `swift-coreml-transformers`.
- **MobileCLIP weights are research-only.** They're under the Apple Machine Learning Research Model License ([LICENSE_MODELS](https://github.com/apple/ml-mobileclip/blob/main/LICENSE_MODELS)), which allows "non-commercial scientific research" and excludes "use in any commercial product or service". They're downloaded at runtime, not bundled. Fine for experimenting and research; any release to users needs a model with a commercial-friendly license. `MobileCLIP.swift` is plain CLIP zero-shot code, so any CLIP-style Core ML image/text encoder pair with 512-d outputs can be dropped in.
