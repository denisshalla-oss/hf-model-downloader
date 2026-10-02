# Contributing

Thanks for helping improve HF Model Downloader! This guide covers how to set up, test, commit, and release.

## Development setup

No build step — the project is two scripts and a stdlib-only Python file.

Requirements to develop/test locally:

- `bash` ≥ 4.4 (macOS: `brew install bash`)
- `curl`
- `python3` (for the GUI)
- optional: `aria2c` (to test that code path), `shellcheck`

## Run the project

```bash
# CLI — interactive
./hf-model-download.sh https://huggingface.co/hf-internal-testing/tiny-random-gpt2

# CLI — non-interactive (the contract the GUI relies on)
./hf-model-download.sh <repo> -o /tmp/test -f 1 -y --jobs 1

# GUI — opens http://127.0.0.1:8791
./hf-model-download-gui.sh --no-browser   # for testing; without --no-browser it opens a tab
```

Use a tiny public repo for tests (e.g. `hf-internal-testing/tiny-random-gpt2`) — files are under 10 MB.

## Test before you commit

There is no unit-test harness; CI enforces syntax and ShellCheck. At minimum:

```bash
bash -n hf-model-download.sh && bash -n hf-model-download-gui.sh
python3 -m py_compile hf-model-download-gui.py
shellcheck hf-model-download.sh          # if installed (CI runs it too, informational)
```

Then run the live checklist that matches your change:

- [ ] fresh download completes, file size matches the repo listing
- [ ] re-run skips complete files (`already downloaded and complete`)
- [ ] interrupt (Ctrl-C) mid-download, re-run resumes from the `.part`
- [ ] non-interactive mode (`-y`, stdin not a TTY) makes zero prompts
- [ ] `--list-json` prints **pure JSON on stdout** (the GUI parses it — no banners!)

## Code guidelines

- **Bash**: the script runs under `set -u`. Guard empty array expansions (`"${arr[@]+"${arr[@]}"}"` is unnecessary on bash ≥ 4.4, but never assume a variable is set). Keep it POSIX-friendly where cheap; GNU/BSD `stat` and `sha256sum`/`shasum` differences are handled in `stat_size()`/`SHA_CMD` — extend those helpers rather than hardcoding new ones.
- **Network**: every request to huggingface.co must send the shared `$UA` user agent, and auth must go through `AUTH_HDR`. 401/403 = auth problem, 404 = not found, 416 = stale `.part` — keep those semantics distinct (see `http_needs_auth()`).
- **GUI (Python)**: stdlib only. Keep it a single file. The GUI talks to the CLI exclusively through `--list-json` (read) and the non-interactive flag contract (write) — don't add a second protocol.
- **No secrets**: never commit tokens, `.env` files, or machine-specific paths in code. (The `.desktop` file intentionally contains the install path; keep it out of scripts.)

## Branching & commits

Branch naming:

```
feature/<short-topic>    e.g. feature/gui-progress-bar
bugfix/<short-topic>     e.g. bugfix/resume-416
```

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add --list-json machine-readable file listing
fix: resume from .part when remote size matches
docs: update GUI section of README
chore: bump CI actions
```

Rebase onto `main` before opening the PR; keep history linear (no merge commits on feature branches).

## Pull requests

1. Open the PR — the template checklist will appear.
2. Paste the relevant test-checklist results into *Testing*.
3. If behavior or usage changed, update `README.md` in the same PR.
4. CI must be green (shell + python jobs) before merge.

## Releasing (maintainers)

```bash
git tag -a v1.1.0 -m "v1.1.0 — <one line>"
git push origin v1.1.0

# build the artifact from the tag and publish
git archive --format=tar.gz --prefix=hf-model-downloader-1.1.0/ -o /tmp/hfdl-1.1.0.tar.gz v1.1.0
gh release create v1.1.0 --title "v1.1.0 — <one line>" --notes-file NOTES.md --verify-tag /tmp/hfdl-1.1.0.tar.gz
```

Bump versions semantically: `v1.1.0` for features, `v1.0.1` for fixes, `v2.0.0` for breaking CLI changes.
