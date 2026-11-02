# Third-party notices

## Basic Pitch (Spotify)

`Sources/AnalysisEngine/Resources/BasicPitch/nmp.mlpackage` is the note-transcription model from
`basic-pitch` 0.4.0 (`basic_pitch/saved_models/icassp_2022/nmp.mlpackage`), redistributed unmodified.
Licensed under the Apache License 2.0; its LICENSE and NOTICE are bundled next to the model.
Copyright 2022 Spotify AB. Upstream: https://github.com/spotify/basic-pitch

## Demo audio

`Sources/RiffnexApp/Resources/Demo/riffnex-demo.m4a` is an original composition synthesized by
`tools/fixtures/make_demo.py` for RIFFNEX. It contains no third-party material.

## Demucs v4 (Meta AI)

`Sources/AnalysisEngine/Resources/Separation/htdemucs6s.mlpackage` is the `htdemucs_6s` source-separation
model from Demucs 4.0.1 (https://github.com/facebookresearch/demucs), converted to Core ML by
`tools/separation/convert_htdemucs.py` (network only; the STFT/iSTFT run in the app). Demucs code and
pretrained models are released under the MIT License, Copyright (c) Meta Platforms, Inc. and affiliates.
