# Shotsort — iPhone screenshot organizer

Sorts your iPhone screenshots into categories using [TypeSafe's Jev](https://docs.typesafe.ai) model.

## How it works

1. Reads screenshots from Photos (`mediaSubtype == photoScreenshot`).
2. Runs on-device OCR (Vision) on each one.
3. Sends the text to Jev as a single **Choice** question. The categories and their descriptions are the options.
4. Stores the category, confidence and probabilities in SwiftData, keyed by the Photos asset ID. A screenshot that's already sorted is never sent again.
5. Anything under the confidence threshold (50% by default) goes to the **Review** tab. Picking a category by hand marks it as yours, and Jev won't overwrite it.

If a request fails, it's retried once. After that the error is saved on the screenshot and its previous category is kept.

Optional: **Settings → Also send the image** attaches a 768px JPEG and switches to a vision model (`jev-preview` by default). This needs a key with image access.

## Features

- Category list with counts and previews, a grid per category, and an Unsorted bucket
- Detail view: change the category, see Jev's top probabilities and the OCR text, or ask Jev again
- Editable categories: Jev reads each category's description, so the wording matters
- Save categories as Photos albums (`Screenshots · <name>`)

## Setup

```sh
brew install xcodegen
xcodegen generate
open ScreenshotOrganizer.xcodeproj
```

Pick your team under Signing & Capabilities, then run it on your iPhone. You can use the simulator instead (`xcodebuild -downloadPlatform iOS`), but its library has no screenshots unless you add some.

When the app opens, go to **Settings** and paste your TypeSafe API key. It's stored in the device Keychain.

> The TypeSafe docs recommend keeping API keys on a server. A key typed into the Keychain is fine for a personal build. Before shipping to other people, put a small proxy in front of `/v1/systemone`.

## Layout

```
ScreenshotOrganizer/
  App.swift                 entry, Photos permission, category seeding
  Models/Models.swift       ScreenshotRecord, CategoryDef (+ default categories)
  Services/
    PhotoLibrary.swift      fetch screenshots, load images, save albums
    OCR.swift               Vision text recognition
    TypeSafeClient.swift    POST /v1/systemone, Choice question, response parsing
    Classifier.swift        sync library → SwiftData, classification loop
    Keychain.swift
  Views/                    Library, Review, Detail, Settings
```
