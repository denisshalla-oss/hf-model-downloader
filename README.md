# HF Model Downloader

Interactive + web-GUI downloader for [Hugging Face](https://huggingface.co) models with resume, SHA256 verification, and ComfyUI-aware folder layout.

[![CI](https://github.com/your-username/hf-model-downloader/actions/badge.svg)](https://github.com/your-username/hf-model-downloader/actions)

## Features

- **Two interfaces** — a friendly interactive CLI, or a local web GUI (zero dependencies)
- **File picker** — lists every downloadable file in the repo with sizes and categories; select by number, name, range (`1-3`), or `all`
- **Resume** — interrupted downloads keep a `.part` file and continue exactly where they stopped
- **SHA256 verification** — automatically uses the repo's `SHA256SUMS` when one exists (verify on download *and* verify-before-skip on re-runs)
- **Smart skips** — complete files are skipped on re-runs; corrupt ones are detected
- **Parallel downloads** — `--jobs N` (1–8)
- **Gated/private repos** — pass a token with `--token` or the GUI token field (never stored on disk)
- **Stale-part detection** — clear hint when a saved `.part` no longer matches the remote file (HTTP 416)
- **Layouts** — preserve repo structure, flat, or ComfyUI folders (`models/diffusion_models`, `text_encoders`, `vae`)

## Requirements

- `bash` ≥ 4.4 (macOS: `brew install bash`), `curl`
- `python3` (only for the web GUI)
- `aria2c` (optional — used automatically when present, with curl fallback)

## CLI usage

```bash
# interactive
./hf-model-download.sh https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF

# non-interactive: files 1 and 2, into ~/Downloads, parallel
./hf-model-download.sh <repo-url> -f 1,2 -o ~/Downloads/model -j 2 -y

# private/gated repo
./hf-model-download.sh <repo-url> --token hf_xxx -y

# machine-readable file list (used by the GUI)
./hf-model-download.sh --list-json <repo-url>
```

Run `./hf-model-download.sh --help` for all options.

## Web GUI

```bash
./hf-model-download-gui.sh            # opens http://127.0.0.1:8791
./hf-model-download-gui.sh --port 9000 --no-browser
```

The GUI is a single-page app served from **127.0.0.1 only** (never exposed to your network). It streams live download output into the page and supports cancel + resume.

### Desktop icon (Linux)

```bash
cp "HF Model Downloader.desktop" ~/Desktop/
chmod +x ~/Desktop/"HF Model Downloader.desktop"
```

Then right-click the icon → *Allow Launching* (GNOME) or trust it via your desktop environment. The `Exec` line in the `.desktop` file contains this machine's install path — edit it if you install elsewhere.

## Project layout

```
hf-model-download.sh        # the downloader (CLI)
hf-model-download-gui.py    # web GUI server (Python stdlib only)
hf-model-download-gui.sh    # GUI launcher
HF Model Downloader.desktop # desktop icon
.github/workflows/ci.yml    # CI: bash syntax + ShellCheck + python compile
```

## Security notes

- No credentials are written to disk or logs; tokens are passed in-memory only.
- The GUI binds to localhost and accepts no external connections.
- Downloaded files are verified against SHA256SUMS when the repo provides one, and `.gguf` files are checked for the GGUF magic bytes.

## License

MIT — see [LICENSE](LICENSE).
