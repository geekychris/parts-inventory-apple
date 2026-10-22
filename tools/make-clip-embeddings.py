# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = ["coremltools>=8", "numpy", "pillow", "huggingface_hub", "tokenizers"]
# ///
"""Build the zero-shot text embeddings for the app's "what part is this?" feature.

Uses Apple's MobileCLIP Core ML encoders (Hugging Face: apple/coreml-mobileclip).
The text encoder runs here, once, on macOS; only the image encoder ships in the app.

  uv run tools/make-clip-embeddings.py --download-dir /some/empty/dir
      # writes PartsKit/Sources/PartsKit/Resources/clip-text-embeddings.json
      # and copies the image encoder to App/Resources/MobileCLIPImage.mlpackage
  uv run tools/make-clip-embeddings.py --download-dir DIR --no-copy --validate a.jpg b.jpg
      # also prints the top 3 kinds per photo

Rerun whenever tools/clip-labels.json changes. Image and text encoders must be the
same variant (--variant), or the embeddings are meaningless.

Image encoder input (what the Swift side must feed it): "image", 256x256 RGB image
(CVPixelBuffer, 32BGRA/ARGB), centre-cropped to a square then resized; the model
scales pixels by 1/255 itself and applies no mean/std. Output "final_emb_1",
Float32 [1, 512], NOT normalised: L2-normalise it, dot with each label vector,
multiply by logitScale, softmax.
"""

import argparse
import json
import shutil
from pathlib import Path

import numpy as np

REPO = "apple/coreml-mobileclip"
REVISION = "3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947"  # 2024-11-19
TOKENIZER_REPO = "openai/clip-vit-base-patch32"  # same CLIP BPE vocab MobileCLIP uses
CONTEXT = 77
SOT, EOT = 49406, 49407
LOGIT_SCALE = 100.0  # MobileCLIP's learned scale is clamped at 100

ROOT = Path(__file__).resolve().parent.parent


def download(variant: str, dest: Path) -> Path:
    from huggingface_hub import hf_hub_download, snapshot_download

    snapshot_download(REPO, revision=REVISION, local_dir=dest,
                      allow_patterns=[f"mobileclip_{variant}_image.mlpackage/*",
                                      f"mobileclip_{variant}_text.mlpackage/*"])
    hf_hub_download(TOKENIZER_REPO, "tokenizer.json", local_dir=dest / "tokenizer")
    return dest


def tokenizer(dest: Path):
    from tokenizers import Tokenizer

    tok = Tokenizer.from_file(str(dest / "tokenizer" / "tokenizer.json"))
    tok.no_padding()
    tok.no_truncation()

    def encode(text: str) -> np.ndarray:
        ids = tok.encode(text).ids  # includes SOT ... EOT
        assert ids[0] == SOT and ids[-1] == EOT, ids
        if len(ids) > CONTEXT:
            ids = ids[: CONTEXT - 1] + [EOT]
        out = np.zeros((1, CONTEXT), dtype=np.int32)  # pad with 0, as open_clip does
        out[0, : len(ids)] = ids
        return out

    return encode


def l2(v: np.ndarray) -> np.ndarray:
    v = np.asarray(v, dtype=np.float64).reshape(-1)
    return v / np.linalg.norm(v)


def text_embeddings(variant: str, dest: Path, labels: dict) -> dict:
    import coremltools as ct

    model = ct.models.MLModel(str(dest / f"mobileclip_{variant}_text.mlpackage"),
                              compute_units=ct.ComputeUnit.CPU_ONLY)
    encode = tokenizer(dest)
    template = labels["template"]

    def embed(items):
        rows = []
        for it in items:
            prompt = template.replace("{}", it["label"])
            out = model.predict({"text": encode(prompt)})
            vec = l2(next(iter(out.values())))
            rows.append({"ref": it["ref"], "label": it["label"],
                         "vec": [round(float(x), 5) for x in vec]})
        return rows

    kinds = embed(labels["kinds"])
    return {
        "model": f"MobileCLIP-{variant.upper()} (apple/coreml-mobileclip)",
        "dim": len(kinds[0]["vec"]),
        "logitScale": LOGIT_SCALE,
        "template": template,
        "kinds": kinds,
        "boards": embed(labels.get("boards", [])),
    }


def preprocess(path: Path, size: int = 256):
    """Centre-crop to a square, resize to size x size (as Apple's demo app does)."""
    from PIL import Image, ImageOps

    im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    w, h = im.size
    s = min(w, h)
    im = im.crop(((w - s) // 2, (h - s) // 2, (w - s) // 2 + s, (h - s) // 2 + s))
    return im.resize((size, size), Image.Resampling.BICUBIC)


def validate(variant: str, dest: Path, emb: dict, photos: list[str], group: str = "kinds"):
    import coremltools as ct

    model = ct.models.MLModel(str(dest / f"mobileclip_{variant}_image.mlpackage"))
    names = [r["label"] for r in emb[group]]
    mat = np.array([r["vec"] for r in emb[group]])
    for p in photos:
        out = model.predict({"image": preprocess(Path(p))})
        v = l2(out["final_emb_1"])
        logits = emb["logitScale"] * (mat @ v)
        prob = np.exp(logits - logits.max())
        prob /= prob.sum()
        top = np.argsort(-prob)[:3]
        print(f"{Path(p).name:12s} " + " | ".join(f"{names[i]} {prob[i]*100:.0f}%" for i in top))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--variant", default="s2", choices=["s0", "s1", "s2", "blt"])
    ap.add_argument("--download-dir", required=True, type=Path,
                    help="where the Core ML models and tokenizer are (or get) downloaded")
    ap.add_argument("--labels", type=Path, default=ROOT / "tools/clip-labels.json")
    ap.add_argument("--out", type=Path,
                    default=ROOT / "PartsKit/Sources/PartsKit/Resources/clip-text-embeddings.json")
    ap.add_argument("--image-model-out", type=Path, default=ROOT / "App/Resources/MobileCLIPImage.mlpackage")
    ap.add_argument("--no-copy", action="store_true", help="don't copy the image encoder into the app")
    ap.add_argument("--validate", nargs="*", default=[], help="photos to classify (top 3 kinds)")
    a = ap.parse_args()

    dest = download(a.variant, a.download_dir)
    labels = json.loads(a.labels.read_text())
    emb = text_embeddings(a.variant, dest, labels)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(emb, separators=(",", ":")) + "\n")
    print(f"wrote {a.out} ({len(emb['kinds'])} kinds, {len(emb['boards'])} boards, dim {emb['dim']})")

    if not a.no_copy:
        src = dest / f"mobileclip_{a.variant}_image.mlpackage"
        if a.image_model_out.exists():
            shutil.rmtree(a.image_model_out)
        a.image_model_out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src, a.image_model_out)
        print(f"copied {src.name} -> {a.image_model_out}")

    if a.validate:
        validate(a.variant, dest, emb, a.validate)


if __name__ == "__main__":
    main()
