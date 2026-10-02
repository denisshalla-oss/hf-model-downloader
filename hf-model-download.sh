#!/usr/bin/env bash
#
# hf-model-download.sh
# --------------------
# Interactive downloader for Hugging Face model repositories.
#
# Flow:  paste a repo link  ->  pick from a live list of quants/files  ->  pick a
#        folder  ->  download with resume  ->  verify SHA256.
#
# The file list is fetched from the Hugging Face API at runtime, so this works
# with any public (or token-accessible) HF repo, not just the one it was
# written for.
#
# Usage:
#   ./hf-model-download.sh                     # fully interactive
#   ./hf-model-download.sh <hf-repo-url>       # skip the link prompt
#   ./hf-model-download.sh <url> -o DIR -f 2   # non-interactive (still confirms)
#   ./hf-model-download.sh <url> -o DIR -f all -y --jobs 2   # fully unattended
#
# Options:
#   -o, --dir DIR        download directory (skips the folder prompt)
#   -f, --file SEL       selection, e.g. "2", "2,5", "1-3", "all" (skips menu)
#   -l, --list           list files and exit
#   -j, --jobs N         run up to N downloads in parallel (default 1)
#   -y, --yes            skip ALL prompts and confirmations (fully non-interactive)
#       --layout MODE    preserve | flat | comfyui
#       --token TOKEN    Hugging Face token (or set HF_TOKEN / HUGGING_FACE_HUB_TOKEN)
#       --no-verify      skip SHA256 verification
#       --list-json      print the file list as JSON (for tools/GUIs) and exit
#   -h, --help           show help
#

set -u

PROG="${0##*/}"
UA="${PROG}/2.0"

# Requires bash >= 4.4 (empty arrays under set -u, wait -n).
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]] || { [[ "${BASH_VERSINFO[0]:-0}" -eq 4 ]] && [[ "${BASH_VERSINFO[1]:-0}" -lt 4 ]]; }; then
  printf 'error: %s requires bash >= 4.4 (you have %s)\n' "$PROG" "${BASH_VERSION:-unknown}" >&2
  printf '  macOS users: run  brew install bash  and use /opt/homebrew/bin/bash\n' >&2
  exit 1
fi

# Colors, only when attached to a terminal.
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

die()  { printf '%s error: %s%s\n' "$C_RED$C_BOLD" "$*" "$C_RESET" >&2; exit 1; }
warn() { printf '%s warning: %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
info() { printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*"; }
ok()   { printf '%s  ok %s %s\n' "$C_GREEN" "$C_RESET" "$*"; }

cleanup() {
  [[ -n "${WORK:-}" && -d "${WORK:-}" ]] && rm -rf "$WORK"
  return 0
}
trap cleanup EXIT
trap 'printf "\n%s aborted by user%s\n" "$C_YELLOW" "$C_RESET"; exit 130' INT TERM

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------

ARG_URL=''
ARG_DIR=''
ARG_SEL=''
ARG_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
ARG_LAYOUT=''
ARG_JOBS=1
OPT_LIST=0
OPT_LIST_JSON=0
OPT_YES=0
OPT_VERIFY=1

# Options that take a value: fail fast instead of looping on a bare flag.
# need_value <flag> <value>
need_value() {
  if [[ -z "${2:-}" ]]; then
    die "option '$1' requires a value (try --help)"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--dir)     need_value "$1" "${2:-}"; ARG_DIR="$2"; shift 2 ;;
    -f|--file)    need_value "$1" "${2:-}"; ARG_SEL="$2"; shift 2 ;;
    -l|--list)    OPT_LIST=1; shift ;;
    -j|--jobs)    need_value "$1" "${2:-}"; ARG_JOBS="$2"; shift 2 ;;
    -y|--yes)     OPT_YES=1; shift ;;
    --layout)     need_value "$1" "${2:-}"; ARG_LAYOUT="$2"; shift 2 ;;
    --token)      need_value "$1" "${2:-}"; ARG_TOKEN="$2"; shift 2 ;;
    --no-verify)  OPT_VERIFY=0; shift ;;
    --list-json)  OPT_LIST_JSON=1; shift ;;
    -h|--help)    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
    -*)           die "unknown option: $1 (try --help)" ;;
    *)            ARG_URL="$1"; shift ;;
  esac
done

if [[ "$ARG_JOBS" =~ ^[1-9][0-9]*$ ]] || [[ "$ARG_JOBS" == "1" ]]; then :; else
  die "--jobs must be a positive integer"
fi
if [[ -n "$ARG_LAYOUT" ]]; then
  case "$ARG_LAYOUT" in
    preserve|flat|comfyui) ;;
    *) die "--layout must be one of: preserve, flat, comfyui" ;;
  esac
fi

# -y or a non-tty stdin means "zero prompts".
NONINTERACTIVE=0
if (( OPT_YES )) || ! [[ -t 0 ]]; then
  NONINTERACTIVE=1
fi

# Required tools (checksum tools only when verification is on).
for tool in curl python3; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' is not installed"
done

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# ask <varname> <prompt> [default] -- returns 1 on EOF (Ctrl-D).
# In non-interactive mode: uses the default if there is one, else returns 1.
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __val=''
  if (( NONINTERACTIVE )); then
    if [[ -n "$__default" ]]; then
      printf -v "$__var" '%s' "$__default"
      return 0
    fi
    return 1
  fi
  if [[ -n "$__default" ]]; then
    printf '%s [%s]: ' "$__prompt" "$__default" >&2
  else
    printf '%s: ' "$__prompt" >&2
  fi
  IFS= read -r __val || { printf '\n' >&2; return 1; }
  [[ -z "$__val" && -n "$__default" ]] && __val="$__default"
  printf -v "$__var" '%s' "$__val"
  return 0
}

# confirm_gate <message> -- proceed if -y, die in non-interactive mode without
# -y, otherwise ask (default no). Returns 1 when the user declines.
confirm_gate() {
  local ans
  if (( OPT_YES )); then
    return 0
  fi
  if (( NONINTERACTIVE )); then
    die "needs confirmation: $* (re-run with -y to allow it, or run interactively)"
  fi
  ask ans "$*? (y/N)" "n" || ans=n
  [[ "${ans,,}" == y* ]]
}

# Human-readable size from a byte count.
fmt_size() {
  local b="${1:-0}"
  python3 -c '
import sys
b = float(sys.argv[1] or 0)
for unit in ("B", "KB", "MB", "GB", "TB"):
    if b < 1000 or unit == "TB":
        print(f"{int(b)} B" if unit == "B" else f"{b:.2f} {unit}")
        break
    b /= 1000
' "$b"
}

# File size, GNU or BSD stat.
STAT_MODE=''
stat_size() {
  local f="$1"
  if [[ -z "$STAT_MODE" ]]; then
    if stat -c %s /dev/null >/dev/null 2>&1; then STAT_MODE=g; else STAT_MODE=b; fi
  fi
  if [[ "$STAT_MODE" == g ]]; then
    stat -c %s "$f"
  else
    stat -f %z "$f"
  fi
}

# sha256 of a file (empty output if no checksum tool is available).
SHA_CMD=()
if (( OPT_VERIFY )); then
  if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    SHA_CMD=(shasum -a 256)
  else
    die "verification needs sha256sum (or shasum) -- install one, or pass --no-verify"
  fi
fi
sha256_of() {
  if (( ${#SHA_CMD[@]} == 0 )); then return 1; fi
  "${SHA_CMD[@]}" "$1" 2>/dev/null | awk '{print $1}'
}

# Expand a leading ~ and make the path absolute.
expand_path() {
  local p="$1"
  case "$p" in
    '~')     p="$HOME" ;;
    '~/'*)   p="$HOME/${p#\~/}" ;;
  esac
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    *)  printf '%s\n' "$PWD/$p" ;;
  esac
}

# Extract "owner/name" from a Hugging Face URL or bare repo id.
parse_repo_id() {
  local raw="$1"
  raw="${raw%%\?*}"      # drop ?query
  raw="${raw%%#*}"       # drop #fragment
  raw="${raw%/}"         # drop trailing slash
  raw="${raw#http://}"
  raw="${raw#https://}"
  if [[ "$raw" == */* ]]; then
    local host="${raw%%/*}" rest="${raw#*/}"
    case "$host" in
      huggingface.co|www.huggingface.co|hf.co|huggingface.com)
        # strip leading segments that are not part of "owner/name"
        while [[ "$rest" == models/* || "$rest" == datasets/* || "$rest" == spaces/* ]]; do
          rest="${rest#*/}"
        done
        local owner="${rest%%/*}"
        [[ "$owner" == "$rest" ]] && return 1
        rest="${rest#*/}"
        local name="${rest%%/*}"
        [[ -z "$owner" || -z "$name" ]] && return 1
        printf '%s/%s\n' "$owner" "$name"
        return 0
        ;;
    esac
  fi
  # Bare "owner/name"
  if [[ "$raw" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    printf '%s\n' "$raw"
    return 0
  fi
  return 1
}

# HTTP status codes that mean "you need a token / it is not public".
# (404 is handled separately as "not found", not auth.)
http_needs_auth() { [[ "$1" == "401" || "$1" == "403" ]]; }

# ---------------------------------------------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hfdl.XXXXXX")" || die "cannot create temp dir"
API="$WORK/api.json"
TSV="$WORK/files.tsv"
SUMS="$WORK/sha256sums"

# ---------------------------------------------------------------------------
# step 1 -- the link
# ---------------------------------------------------------------------------

if (( ! OPT_LIST_JSON )); then
  printf '\n%s%s Hugging Face model downloader %s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  printf '%sPaste a repo link, choose a file, choose a folder. That is it.%s\n\n' "$C_DIM" "$C_RESET"
fi

REPO=''
if [[ -n "$ARG_URL" ]]; then
  REPO="$(parse_repo_id "$ARG_URL" || true)"
  [[ -z "$REPO" ]] && die "could not read a repo id from: $ARG_URL"
  (( OPT_LIST_JSON )) || info "repo: ${C_BOLD}${REPO}${C_RESET}"
else
  while :; do
    ask INPUT "Paste the Hugging Face link" || die "no repo link -- paste one, or pass the URL as the first argument"
    [[ -z "$INPUT" ]] && { warn "empty input, try again"; continue; }
    REPO="$(parse_repo_id "$INPUT" || true)"
    if [[ -z "$REPO" ]]; then
      warn "that does not look like a Hugging Face repo link."
      printf '%s    example: https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF%s\n' "$C_DIM" "$C_RESET" >&2
      continue
    fi
    break
  done
  info "repo: ${C_BOLD}${REPO}${C_RESET}"
fi

# ---------------------------------------------------------------------------
# step 2 -- fetch the file list
# ---------------------------------------------------------------------------

# Fetch the repo JSON from the HF API. Retries 429/5xx twice with backoff.
# Honors a token when provided. Prints an http code, or "network".
fetch_repo_json() {
  local repo="$1" out="$2" token="$3" url code attempt
  url="https://huggingface.co/api/models/${repo}?blobs=true"
  local -a hdr=(-H "User-Agent: $UA")
  [[ -n "$token" ]] && hdr+=(-H "Authorization: Bearer ${token}")

  for (( attempt = 1; attempt <= 3; attempt++ )); do
    code="$(curl -sSL --max-time 60 -o "$out" -w '%{http_code}' "${hdr[@]}" "$url" 2>/dev/null)" || {
      printf 'network\n'; return 0
    }
    case "$code" in
      429|5[0-9][0-9])
        if (( attempt < 3 )); then
          sleep $(( attempt * 2 ))
          continue
        fi
        ;;
    esac
    printf '%s\n' "$code"
    return 0
  done
}

(( OPT_LIST_JSON )) || info "fetching file list from huggingface.co ..."
CODE="$(fetch_repo_json "$REPO" "$API" "$ARG_TOKEN")"

if [[ "$CODE" == "network" ]]; then
  die "could not reach huggingface.co (check your internet connection)"
fi

if http_needs_auth "$CODE" && [[ -z "$ARG_TOKEN" ]]; then
  if (( NONINTERACTIVE )); then
    die "access denied (HTTP $CODE) -- the repo is private or gated; set HF_TOKEN or pass --token"
  fi
  warn "the API returned HTTP $CODE -- the repo may be private or gated."
  if ask TOK "Paste a Hugging Face token (or press Enter to give up)"; then
    if [[ -n "$TOK" ]]; then
      ARG_TOKEN="$TOK"
      CODE="$(fetch_repo_json "$REPO" "$API" "$ARG_TOKEN")"
    fi
  fi
fi

if [[ "$CODE" != "200" ]]; then
  case "$CODE" in
    401|403) die "access denied (HTTP $CODE). The repo is private or gated and the token is
       missing or invalid, or the name is misspelled. Check this exact id: $REPO" ;;
    404)     die "repo not found (HTTP 404). Check the spelling of: $REPO" ;;
    429)     die "rate limited (HTTP 429) -- wait a minute and try again" ;;
    network) die "could not reach huggingface.co (check your internet connection)" ;;
    *)       die "the API returned HTTP $CODE" ;;
  esac
fi

# Parse JSON -> TSV:  label <TAB> bytes <TAB> repo_path <TAB> category <TAB> note
if ! python3 - "$API" > "$TSV" <<'PY'
import json, os, re, sys

with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
    data = json.load(fh)

siblings = data.get("siblings") or []

SKIP_NAMES = {".gitattributes", "README.md", "SHA256SUMS", "config.json"}
SKIP_EXT = (".md", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".txt", ".json", ".yaml", ".yml")

def keep(name):
    if name in SKIP_NAMES:
        return False
    if name.startswith("assets/") or name.startswith("."):
        return False
    return not name.lower().endswith(SKIP_EXT)

# Short tag for the left column, e.g. Q4_K_M, BF16, INT8, MLX-4BIT.
TAG_PATTERNS = [
    r"Q\d+_K_[A-Z]+", r"Q\d+_K", r"Q\d+_\d+", r"IQ\d+_[A-Z0-9_]+",
    r"NVFP4", r"BF16", r"FP16", r"FP8", r"INT8", r"MLX[-_]?\d+bit",
]

def tag_of(base):
    for pat in TAG_PATTERNS:
        m = re.search(pat, base, re.I)
        if m:
            return m.group(0).upper().replace("MLX", "MLX-").replace("--", "-")
    stem = re.sub(r"\.(gguf|safetensors|bin|pt|ckpt)$", "", base, flags=re.I)
    stem = re.sub(r"^qwen-image-2\.1-(UC-)?", "", stem, flags=re.I)
    return stem[:22] or base[:22]

def category_of(name):
    if name.startswith("text_encoders/"):
        return "text_encoder"
    if name.startswith("vae/"):
        return "vae"
    low = name.lower()
    if "lora" in low:
        return "lora"
    if low.endswith(".gguf"):
        return "gguf"
    if low.endswith(".safetensors"):
        return "safetensors"
    return "other"

# Display order: main GGUF quants first (small -> large), then other weight
# formats, then companion files.
QUANT_ORDER = ["Q4_0", "Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0", "BF16", "IQ4_XS"]
CAT_RANK = {"gguf": 0, "safetensors": 1, "lora": 2, "text_encoder": 3, "vae": 4, "other": 5}

rows = []
for s in siblings:
    name = s.get("rfilename") or ""
    if not name or not keep(name):
        continue
    size = s.get("size") or 0
    cat = category_of(name)
    base = os.path.basename(name)
    tag = tag_of(base)

    if cat in ("gguf", "safetensors") and "/" not in name:
        try:
            order = QUANT_ORDER.index(tag)
        except ValueError:
            order = 50
    else:
        order = 50

    rows.append((CAT_RANK.get(cat, 9), order, int(size), name, tag, cat))

rows.sort(key=lambda r: (r[0], r[1], r[2]))

def note_for(tag, cat, name):
    if cat == "text_encoder":
        return "companion file"
    if cat == "vae":
        return "companion file"
    if tag == "Q4_K_M":
        return "recommended balance"
    if tag in ("BF16", "FP16"):
        return "full precision, heavy"
    if tag == "NVFP4":
        return "needs NVIDIA Blackwell"
    if tag.startswith("MLX"):
        return "macOS / MLX only"
    if cat == "lora":
        return "style LoRA"
    return ""

for r in rows:
    _, _, size, name, tag, cat = r
    label = tag if "/" not in name else f"{cat}: {tag}"
    note = note_for(tag, cat, name)
    print("\t".join([label, str(size), name, cat, note]))
PY
then
  die "could not parse the API response (is this a model repo?)"
fi

if [[ ! -s "$TSV" ]]; then
  die "no downloadable model files found in $REPO"
fi

# Load into parallel arrays.
LABELS=(); SIZES=(); PATHS=(); CATS=(); NOTES=()
while IFS=$'\t' read -r f_label f_size f_path f_cat f_note; do
  LABELS+=("$f_label"); SIZES+=("$f_size"); PATHS+=("$f_path")
  CATS+=("$f_cat"); NOTES+=("${f_note:-}")
done < "$TSV"

COUNT="${#PATHS[@]}"

# Machine-readable list for tools/GUIs.
if (( OPT_LIST_JSON )); then
  python3 - "$TSV" "$REPO" <<'PY'
import json, sys
rows = []
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    for line in fh:
        p = line.rstrip("\n").split("\t")
        if len(p) < 4:
            continue
        label, size, path, cat = p[0], int(p[1] or 0), p[2], p[3]
        note = p[4] if len(p) > 4 else ""
        rows.append({
            "index": len(rows) + 1,
            "label": label,
            "size": size,
            "path": path,
            "category": cat,
            "note": note,
        })
json.dump({"repo": sys.argv[2], "files": rows}, sys.stdout, indent=1)
print()
PY
  exit 0
fi

# Column width for the label.
LABEL_W=0
for l in "${LABELS[@]}"; do (( ${#l} > LABEL_W )) && LABEL_W=${#l}; done
(( LABEL_W < 12 )) && LABEL_W=12
(( LABEL_W > 34 )) && LABEL_W=34

print_menu() {
  local i last_cat=''
  printf '\n%sAvailable files in %s%s%s\n' "$C_BOLD" "$C_CYAN" "$REPO" "$C_RESET"
  printf '%s%s%s\n' "$C_DIM" "-----------------------------------------------------------------------" "$C_RESET"
  for ((i = 0; i < COUNT; i++)); do
    local cat="${CATS[i]}"
    if [[ "$cat" != "$last_cat" ]]; then
      case "$cat" in
        gguf)         printf '\n  %sGGUF -- llama.cpp / ComfyUI-GGUF%s\n' "$C_BOLD" "$C_RESET" ;;
        safetensors)  printf '\n  %sOther weight formats%s\n' "$C_BOLD" "$C_RESET" ;;
        text_encoder) printf '\n  %sText encoders (required companion)%s\n' "$C_BOLD" "$C_RESET" ;;
        vae)          printf '\n  %sVAE (required companion)%s\n' "$C_BOLD" "$C_RESET" ;;
        lora)         printf '\n  %sLoRA%s\n' "$C_BOLD" "$C_RESET" ;;
        *)            printf '\n  %sOther%s\n' "$C_BOLD" "$C_RESET" ;;
      esac
      last_cat="$cat"
    fi
    printf '  %s%2d)%s %-*s %10s  %s%s%s' \
      "$C_CYAN" "$((i + 1))" "$C_RESET" \
      "$LABEL_W" "${LABELS[i]}" \
      "$(fmt_size "${SIZES[i]}")" \
      "$C_DIM" "${PATHS[i]}" "$C_RESET"
    [[ -n "${NOTES[i]}" ]] && printf '  %s<-- %s%s' "$C_YELLOW" "${NOTES[i]}" "$C_RESET"
    printf '\n'
  done
  printf '\n%sSelect by number or name -- e.g. 2 | "2,5" | 1-3 | all   (q to quit)%s\n' "$C_DIM" "$C_RESET"
}

if (( OPT_LIST )); then
  print_menu
  exit 0
fi

print_menu

# ---------------------------------------------------------------------------
# step 3 -- choose file(s)
# ---------------------------------------------------------------------------

# Resolve a selection string to zero-based indices in SELECTED[].
# "none"/"q"/"quit" tokens inside a list are ignored; a *standalone*
# q/quit/none cancels the whole run (handled by the interactive loop).
resolve_selection() {
  local input="$1" tok
  SELECTED=()
  local -a raw=()
  IFS=',' read -r -a raw <<< "$input"

  for tok in "${raw[@]}"; do
    # trim whitespace
    tok="${tok#"${tok%%[![:space:]]*}"}"
    tok="${tok%"${tok##*[![:space:]]}"}"
    [[ -z "$tok" ]] && continue

    case "${tok,,}" in
      all|a|'*')    for ((i = 0; i < COUNT; i++)); do SELECTED+=("$i"); done; continue ;;
      none|n|q|quit) continue ;;
    esac

    if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local lo="${BASH_REMATCH[1]}" hi="${BASH_REMATCH[2]}" n
      (( lo > hi )) && { local t="$lo"; lo="$hi"; hi="$t"; }
      for ((n = lo; n <= hi; n++)); do
        (( n >= 1 && n <= COUNT )) && SELECTED+=("$((n - 1))")
      done
      continue
    fi

    if [[ "$tok" =~ ^[0-9]+$ ]]; then
      (( tok >= 1 && tok <= COUNT )) && SELECTED+=("$((tok - 1))")
      continue
    fi

    # Match by name / tag, case-insensitive substring.
    local hit=-1 matches=0 i
    for ((i = 0; i < COUNT; i++)); do
      if [[ "${LABELS[i],,}" == *"${tok,,}"* || "${PATHS[i],,}" == *"${tok,,}"* ]]; then
        hit="$i"; ((matches++))
      fi
    done
    if (( matches == 1 )); then
      SELECTED+=("$hit")
    elif (( matches > 1 )); then
      warn "'$tok' matches $matches files -- use numbers instead"
    else
      warn "'$tok' did not match anything"
    fi
  done

  # de-duplicate, keep order
  local -a uniq=()
  local seen=" " idx
  for idx in "${SELECTED[@]}"; do
    [[ -z "$idx" ]] && continue
    [[ "$seen" == *" $idx "* ]] && continue
    seen+="$idx "; uniq+=("$idx")
  done
  if (( ${#uniq[@]} > 0 )); then
    SELECTED=("${uniq[@]}")
  else
    SELECTED=()
  fi
  (( ${#SELECTED[@]} > 0 ))
}

SELECTED=()
if [[ -n "$ARG_SEL" ]]; then
  resolve_selection "$ARG_SEL" || die "selection '$ARG_SEL' matched nothing (use --list to see the numbers)"
else
  if (( NONINTERACTIVE )); then
    die "no file selection given -- use -f (run with --list to see the numbers)"
  fi
  while :; do
    ask SEL "Which one do you want" || die "no input"
    [[ -z "$SEL" ]] && { warn "nothing entered"; continue; }
    case "${SEL,,}" in
      q|quit|none) info "cancelled"; exit 0 ;;
    esac
    if resolve_selection "$SEL"; then
      break
    else
      printf '%s    no match for "%s" -- try a number from the list.%s\n' "$C_YELLOW" "$SEL" "$C_RESET" >&2
      print_menu
    fi
  done
fi

# Total bytes to fetch.
TOTAL_BYTES=0
for idx in "${SELECTED[@]}"; do
  TOTAL_BYTES=$((TOTAL_BYTES + SIZES[idx]))
done

printf '\n%sSelected:%s\n' "$C_BOLD" "$C_RESET"
for idx in "${SELECTED[@]}"; do
  printf '   - %s %s(%s)%s\n' "${PATHS[idx]}" "$C_DIM" "$(fmt_size "${SIZES[idx]}")" "$C_RESET"
done
printf '   %s= %s total%s\n' "$C_DIM" "$(fmt_size "$TOTAL_BYTES")" "$C_RESET"

# ---------------------------------------------------------------------------
# step 4 -- where to download
# ---------------------------------------------------------------------------

TARGET=''
if [[ -n "$ARG_DIR" ]]; then
  TARGET="$(expand_path "$ARG_DIR")"
else
  DEFAULT_DIR="$HOME/Downloads/${REPO##*/}"
  if (( NONINTERACTIVE )); then
    TARGET="$(expand_path "$DEFAULT_DIR")"
    info "non-interactive: using default directory ${C_BOLD}${TARGET}${C_RESET} (override with -o)"
  else
    ask DEST "Where should I download it" "$DEFAULT_DIR" || die "no input"
    TARGET="$(expand_path "$DEST")"
  fi
fi

# Layout: how subfolders inside the repo are mapped onto disk.
LAYOUT="$ARG_LAYOUT"
HAS_SUBDIR=0
for idx in "${SELECTED[@]}"; do
  [[ "${PATHS[idx]}" == */* ]] && HAS_SUBDIR=1
done

if [[ -z "$LAYOUT" ]]; then
  if (( HAS_SUBDIR )); then
    if (( NONINTERACTIVE )); then
      LAYOUT=preserve
      info "layout: ${C_BOLD}preserve${C_RESET} ${C_DIM}(non-interactive default -- override with --layout)${C_RESET}"
    else
      printf '\n%sThis repo has subfolders (text_encoders/, vae/). How should I lay them out?%s\n' "$C_BOLD" "$C_RESET"
      printf '  1) keep repo structure   -> %s/text_encoders/..., %s/vae/...   %s(default)%s\n' "$TARGET" "$TARGET" "$C_DIM" "$C_RESET"
      printf '  2) flat                  -> everything directly in %s\n' "$TARGET"
      printf '  3) ComfyUI layout        -> assume %s is ComfyUI models/ dir\n' "$TARGET"
      printf '%s     (ComfyUI: diffusion_models/, text_encoders/, vae/, loras/)%s\n' "$C_DIM" "$C_RESET"
      if ask LAYOUT_ANS "Layout" "1"; then
        case "${LAYOUT_ANS:-1}" in
          2) LAYOUT=flat ;;
          3) LAYOUT=comfyui ;;
          *) LAYOUT=preserve ;;
        esac
      else
        LAYOUT=preserve
      fi
    fi
  else
    LAYOUT=preserve
  fi
fi

# Map a repo-relative path to its destination path.
dest_for() {
  local rel="$1"
  case "$LAYOUT" in
    flat)
      printf '%s/%s\n' "$TARGET" "${rel##*/}"
      ;;
    comfyui)
      local base="${rel##*/}" sub
      case "$rel" in
        text_encoders/*) sub="text_encoders" ;;
        vae/*)           sub="vae" ;;
        *)
          if [[ "${base,,}" == *lora* ]]; then sub="loras"
          elif [[ "${base,,}" == *.gguf ]]; then sub="diffusion_models"
          else sub="diffusion_models"; fi
          ;;
      esac
      printf '%s/%s/%s\n' "$TARGET" "$sub" "$base"
      ;;
    *)
      printf '%s/%s\n' "$TARGET" "$rel"
      ;;
  esac
}

info "target: ${C_BOLD}${TARGET}${C_RESET} ${C_DIM}(layout: ${LAYOUT})${C_RESET}"

# Warn about flat-layout basename collisions before downloading anything.
if [[ "$LAYOUT" == "flat" ]]; then
  COLLIDE="$(for idx in "${SELECTED[@]}"; do printf '%s\n' "${PATHS[idx]##*/}"; done | sort | uniq -d)"
  if [[ -n "$COLLIDE" ]]; then
    warn "these filenames collide in flat layout and would overwrite each other:"
    printf '%s\n' "$COLLIDE" | sed 's/^/    /' >&2
    confirm_gate "Continue anyway with colliding filenames" || { info "cancelled"; exit 0; }
  fi
fi

# Make sure the directory exists and is writable.
mkdir -p "$TARGET" || die "cannot create directory: $TARGET"
[[ -w "$TARGET" ]] || die "directory is not writable: $TARGET"

# Free space check (best effort).
AVAIL_KB="$(df -Pk "$TARGET" 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ "$AVAIL_KB" =~ ^[0-9]+$ ]]; then
  AVAIL_BYTES=$((AVAIL_KB * 1024))
  printf '%s   free space at target: %s%s\n' "$C_DIM" "$(fmt_size "$AVAIL_BYTES")" "$C_RESET"
  if (( TOTAL_BYTES > AVAIL_BYTES )); then
    warn "not enough free space: need $(fmt_size "$TOTAL_BYTES"), have $(fmt_size "$AVAIL_BYTES")"
    confirm_gate "Continue anyway despite low disk space" || { info "cancelled"; exit 0; }
  fi
fi

# ---------------------------------------------------------------------------
# step 5 -- confirm
# ---------------------------------------------------------------------------

if (( OPT_YES )); then
  :
elif (( NONINTERACTIVE )); then
  info "non-interactive: proceeding without confirmation"
else
  printf '\n%sReady to download %d file(s), %s, into:%s\n' "$C_BOLD" "${#SELECTED[@]}" "$(fmt_size "$TOTAL_BYTES")" "$C_RESET"
  printf '  %s\n' "$TARGET"
  ask GO "Start? (Y/n)" "y" || GO=n
  case "${GO,,}" in
    n|no|q|quit) info "cancelled"; exit 0 ;;
  esac
fi

printf '\n'

# ---------------------------------------------------------------------------
# step 6 -- download
# ---------------------------------------------------------------------------

# Pick the fastest available downloader.
DOWNLOADER='curl'
if command -v aria2c >/dev/null 2>&1; then
  DOWNLOADER='aria2c'
fi

# Try to grab SHA256SUMS for verification.
CHECKSUMS_OK=0
AUTH_HDR=(-H "User-Agent: $UA")
[[ -n "$ARG_TOKEN" ]] && AUTH_HDR+=(-H "Authorization: Bearer ${ARG_TOKEN}")

if (( OPT_VERIFY )); then
  sums_code="$(curl -sSL --max-time 30 -o "$SUMS" -w '%{http_code}' \
    "${AUTH_HDR[@]}" \
    "https://huggingface.co/${REPO}/resolve/main/SHA256SUMS" 2>/dev/null)" || sums_code=000
  if [[ "$sums_code" == "200" ]] && grep -qE '^[0-9a-fA-F]{64}[[:space:]]' "$SUMS" 2>/dev/null; then
    CHECKSUMS_OK=1
    printf '%s   checksums: SHA256SUMS found, will verify%s\n' "$C_DIM" "$C_RESET"
  else
    printf '%s   checksums: no SHA256SUMS in repo, skipping verification%s\n' "$C_DIM" "$C_RESET"
  fi
else
  printf '%s   checksums: disabled (--no-verify)%s\n' "$C_DIM" "$C_RESET"
fi

# Look up a file's expected hash (empty if unknown).
expected_hash() {
  local rel="$1"
  (( CHECKSUMS_OK )) || return 0
  awk -v want="$rel" '
    { h = $1; $1 = ""; sub(/^[[:space:]]+/, ""); sub(/^\*/, "");
      if ($0 == want) { print h; exit } }
  ' "$SUMS"
}

# Record the per-file outcome; the main loop collects these in order.
record() { # $1=idx  $2=ok|fail  $3=display
  printf '%s\t%s\n' "$2" "$3" > "$WORK/result.$1"
}

# download_one <idx> <pos> <total>
# Self-contained per-file worker, safe to run in a background subshell.
download_one() {
  local idx="$1" pos="$2" total="$3"
  local rel size dest destdir base url_enc url part
  local have part_have bytes_now code want got magic redo=0 redo_a=''

  rel="${PATHS[idx]}"
  size="${SIZES[idx]}"
  dest="$(dest_for "$rel")"
  destdir="${dest%/*}"
  base="${dest##*/}"
  url_enc="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$rel")"
  url="https://huggingface.co/${REPO}/resolve/main/${url_enc}?download=true"
  part="${dest}.part"

  if ! mkdir -p "$destdir" 2>/dev/null; then
    warn "cannot create $destdir"
    record "$idx" fail "$rel"
    return 1
  fi

  printf '%s%s%s\n' "$C_BOLD$C_BLUE" "-----------------------------------------------------------------------" "$C_RESET"
  printf '%s[%d/%d]%s %s  %s(%s)%s\n' "$C_BOLD" "$pos" "$total" "$C_RESET" \
    "$rel" "$C_DIM" "$(fmt_size "$size")" "$C_RESET"
  printf '%s     -> %s%s\n' "$C_DIM" "$dest" "$C_RESET"

  # ---- existing destination file ------------------------------------------
  if [[ -f "$dest" ]]; then
    have="$(stat_size "$dest" 2>/dev/null || echo 0)"
    if (( size > 0 )) && (( have == size )); then
      if (( CHECKSUMS_OK && OPT_VERIFY )); then
        want="$(expected_hash "$rel")"
        if [[ -n "$want" ]]; then
          printf '%s     file exists -- verifying sha256 before skipping...%s\n' "$C_DIM" "$C_RESET"
          got="$(sha256_of "$dest")"
          if [[ -n "$got" && "${got,,}" == "${want,,}" ]]; then
            ok "verified, skipping download"
            record "$idx" ok "$dest"
            return 0
          fi
          warn "existing file FAILED checksum"
          if (( SEQ && ! OPT_YES )); then
            ask redo_a "Re-download it" "n" || redo_a=n
            [[ "${redo_a,,}" == y* ]] && redo=1
          fi
          if (( ! redo )); then
            record "$idx" fail "$rel (existing file checksum mismatch)"
            return 1
          fi
          rm -f "$dest" || true
          printf '%s     removed bad file, re-downloading%s\n' "$C_DIM" "$C_RESET"
        else
          ok "already downloaded and complete, skipping (no checksum entry)"
          record "$idx" ok "$dest"
          return 0
        fi
      else
        ok "already downloaded and complete, skipping"
        record "$idx" ok "$dest"
        return 0
      fi
    else
      printf '%s     existing file is %s, expected %s -- will re-download and replace it%s\n' \
        "$C_DIM" "$(fmt_size "$have")" "$(fmt_size "$size")" "$C_RESET"
      rm -f "$dest" || true
    fi
  fi

  # ---- recover a complete .part left by an interrupted run ------------------
  local skip=0
  if [[ -f "$part" ]]; then
    part_have="$(stat_size "$part" 2>/dev/null || echo 0)"
    if (( size > 0 )) && (( part_have == size )); then
      if mv -f "$part" "$dest"; then
        ok "recovered a complete download from ${base}.part"
        skip=1
      else
        warn "could not move ${base}.part into place"
        record "$idx" fail "$rel"
        return 1
      fi
    elif (( part_have > 0 )); then
      printf '%s     found a partial download (%s), resuming from there%s\n' \
        "$C_DIM" "$(fmt_size "$part_have")" "$C_RESET"
    fi
  fi

  # ---- transfer -------------------------------------------------------------
  if (( ! skip )); then
    if [[ "$DOWNLOADER" == "aria2c" ]]; then
      local -a ARIA_HDR=(--header="User-Agent: $UA")
      [[ -n "$ARG_TOKEN" ]] && ARIA_HDR+=("--header=Authorization: Bearer ${ARG_TOKEN}")
      if aria2c \
          --continue=true \
          --max-connection-per-server=8 \
          --split=8 \
          --min-split-size=16M \
          --file-allocation=none \
          --auto-file-renaming=false \
          --allow-overwrite=true \
          --user-agent="$UA" \
          --console-log-level=info \
          --summary-interval=10 \
          --dir="$destdir" \
          --out="${base}.part" \
          "${ARIA_HDR[@]}" \
          "$url" && [[ -f "$part" ]]; then
        if ! mv -f "$part" "$dest"; then
          warn "could not move ${base}.part into place"
          record "$idx" fail "$rel"
          return 1
        fi
      else
        local rc=$?
        if (( rc == 0 )) && [[ ! -f "$dest" ]]; then
          warn "download reported success but the file is missing"
          record "$idx" fail "$rel"
          return 1
        fi
        if (( rc != 0 )); then
          warn "aria2c failed (exit $rc) -- retrying with curl"
          DOWNLOADER=curl
        fi
      fi
    fi

    if [[ "$DOWNLOADER" == "curl" ]] && [[ ! -f "$dest" ]]; then
      code="$(curl -L --fail --retry 5 --retry-delay 3 --retry-connrefused \
          --connect-timeout 30 --continue-at - --progress-bar \
          -H "User-Agent: $UA" \
          "${AUTH_HDR[@]}" \
          -o "$part" -w '%{http_code}' "$url")" || code=000
      if [[ "$code" == "200" || "$code" == "206" ]]; then
        bytes_now="$(stat_size "$part" 2>/dev/null || echo 0)"
        if (( size > 0 && bytes_now < size )); then
          warn "downloaded ${bytes_now} of ${size} bytes -- file is incomplete, keeping .part for resume"
          record "$idx" fail "$rel"
          return 1
        fi
        if ! mv -f "$part" "$dest"; then
          warn "could not move ${base}.part into place"
          record "$idx" fail "$rel"
          return 1
        fi
      else
        if [[ "$code" == "416" ]]; then
          warn "server rejected the saved .part (HTTP 416) -- it is older than the remote file."
          printf '%s        delete this and re-run:  rm %s%s\n' "$C_DIM" "$part" "$C_RESET" >&2
        else
          warn "curl failed for $rel (HTTP $code; partial data kept in ${part} for resume)"
        fi
        record "$idx" fail "$rel"
        return 1
      fi
    fi
  fi

  # ---- sanity: GGUF files must start with the GGUF magic --------------------
  if [[ "${base,,}" == *.gguf ]]; then
    magic="$(head -c 4 "$dest" 2>/dev/null || true)"
    if [[ "$magic" != "GGUF" ]]; then
      warn "this file does not start with the GGUF magic bytes -- it may be corrupt or an error page"
    fi
  fi

  # ---- SHA256 verification ---------------------------------------------------
  if (( CHECKSUMS_OK && OPT_VERIFY )); then
    want="$(expected_hash "$rel")"
    if [[ -n "$want" ]]; then
      printf '%s     verifying sha256...%s\n' "$C_DIM" "$C_RESET"
      got="$(sha256_of "$dest")"
      if [[ -n "$got" && "${got,,}" == "${want,,}" ]]; then
        ok "sha256 verified"
      else
        warn "sha256 MISMATCH for $base"
        printf '%s        expected %s%s\n' "$C_DIM" "$want" "$C_RESET" >&2
        printf '%s        got      %s%s\n' "$C_DIM" "$got" "$C_RESET" >&2
        record "$idx" fail "$rel (checksum mismatch)"
        return 1
      fi
    fi
  fi

  record "$idx" ok "$dest"
  return 0
}

# ---- run: sequential or bounded-parallel ------------------------------------
downloaded_files=(); failed_files=(); FAIL_IDX=()
START_TS=$SECONDS
N_SEL="${#SELECTED[@]}"
POS=0
SEQ=0
JOBS="$ARG_JOBS"

if (( JOBS > 1 )); then
  printf '%s   parallel mode: up to %d concurrent download(s)%s\n' "$C_DIM" "$JOBS" "$C_RESET"
  running=0
  local_pids=()
  for idx in "${SELECTED[@]}"; do
    POS=$((POS + 1))
    download_one "$idx" "$POS" "$N_SEL" > "$WORK/log.$idx" 2>&1 &
    local_pids+=("$!")
    running=$((running + 1))
    if (( running >= JOBS )); then
      wait -n "${local_pids[@]}" 2>/dev/null || true
      running=$((running - 1))
    fi
  done
  wait 2>/dev/null || true
else
  SEQ=1
  for idx in "${SELECTED[@]}"; do
    POS=$((POS + 1))
    download_one "$idx" "$POS" "$N_SEL"
  done
fi

# Collect per-file results in selection order.
for idx in "${SELECTED[@]}"; do
  rf="$WORK/result.$idx"
  if [[ -f "$rf" ]]; then
    IFS=$'\t' read -r st disp < "$rf" || { st=fail; disp="${PATHS[idx]}"; }
    if [[ "$st" == "ok" ]]; then
      downloaded_files+=("$disp")
    else
      failed_files+=("$disp")
      FAIL_IDX+=("$idx")
    fi
  else
    failed_files+=("${PATHS[idx]} (no result)")
    FAIL_IDX+=("$idx")
  fi
done

# ---------------------------------------------------------------------------
# step 7 -- summary
# ---------------------------------------------------------------------------

ELAPSED=$((SECONDS - START_TS))
printf '%s%s%s\n' "$C_BOLD$C_BLUE" "-----------------------------------------------------------------------" "$C_RESET"
printf '%sDone.%s %d file(s) downloaded, %d failed, in %dm %ds.\n' \
  "$C_BOLD$C_GREEN" "$C_RESET" "${#downloaded_files[@]}" "${#failed_files[@]}" \
  "$((ELAPSED / 60))" "$((ELAPSED % 60))"

if (( ${#downloaded_files[@]} > 0 )); then
  printf '\n%sSaved to:%s\n' "$C_BOLD" "$C_RESET"
  for f in "${downloaded_files[@]}"; do
    printf '  %s\n' "$f"
  done
fi

if (( ${#failed_files[@]} > 0 )); then
  printf '\n%sFailed:%s\n' "$C_BOLD$C_RED" "$C_RESET"
  for f in "${failed_files[@]}"; do
    printf '  %s\n' "$f"
  done
  printf '%sRe-run this script and pick the same file -- partial data resumes automatically.%s\n' "$C_DIM" "$C_RESET"
  # In parallel mode the per-file output went to logs; show the failing ones.
  if (( JOBS > 1 )); then
    for idx in "${FAIL_IDX[@]}"; do
      lf="$WORK/log.$idx"
      [[ -f "$lf" ]] || continue
      printf '\n%s--- log for %s ---%s\n' "$C_DIM" "${PATHS[idx]}" "$C_RESET"
      tr '\r' '\n' < "$lf" | grep -v '^[[:space:]]*$' | tail -25
    done
  fi
  exit 1
fi

# Placement hints for ComfyUI users.
if [[ "$LAYOUT" != "flat" ]]; then
  for f in "${downloaded_files[@]}"; do
    case "$f" in
      */diffusion_models/*|*/text_encoders/*|*/vae/*|*/loras/*) : ;;
      *)
        printf '\n%sComfyUI tip: put .gguf files in models/diffusion_models/, the text encoder in%s\n' "$C_DIM" "$C_RESET"
        printf '%smodels/text_encoders/ and the VAE in models/vae/.%s\n' "$C_DIM" "$C_RESET"
        break
        ;;
    esac
  done
fi

exit 0