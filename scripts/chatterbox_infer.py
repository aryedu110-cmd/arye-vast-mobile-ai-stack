#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os

import torch
import torchaudio as ta
from chatterbox.mtl_tts import ChatterboxMultilingualTTS


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--text", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--language", default="he")
    parser.add_argument("--audio-prompt")
    parser.add_argument("--exaggeration", type=float, default=0.5)
    parser.add_argument("--cfg-weight", type=float, default=0.5)
    args = parser.parse_args()

    if not torch.cuda.is_available():
        raise RuntimeError("Chatterbox real mode requires an NVIDIA GPU")
    model = ChatterboxMultilingualTTS.from_pretrained(device="cuda")
    kwargs = {
        "language_id": args.language,
        "exaggeration": args.exaggeration,
        "cfg_weight": args.cfg_weight,
    }
    if args.audio_prompt:
        kwargs["audio_prompt_path"] = args.audio_prompt
    wav = model.generate(args.text, **kwargs)
    ta.save(args.output, wav, model.sr)


if __name__ == "__main__":
    main()
