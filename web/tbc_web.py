#!/usr/bin/env python3
"""Local authenticated web UI for TCP Brutal Custom."""
import base64
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import subprocess
import threading
import time
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

CONFIG = "/etc/tcp-brutal-custom-web.conf"
DB = "/var/lib/tcp-brutal-custom/traffic.sqlite3"
TBC = "/usr/local/bin/tbc"
BRUTALCTL = "/usr/local/bin/brutalctl"
SESSIONS = {}
SESSIONS_LOCK = threading.Lock()
JOBS = {}
LOGIN_FAILURES = {}


def config():
    values = {}
    try:
        with open(CONFIG, encoding="utf-8") as handle:
            for line in handle:
                if "=" in line:
                    key, value = line.rstrip("\n").split("=", 1)
                    values[key] = value
    except FileNotFoundError:
        pass
    return values


def manager_config():
    values = {}
    try:
        with open("/etc/tcp-brutal-custom.conf", encoding="utf-8") as handle:
            for line in handle:
                if "=" in line:
                    key, value = line.rstrip("\n").split("=", 1)
                    values[key] = value
    except FileNotFoundError:
        pass
    return values


def verify_password(password):
    values = config()
    try:
        rounds, salt, digest = values["PASSWORD_HASH"].split("$", 2)
        actual = hashlib.pbkdf2_hmac("sha256", password.encode(),
                                     base64.b64decode(salt), int(rounds))
        return hmac.compare_digest(base64.b64encode(actual).decode(), digest)
    except (KeyError, ValueError):
        return False


def run(*args, timeout=30):
    try:
        result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
        return result.returncode, result.stdout, result.stderr
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, "", str(exc)


def start_job(name, args):
    job_id = secrets.token_urlsafe(12)
    JOBS[job_id] = {"running": True, "output": ""}
    def worker():
        result = subprocess.run([TBC, name, *args], text=True, capture_output=True)
        JOBS[job_id] = {"running": False, "ok": result.returncode == 0,
                        "output": result.stdout + result.stderr}
    threading.Thread(target=worker, daemon=True).start()
    return job_id


def port_stats():
    code, output, error = run(BRUTALCTL, "port-stats")
    rows = []
    for line in output.splitlines():
        fields = dict(item.split("=", 1) for item in line.split() if "=" in item)
        if "port" in fields:
            sent, retrans = int(fields.get("sent", 0)), int(fields.get("retrans", 0))
            rows.append({"port": int(fields["port"]), "sent": sent, "retrans": retrans,
                         "rate": retrans / sent if sent else None})
    return {"ports": rows, "error": error if code else None}


def history(days):
    if not os.path.exists(DB):
        return []
    cutoff = time.strftime("%Y-%m-%d", time.localtime(time.time() - days * 86400))
    with sqlite3.connect(DB) as db:
        rows = db.execute("SELECT day,port,sent,retrans FROM daily WHERE day>=? ORDER BY day,port",
                          (cutoff,)).fetchall()
    return [{"day": d, "port": p, "sent": s, "retrans": r,
             "rate": r / s if s else None} for d, p, s, r in rows]


def page():
    return '''<!doctype html><meta charset="utf-8"><title>TCP Brutal Custom</title>
<style>body{font:16px system-ui;max-width:1050px;margin:2rem auto;padding:0 1rem;background:#101820;color:#e6edf3}button,input{padding:.5rem;margin:.2rem}table{width:100%;border-collapse:collapse}td,th{padding:.55rem;border-bottom:1px solid #38444d;text-align:left}.card{padding:1rem;background:#18242e;margin:1rem 0}pre{white-space:pre-wrap}</style>
<h1>TCP Brutal Custom</h1><div id="app">载入中…</div><script>
let CSRF='';
const call=async(p,o={})=>{let r=await fetch(p,{headers:{'Content-Type':'application/json','X-CSRF':CSRF},...o});if(!r.ok)throw Error(await r.text());return r.json()};
const fmt=n=>n==null?'—':new Intl.NumberFormat().format(n); const pct=n=>n==null?'—':(n*100).toFixed(2)+'%';
async function render(){try{let [s,p,h]=await Promise.all([call('/api/status'),call('/api/port-stats'),call('/api/history?days=30')]);CSRF=s.csrf||CSRF;
let rows=p.ports.map(x=>`<tr><td>${x.port}</td><td>${fmt(x.sent)}</td><td>${fmt(x.retrans)}</td><td>${pct(x.rate)}</td></tr>`).join('');
const sum=days=>{let x=h.filter(v=>v.day>=days).reduce((a,v)=>({sent:a.sent+v.sent,retrans:a.retrans+v.retrans}),{sent:0,retrans:0});return `${fmt(x.sent)} 字节 / ${pct(x.sent?x.retrans/x.sent:null)}`}; const today=s.today, week=s.week, month=s.month; let historyRows=h.map(x=>`<tr><td>${x.day}</td><td>${x.port}</td><td>${fmt(x.sent)}</td><td>${pct(x.rate)}</td></tr>`).join('');
document.querySelector('#app').innerHTML=`<div class=card><b>状态</b><pre>${s.status}</pre></div><div class=card><b>管理</b><form id=f>模式 <select name=mode><option>${s.config.MODE}</option><option>auto</option><option>ipv4</option><option>ipv6</option><option>dual</option></select> IPv4 <input name=v4 value="${s.config.IPV4_RATE}"> IPv6 <input name=v6 value="${s.config.IPV6_RATE}"> 端口 <input name=ports value="${s.config.TCP_PORTS||''}"> 总出口 <input name=aggregate value="${s.config.AGGREGATE_RATE}"><button>保存</button></form><button onclick="act('enable')">开启开机启动</button><button onclick="act('disable')">关闭开机启动</button><button onclick="act('ports-check')">端口预检</button><button onclick="act('aggregate-check')">出口预检</button><button onclick="act('update')">安装 / 更新</button><button onclick="if(confirm('确认卸载并删除统计历史？'))act('uninstall')">卸载</button></div><div class=card><b>已管理端口累计</b><table><tr><th>端口</th><th>发送字节</th><th>重传字节</th><th>平均重传率</th></tr>${rows||'<tr><td colspan=4>暂无数据</td></tr>'}</table><p>今日：${sum(today)}　最近 7 天：${sum(week)}　最近 30 天：${sum(month)}</p><table><tr><th>日期</th><th>端口</th><th>发送字节</th><th>平均重传率</th></tr>${historyRows||'<tr><td colspan=4>暂无历史</td></tr>'}</table></div><div class=card><b>活跃 IP</b><pre id=peers>载入中…</pre></div><button onclick="location='/logout'">退出登录</button>`;
document.querySelector('#f').onsubmit=async e=>{e.preventDefault();let f=new FormData(e.target);await act('rate',[f.get('v4'),f.get('v6'),f.get('mode')]);await act('ports',[f.get('ports')]);await act('aggregate',[f.get('aggregate')]);render()};let peers=await call('/api/peers');document.querySelector('#peers').textContent=peers.output}catch(e){document.querySelector('#app').textContent=e}}
async function act(name,args=[]){let r=await call('/api/action',{method:'POST',body:JSON.stringify({name,args})});alert(r.output||r.error||'已完成')};render();setInterval(render,10000);
</script>'''.encode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def json(self, value, status=200):
        data = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def body(self):
        length = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(length) or b"{}")
    def session(self):
        cookie = SimpleCookie(self.headers.get("Cookie")); token = cookie.get("tbc_session")
        with SESSIONS_LOCK:
            session = token and SESSIONS.get(token.value)
            if session and session["expires"] > time.time():
                return session
            if token:
                SESSIONS.pop(token.value, None)
            return None
    def login_required(self):
        if self.session(): return False
        self.json({"error": "请先登录"}, HTTPStatus.UNAUTHORIZED); return True
    def do_GET(self):
        if self.path == "/login":
            self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8"); self.end_headers()
            self.wfile.write('<meta charset="utf-8"><form method="post"><input name="user" placeholder="用户名"><input name="password" type="password" placeholder="密码"><button>登录</button></form>'.encode()); return
        if self.path == "/logout":
            self.send_response(303); self.send_header("Set-Cookie", "tbc_session=; Max-Age=0; Path=/; HttpOnly; SameSite=Strict"); self.send_header("Location", "/login"); self.end_headers(); return
        if self.login_required(): return
        if self.path == "/":
            data=page(); self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        if self.path == "/api/status":
            now = time.time()
            code,out,err=run(TBC,"status"); self.json({"status":out+err,"config":manager_config(),"csrf":self.session()["csrf"],"today":time.strftime("%Y-%m-%d", time.localtime(now)),"week":time.strftime("%Y-%m-%d", time.localtime(now-6*86400)),"month":time.strftime("%Y-%m-%d", time.localtime(now-29*86400))}); return
        if self.path == "/api/port-stats": self.json(port_stats()); return
        if self.path.startswith("/api/history"):
            self.json(history(30)); return
        if self.path == "/api/peers":
            code,out,err=run(TBC,"view",timeout=15); self.json({"output":out+err}); return
        if self.path.startswith("/api/job?id="):
            self.json(JOBS.get(self.path.split("=", 1)[1], {"error": "任务不存在"}), 200); return
        self.send_error(404)
    def do_POST(self):
        if self.path == "/login":
            raw=self.rfile.read(int(self.headers.get("Content-Length",0))).decode(); fields=dict(x.split("=",1) for x in raw.split("&") if "=" in x)
            from urllib.parse import unquote_plus
            values=config()
            client = self.client_address[0]
            failures, blocked_until = LOGIN_FAILURES.get(client, (0, 0))
            if blocked_until > time.time():
                self.send_error(HTTPStatus.TOO_MANY_REQUESTS, "请稍后再试")
                return
            if fields.get("user") == values.get("USER") and verify_password(unquote_plus(fields.get("password", ""))):
                token=secrets.token_urlsafe(32)
                with SESSIONS_LOCK: SESSIONS[token]={"expires":time.time()+43200,"csrf":secrets.token_urlsafe(24)}
                LOGIN_FAILURES.pop(client, None)
                self.send_response(303); self.send_header("Set-Cookie", "tbc_session=%s; Path=/; HttpOnly; SameSite=Strict"%token); self.send_header("Location","/"); self.end_headers()
            else:
                failures += 1
                LOGIN_FAILURES[client] = (failures, time.time()+300 if failures >= 5 else 0)
                self.send_error(HTTPStatus.UNAUTHORIZED, "用户名或密码错误")
            return
        if self.login_required(): return
        if self.path != "/api/action": self.send_error(404); return
        try:
            if not hmac.compare_digest(self.headers.get("X-CSRF", ""), self.session()["csrf"]):
                raise ValueError("CSRF 校验失败")
            data=self.body(); name=data["name"]; args=data.get("args", [])
            allowed={"rate":3,"ports":1,"aggregate":1,"enable":0,"disable":0,"ports-check":0,"aggregate-check":0,"install":0,"update":0,"uninstall":0}
            if name not in allowed or len(args) != allowed[name] or not all(isinstance(x,str) and len(x)<128 for x in args): raise ValueError("无效操作")
            if name in {"install", "update", "uninstall"}:
                self.json({"job": start_job(name, args), "ok": True}); return
            code,out,err=run(TBC,name,*args,timeout=120)
            self.json({"output":out,"error":err,"ok":code==0}, 200 if code==0 else 400)
        except (ValueError, json.JSONDecodeError) as exc: self.json({"error":str(exc)},400)


if __name__ == "__main__":
    value=config(); port=int(value.get("PORT", "8080"))
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
