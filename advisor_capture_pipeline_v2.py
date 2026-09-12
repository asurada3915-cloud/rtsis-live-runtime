#!/usr/bin/env python3
"""RTSIS public advisor capture pipeline v2.

Research-only collector. It captures public RSS/Atom, Telegram preview pages,
public YouTube/Instagram pages, and explicit public URLs. It never logs in,
uses cookies, downloads videos, opens the RTSIS Formal DB, or writes to RTSIS.
Every fetch is retained as a raw artifact and every item is deduplicated by
source + canonical URL/content hash.
"""
import argparse, hashlib, html, json, re, sqlite3, sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin, urlparse
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

UA = "RTSIS-Research-Capture/2.0 (+public-only)"
NS = {"atom": "http://www.w3.org/2005/Atom", "media": "http://search.yahoo.com/mrss/"}

def utc(): return datetime.now(timezone.utc).isoformat()
def digest(s): return hashlib.sha256(s.encode("utf-8", "ignore")).hexdigest()
def clean(s): return re.sub(r"\s+", " ", html.unescape(s or "")).strip()

def fetch(url, timeout):
    req = Request(url, headers={"User-Agent": UA, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.5"})
    with urlopen(req, timeout=timeout) as r: return r.read(), r.headers.get_content_type()

def text(node, names):
    for name in names:
        x = node.find(name)
        if x is not None and x.text: return clean(x.text)
    return ""

def feed_items(raw, source):
    root = ET.fromstring(raw); result=[]
    nodes = root.findall(".//item") + root.findall(".//atom:entry", NS)
    for node in nodes:
        title=text(node,["title","atom:title"])
        link=text(node,["link","atom:link"])
        if not link:
            x=node.find("atom:link",NS); link=(x.attrib.get("href","") if x is not None else "")
        published=text(node,["pubDate","published","updated","atom:published","atom:updated"])
        body=text(node,["description","summary","content:encoded","atom:summary"])
        result.append(item(source, title, link, published, body, "feed"))
    return result

def meta(raw, key):
    patterns = [rf'<meta[^>]+(?:property|name|itemprop)=["\']{re.escape(key)}["\'][^>]+content=["\'](.*?)["\']',
                rf'<meta[^>]+content=["\'](.*?)["\'][^>]+(?:property|name|itemprop)=["\']{re.escape(key)}["\']']
    for p in patterns:
        m=re.search(p,raw,re.I|re.S)
        if m:return clean(m.group(1))
    return ""

def html_items(raw, source, url):
    title=meta(raw,"og:title") or meta(raw,"title")
    desc=meta(raw,"og:description") or meta(raw,"description")
    items=[]
    # Telegram public preview: one record per widget post when available.
    posts=re.findall(r'<div[^>]+class=["\'][^"\']*tgme_widget_message[^"\']*["\'][^>]*>(.*?)</div>\s*</div>',raw,re.I|re.S)
    if source.get("source_type")=="telegram" and posts:
        for block in posts:
            post_url=meta(block,"url") or url
            body=clean(re.sub(r"<[^>]+>"," ",re.search(r'tgme_widget_message_text[^>]*>(.*?)</div>',block,re.I|re.S).group(1) if re.search(r'tgme_widget_message_text[^>]*>(.*?)</div>',block,re.I|re.S) else ""))
            dt=""
            m=re.search(r'<time[^>]+datetime=["\'](.*?)["\']',block,re.I|re.S)
            if m:dt=m.group(1)
            items.append(item(source,title,post_url,dt,body,"telegram_public_post"))
    if not items: items=[item(source,title,url,"",desc,"public_page")]
    return items

def item(source, title, url, published, body, mode):
    canonical=url or (source.get("source_url")+"#"+digest(title+body)[:12])
    return {"source_item_id":digest(source["source_id"]+"|"+canonical)[:32],"source_id":source["source_id"],
            "source_name":source.get("source_name"),"source_type":source.get("source_type"),"title":clean(title),
            "url":canonical,"published_at":clean(published),"content_text":clean(body),"capture_mode":mode}

def init(db):
    con=sqlite3.connect(db)
    con.execute("""CREATE TABLE IF NOT EXISTS captured_items(
      source_item_id TEXT PRIMARY KEY, source_id TEXT, source_name TEXT, source_type TEXT,
      title TEXT, url TEXT, published_at TEXT, content_text TEXT, capture_mode TEXT,
      content_hash TEXT, raw_path TEXT, captured_at TEXT, status TEXT, error_message TEXT)""")
    con.execute("CREATE INDEX IF NOT EXISTS idx_capture_date ON captured_items(source_id,published_at)")
    return con

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--config",required=True); ap.add_argument("--output-dir",default="advisor_research_v2"); ap.add_argument("--timeout",type=int,default=30); ap.add_argument("--once",action="store_true"); args=ap.parse_args()
    cfg=json.loads(Path(args.config).read_text(encoding="utf-8")); out=Path(args.output_dir); rawdir=out/"raw"; rawdir.mkdir(parents=True,exist_ok=True)
    con=init(out/"capture_index.sqlite"); report={"run_at":utc(),"sources":[],"new_items":0,"errors":0}
    for source in cfg.get("sources",[]):
        if not source.get("active",True):continue
        urls=[]
        if source.get("feed_url"): urls.append((source["feed_url"],"feed"))
        urls += [(u,"page") for u in (source.get("item_urls") or [source.get("source_url")]) if u]
        sr={"source_id":source.get("source_id"),"status":"ok","seen":0,"new":0,"errors":[]}
        for url,kind in urls:
            try:
                raw,ctype=fetch(url,args.timeout); raw_text=raw.decode("utf-8","replace")
                raw_name=f"{source['source_id']}_{digest(url)[:16]}.html"; raw_path=rawdir/raw_name; raw_path.write_text(raw_text,encoding="utf-8")
                records=feed_items(raw,source) if kind=="feed" or "xml" in ctype else html_items(raw_text,source,url)
                for record in records:
                    record["content_hash"]=digest(record["title"]+"|"+record["content_text"]); record["raw_path"]=str(raw_path.relative_to(out)); record["captured_at"]=utc(); record["status"]="captured"; record["error_message"]=""
                    before=con.total_changes
                    con.execute("""INSERT OR IGNORE INTO captured_items VALUES (:source_item_id,:source_id,:source_name,:source_type,:title,:url,:published_at,:content_text,:capture_mode,:content_hash,:raw_path,:captured_at,:status,:error_message)""",record)
                    sr["seen"]+=1
                    if con.total_changes>before:sr["new"]+=1; report["new_items"]+=1
            except Exception as exc:
                sr["errors"].append({"url":url,"error":f"{type(exc).__name__}: {exc}"}); report["errors"]+=1
        if sr["errors"]:sr["status"]="partial" if sr["seen"] else "error"
        report["sources"].append(sr)
    con.commit(); con.close(); stamp=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"); (out/f"capture_run_{stamp}.json").write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8"); print(json.dumps(report,ensure_ascii=False,indent=2))

if __name__=="__main__":main()
