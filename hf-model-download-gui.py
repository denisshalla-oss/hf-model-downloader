#!/usr/bin/env python3
"""
hf-model-download-gui.py — small local web GUI for hf-model-download.sh.

Stdlib only. Binds to 127.0.0.1 (never 0.0.0.0).

Endpoints:
  GET  /                single-page UI
  GET  /api/list        ?url=<repo> [&token=...]  -> file list JSON
  POST /api/download    {url, dir, files[], layout, verify, jobs, token}
                        -> streams the script output (chunked) until done
  POST /api/cancel      kill the running download process group
  GET  /api/status      {running: bool}
"""

import json
import os
import signal
import socket
import subprocess
import sys
import threading
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "hf-model-download.sh")
DEFAULT_PORT = 8791
LIST_TIMEOUT = 90

# ---------------------------------------------------------------- state ----
_lock = threading.Lock()
STATE = {"proc": None}  # currently running download Popen (or None)


def _free_port(start):
    for port in range(start, start + 50):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise SystemExit("no free port found near %d" % start)


# ------------------------------------------------------------- handler -----
class Handler(BaseHTTPRequestHandler):
    server_version = "HFModelDownloaderGUI/1.0"
    timeout = 3600  # downloads can run for hours

    def log_message(self, fmt, *args):  # quieter logs
        sys.stderr.write("gui: " + fmt % args + "\n")

    # -- helpers ------------------------------------------------------------
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            return json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            return {}

    def _chunk(self, data: bytes):
        self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
        self.wfile.flush()

    # -- routes ---------------------------------------------------------------
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/":
            page = HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(page)))
            self.end_headers()
            self.wfile.write(page)
        elif u.path == "/api/status":
            with _lock:
                running = STATE["proc"] is not None
            self._json(200, {"running": running})
        elif u.path == "/api/list":
            q = urllib.parse.parse_qs(u.query)
            url = (q.get("url") or [""])[0].strip()
            token = (q.get("token") or [""])[0].strip()
            if not url:
                return self._json(400, {"error": "missing url"})
            if not os.path.isfile(SCRIPT):
                return self._json(500, {"error": "script not found: %s" % SCRIPT})
            cmd = ["bash", SCRIPT, "--list-json", url]
            if token:
                cmd += ["--token", token]
            try:
                p = subprocess.run(cmd, capture_output=True, text=True,
                                   timeout=LIST_TIMEOUT)
            except subprocess.TimeoutExpired:
                return self._json(504, {"error": "timed out talking to huggingface.co"})
            if p.returncode != 0:
                err = (p.stderr or p.stdout or "").strip().splitlines()
                return self._json(502, {"error": err[-1] if err else "exit %d" % p.returncode})
            try:
                data = json.loads(p.stdout)
            except Exception:
                return self._json(502, {"error": "could not parse file list"})
            self._json(200, data)
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/api/cancel":
            with _lock:
                p = STATE["proc"]
            if p is None:
                return self._json(409, {"error": "nothing running"})
            try:
                os.killpg(os.getpgid(p.pid), signal.SIGTERM)
            except ProcessLookupError:
                pass
            self._json(200, {"ok": True})
            return

        if u.path == "/api/download":
            b = self._body_json()
            with _lock:
                if STATE["proc"] is not None:
                    return self._json(409, {"error": "a download is already running"})
            url = (b.get("url") or "").strip()
            files = b.get("files") or []
            if not url or not files:
                return self._json(400, {"error": "url and files are required"})
            if not os.path.isfile(SCRIPT):
                return self._json(500, {"error": "script not found: %s" % SCRIPT})

            cmd = ["bash", SCRIPT, url, "-y",
                   "-f", ",".join(str(int(i)) for i in files)]
            d = (b.get("dir") or "").strip()
            if d:
                cmd += ["-o", d]
            layout = b.get("layout") or "auto"
            if layout != "auto":
                cmd += ["--layout", layout]
            try:
                jobs = max(1, min(8, int(b.get("jobs") or 1)))
            except Exception:
                jobs = 1
            cmd += ["--jobs", str(jobs)]
            if not b.get("verify", True):
                cmd += ["--no-verify"]
            token = (b.get("token") or "").strip()
            if token:
                cmd += ["--token", token]

            p = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT,
                                 start_new_session=True)
            with _lock:
                STATE["proc"] = p

            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()

            client_gone = False
            try:
                for raw in iter(p.stdout.readline, b""):
                    self._chunk(raw.decode("utf-8", "replace").encode("utf-8"))
                p.wait()
                rc = p.returncode
                self._chunk(("\n<<<EOF rc=%d>>>\n" % rc).encode())
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                client_gone = True
            finally:
                if client_gone:
                    # download keeps running in the background; keep tracking
                    # it so /api/status and /api/cancel still work
                    def reap(prc):
                        prc.wait()
                        with _lock:
                            if STATE["proc"] is prc:
                                STATE["proc"] = None
                    threading.Thread(target=reap, args=(p,), daemon=True).start()
                else:
                    with _lock:
                        if STATE["proc"] is p:
                            STATE["proc"] = None
            return

        self._json(404, {"error": "not found"})


# ----------------------------------------------------------------- html ----
HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Hugging Face Model Downloader</title>
<style>
  :root{
    --bg:#0f1115; --panel:#171a21; --panel2:#1d212b; --line:#2a2f3a;
    --text:#e6e9ef; --dim:#8b93a3; --acc:#4da3ff; --acc2:#2f7fe0;
    --ok:#3fb96f; --err:#e35d6a; --warn:#e0a63f;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--text);
       font:14px/1.45 system-ui,Segoe UI,Roboto,Helvetica,Arial,sans-serif}
  .wrap{max-width:1000px;margin:0 auto;padding:20px 16px 60px}
  h1{font-size:20px;margin:8px 0 2px}
  h1 .dot{color:var(--acc)}
  .sub{color:var(--dim);margin:0 0 18px}
  .card{background:var(--panel);border:1px solid var(--line);
        border-radius:10px;padding:14px 16px;margin-bottom:14px}
  label{display:block;color:var(--dim);font-size:12px;margin:10px 0 4px;text-transform:uppercase;letter-spacing:.04em}
  label:first-child{margin-top:0}
  input[type=text],input[type=password],select,input[type=number]{
    width:100%;background:var(--panel2);border:1px solid var(--line);
    color:var(--text);border-radius:8px;padding:9px 10px;font-size:14px}
  input:focus,select:focus{outline:none;border-color:var(--acc2)}
  .row{display:flex;gap:12px;flex-wrap:wrap}
  .row>div{flex:1;min-width:160px}
  button{cursor:pointer;border:0;border-radius:8px;padding:10px 16px;
         font-size:14px;font-weight:600}
  .primary{background:var(--acc);color:#08111d}
  .primary:hover{background:#6cb4ff}
  .primary:disabled{background:#2a3a52;color:#6b7688;cursor:not-allowed}
  .ghost{background:var(--panel2);color:var(--text);border:1px solid var(--line)}
  .ghost:hover{border-color:var(--acc2)}
  .danger{background:#3a1d22;color:#f0a7ae;border:1px solid #59282f}
  .danger:disabled{opacity:.45;cursor:not-allowed}
  table{width:100%;border-collapse:collapse}
  th{color:var(--dim);text-align:left;font-size:12px;text-transform:uppercase;
     letter-spacing:.04em;padding:6px 8px;border-bottom:1px solid var(--line)}
  td{padding:7px 8px;border-bottom:1px solid #20242e;vertical-align:middle}
  tr:last-child td{border-bottom:0}
  tr:hover td{background:#1a1e27}
  .sz{color:var(--dim);white-space:nowrap;text-align:right}
  .path{color:var(--dim);font-size:12px;max-width:340px;overflow:hidden;
        text-overflow:ellipsis;white-space:nowrap}
  .note{color:var(--warn);font-size:12px;white-space:nowrap}
  .tag{display:inline-block;background:var(--panel2);border:1px solid var(--line);
       border-radius:6px;padding:1px 7px;font-size:11px;color:var(--dim);margin-left:8px}
  .toolbar{display:flex;align-items:center;gap:10px;margin:2px 0 10px}
  .toolbar .sp{flex:1}
  #total{color:var(--dim);font-size:13px}
  #status{font-size:13px;color:var(--dim)}
  #status.run{color:var(--acc)} #status.ok{color:var(--ok)} #status.err{color:var(--err)}
  #log{background:#0b0d11;border:1px solid var(--line);border-radius:8px;
       padding:12px;height:340px;overflow:auto;font:12.5px/1.5 ui-monospace,
       SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;
       word-break:break-word}
  .hidden{display:none}
  .spin{display:inline-block;width:13px;height:13px;border:2px solid #6cb4ff44;
        border-top-color:var(--acc);border-radius:50%;animation:sp .8s linear infinite;
        vertical-align:-2px;margin-right:6px}
  @keyframes sp{to{transform:rotate(360deg)}}
  .chk{width:16px;height:16px;accent-color:var(--acc)}
</style>
</head>
<body>
<div class="wrap">
  <h1>Hugging Face Model Downloader<span class="dot">.</span></h1>
  <p class="sub">Paste a repo link &rarr; pick files &rarr; pick a folder &rarr; download with resume + SHA256.</p>

  <div class="card">
    <div class="row">
      <div style="flex:3">
        <label>Repo link</label>
        <input type="text" id="url" placeholder="https://huggingface.co/owner/model" spellcheck="false">
      </div>
      <div style="flex:2">
        <label>HF token (optional, for private/gated)</label>
        <input type="password" id="token" placeholder="hf_..." spellcheck="false">
      </div>
    </div>
    <div class="toolbar" style="margin:12px 0 0">
      <button class="primary" id="btnList">Load file list</button>
      <span id="status"></span>
    </div>
  </div>

  <div class="card hidden" id="fileCard">
    <div class="toolbar">
      <label class="chk" style="margin:0"><input type="checkbox" class="chk" id="selAll" checked></label>
      <b>Files</b>
      <span class="sp"></span>
      <span id="total"></span>
    </div>
    <table>
      <thead><tr><th style="width:26px"></th><th>File</th><th class="sz">Size</th><th class="note">Note</th></tr></thead>
      <tbody id="rows"></tbody>
    </table>
  </div>

  <div class="card">
    <div class="row">
      <div style="flex:3">
        <label>Download folder (blank = ~/Downloads/&lt;repo&gt;)</label>
        <input type="text" id="dir" placeholder="~/Downloads/..." spellcheck="false">
      </div>
      <div>
        <label>Layout</label>
        <select id="layout">
          <option value="auto">auto</option>
          <option value="preserve">preserve repo structure</option>
          <option value="flat">flat</option>
          <option value="comfyui">ComfyUI folders</option>
        </select>
      </div>
      <div>
        <label>Parallel downloads</label>
        <input type="number" id="jobs" min="1" max="8" value="1">
      </div>
    </div>
    <div class="toolbar" style="margin-top:14px">
      <label class="chk" style="margin:0;text-transform:none;letter-spacing:0">
        <input type="checkbox" class="chk" id="verify" checked> verify SHA256
      </label>
      <span class="sp"></span>
      <button class="danger hidden" id="btnCancel">Cancel</button>
      <button class="primary" id="btnGo" disabled>Download</button>
    </div>
  </div>

  <div class="card hidden" id="logCard">
    <div class="toolbar" style="margin-bottom:8px"><b>Live output</b><span class="sp"></span><span id="logStatus"></span></div>
    <pre id="log"></pre>
  </div>
</div>

<script>
const $ = id => document.getElementById(id);
let files = [];

function fmtSize(b){
  if(!b) return "-";
  const u=["B","KB","MB","GB","TB"]; let i=0;
  while(b>=1000 && i<u.length-1){b/=1000;i++;}
  return (i===0?b:b.toFixed(2))+" "+u[i];
}
function setStatus(txt, cls){
  const s=$("status"); s.textContent=txt; s.className=cls||"";
}
async function api(path, opts){
  const r = await fetch(path, opts);
  return r;
}

$("btnList").onclick = async () => {
  const url = $("url").value.trim();
  if(!url){ setStatus("Paste a repo link first","err"); return; }
  setStatus("<span class='spin'></span>Fetching file list...","run");
  $("status").innerHTML = "<span class='spin'></span>Fetching file list...";
  $("status").className="run";
  const tok = $("token").value.trim();
  const q = "url="+encodeURIComponent(url)+(tok?"&token="+encodeURIComponent(tok):"");
  try{
    const r = await api("/api/list?"+q);
    const d = await r.json();
    if(!r.ok) throw new Error(d.error||("HTTP "+r.status));
    files = d.files||[];
    const tb=$("rows"); tb.innerHTML="";
    for(const f of files){
      const tr=document.createElement("tr");
      tr.innerHTML =
        "<td><input type='checkbox' class='chk fchk' value='"+f.index+"' checked></td>"+
        "<td><b>"+esc(f.label)+"</b><span class='tag'>"+esc(f.category)+"</span>"+
          "<div class='path' title='"+esc(f.path)+"'>"+esc(f.path)+"</div></td>"+
        "<td class='sz'>"+fmtSize(f.size)+"</td>"+
        "<td class='note'>"+esc(f.note||"")+"</td>";
      tb.appendChild(tr);
    }
    $("fileCard").classList.remove("hidden");
    $("btnGo").disabled = false;
    updateTotal();
    setStatus(files.length+" files ready","");
  }catch(e){
    $("status").textContent = "Error: "+e.message;
    $("status").className="err";
  }
};

function esc(s){return String(s).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));}

function selectedFiles(){
  return files.filter(f=>{
    const cb=$("rows").querySelector(".fchk[value='"+f.index+"']");
    return cb && cb.checked;
  });
}
function updateTotal(){
  const sel=selectedFiles();
  const bytes=sel.reduce((a,f)=>a+f.size,0);
  $("total").textContent = sel.length+" selected · "+fmtSize(bytes);
  $("btnGo").disabled = sel.length===0;
}
$("selAll").onchange = e => {
  document.querySelectorAll(".fchk").forEach(c=>c.checked=e.target.checked);
  updateTotal();
};
$("rows").addEventListener("change", updateTotal);
$("url").addEventListener("keydown", e=>{ if(e.key==="Enter") $("btnList").click(); });

function appendLog(t){
  const l=$("log");
  l.textContent += t;
  const near = l.scrollHeight - l.scrollTop - l.clientHeight < 60;
  if(near) l.scrollTop = l.scrollHeight;
}

$("btnGo").onclick = async () => {
  const sel = selectedFiles();
  if(!sel.length) return;
  const payload = {
    url: $("url").value.trim(),
    dir: $("dir").value.trim(),
    files: sel.map(f=>f.index),
    layout: $("layout").value,
    verify: $("verify").checked,
    jobs: parseInt($("jobs").value||"1",10),
    token: $("token").value.trim()
  };
  $("logCard").classList.remove("hidden");
  $("log").textContent = "";
  $("btnGo").disabled = true; $("btnList").disabled = true;
  $("btnCancel").classList.remove("hidden");
  $("status").innerHTML = "<span class='spin'></span>Downloading "+sel.length+" file(s)...";
  $("status").className="run";
  appendLog("$ download "+sel.length+" file(s) from "+payload.url+"\n\n");
  try{
    const r = await api("/api/download",{
      method:"POST",
      headers:{"Content-Type":"application/json"},
      body: JSON.stringify(payload)
    });
    if(!r.ok){
      const d = await r.json().catch(()=>({}));
      throw new Error(d.error||("HTTP "+r.status));
    }
    const reader = r.body.getReader();
    const dec = new TextDecoder();
    while(true){
      const {done, value} = await reader.read();
      if(done) break;
      appendLog(dec.decode(value,{stream:true}));
    }
    const tail = $("log").textContent;
    const m = tail.match(/<<<EOF rc=(\d+)>>>/);
    const rc = m ? parseInt(m[1], 10) : -1;
    if (rc === 0)      { setStatus("Done ✓","ok"); $("logStatus").textContent = "finished"; }
    else if (rc === 130 || rc === 143) { setStatus("Cancelled",""); $("logStatus").textContent = "cancelled"; }
    else               { setStatus("Finished with errors — see log","err"); $("logStatus").textContent = "finished with errors"; }
  }catch(e){
    $("status").textContent = "Error: "+e.message;
    $("status").className="err";
  }finally{
    $("btnGo").disabled = selectedFiles().length===0;
    $("btnList").disabled = false;
    $("btnCancel").classList.add("hidden");
    refreshRunning();
  }
};

$("btnCancel").onclick = async () => {
  $("btnCancel").disabled = true;
  try{ await api("/api/cancel",{method:"POST"}); }catch(e){}
  $("btnCancel").disabled = false;
};

async function refreshRunning(){
  try{
    const r = await api("/api/status");
    const d = await r.json();
    if(d.running){
      $("btnGo").disabled = true;
      $("btnCancel").classList.remove("hidden");
      $("status").innerHTML = "<span class='spin'></span>Download running (started outside this page?)";
      $("status").className="run";
    }
  }catch(e){}
}
refreshRunning();
</script>
</body>
</html>
"""


# ---------------------------------------------------------------- main -----
def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--no-browser", action="store_true",
                    help="do not open a browser tab automatically")
    args = ap.parse_args()

    port = _free_port(args.port)
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    httpd.daemon_threads = True
    url = "http://127.0.0.1:%d" % port
    print("HF Model Downloader GUI on %s  (Ctrl-C to stop)" % url, flush=True)
    if not args.no_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped.")


if __name__ == "__main__":
    main()
