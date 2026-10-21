# Third-party notices

## Code included in this repository

**apple/ml-mobileclip** (`ScreenshotOrganizer/LocalModel/CLIPTokenizer.swift`, `GPT2ByteEncoder.swift`,
`ScreenshotOrganizer/Resources/clip-vocab.json`, `clip-merges.txt`). MIT License, Copyright © 2024 Apple Inc.
https://github.com/apple/ml-mobileclip/blob/main/LICENSE

These files are in turn adapted from **huggingface/swift-coreml-transformers** (Apache License 2.0).
https://github.com/huggingface/swift-coreml-transformers

The copied files were changed to load the vocabulary from URLs, drop the `Utils` dependency, and truncate input longer than 77 tokens.

## Models downloaded at runtime (not included in this repository)

**MobileCLIP-S0** Core ML encoders, downloaded by the app from https://huggingface.co/apple/coreml-mobileclip.

Apple Machine Learning Research Model is licensed under the Apple Machine Learning Research Model License Agreement.
https://github.com/apple/ml-mobileclip/blob/main/LICENSE_MODELS

That license limits use of the weights to non-commercial research. This repository's MIT license covers only the code here, not the model weights.
