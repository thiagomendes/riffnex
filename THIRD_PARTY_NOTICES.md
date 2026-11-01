# Third-party notices

## Basic Pitch (Spotify)

`Sources/AnalysisEngine/Resources/BasicPitch/nmp.mlpackage` is the Core ML model shipped by Spotify in
`basic-pitch` 0.4.0 (`basic_pitch/saved_models/icassp_2022/nmp.mlpackage`), redistributed unmodified.

`Sources/MusicCore/Transcription/NoteDecoder.swift` is a Swift port (derivative work) of `basic_pitch/note_creation.py` (`output_to_notes_polyphonic`, `get_infered_onsets`, `constrain_frequency`) from the same release, under the same Apache-2.0 license; the file states this. Golden vectors in `Tests/Fixtures` are outputs of the reference implementation on RIFFNEX's own demo song.

- License: Apache License 2.0. The full text and NOTICE are in `Sources/AnalysisEngine/Resources/BasicPitch/LICENSE.txt` and `NOTICE.txt`.
- Paper: Bittner et al., “A Lightweight Instrument-Agnostic Model for Polyphonic Note Transcription and Multipitch Estimation”, ICASSP 2022.
- Upstream: https://github.com/spotify/basic-pitch

## Demo audio

`Sources/RiffnexApp/Resources/Demo/riffnex-demo.m4a` is an original composition synthesized by
`tools/fixtures/make_demo.py` for RIFFNEX. It contains no third-party material.

## Demucs v4 (Meta AI)

`Sources/AnalysisEngine/Resources/Separation/htdemucs6s.mlpackage` is the `htdemucs_6s` source-separation
model from Demucs 4.0.1 (https://github.com/facebookresearch/demucs), converted to Core ML by
`tools/separation/convert_htdemucs.py` (network only; the STFT/iSTFT run in the app). Demucs code and
pretrained models are released under the MIT License, Copyright (c) Meta Platforms, Inc. and affiliates.
