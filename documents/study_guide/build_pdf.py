#!/usr/bin/env python3
# study_guide .md 23개 → mermaid를 kroki PNG로 렌더 → 합쳐서 combined.md 생성
import re, os, glob, subprocess

SG  = "/data/2026 CAU/AIX2026/git/Yolo_Accelerator/documents/study_guide"
OUT = "/tmp/pdfbuild"
DIAG = os.path.join(OUT, "diagrams")
os.makedirs(DIAG, exist_ok=True)

# 파일 순서: README 먼저, 그 다음 01..22
def order(f):
    b = os.path.basename(f)
    if b == "README.md": return -1
    m = re.match(r"(\d+)_", b)
    return int(m.group(1)) if m else 999
files = sorted(glob.glob(os.path.join(SG, "*.md")), key=order)

# 이모지/특수 마커 → 텍스트 (xelatex 폰트에 없는 글리프 깨짐 방지)
EMOJI = {
    "💡":"[비유] ", "🔍":"[코드] ", "❓":"[왜?] ", "⚠️":"[주의] ", "⚠":"[주의] ",
    "🔑":"[핵심] ", "✅":"[O]", "❌":"[X]", "★":"*", "📍":"", "📑":"", "🎯":"",
    "🚌":"", "🔢":"", "🧮":"", "💾":"", "🪟":"", "🌊":"", "📋":"", "📞":"", "📦":"",
    "🟦":"■", "🟩":"■", "🟥":"■", "🟡":"", "🟢":"", "🔴":"", "⏳":"", "🤖":"",
    "①":"(1)", "②":"(2)", "③":"(3)", "④":"(4)", "⑤":"(5)",
    "⑥":"(6)", "⑦":"(7)", "⑧":"(8)", "⑨":"(9)",
}

def krender(code, name):
    png = os.path.join(DIAG, name + ".png")
    if os.path.exists(png) and os.path.getsize(png) > 100:
        return png  # 캐시 재사용 (재렌더 skip)
    subprocess.run(["curl", "-sf", "-X", "POST", "https://kroki.io/mermaid/png",
                    "-H", "Content-Type: text/plain",
                    "--data-binary", "@-", "-o", png],
                   input=code.encode("utf-8"), check=True, timeout=90)
    if (not os.path.exists(png)) or os.path.getsize(png) < 100:
        raise Exception("empty/small response")
    with open(png, "rb") as fh:
        if fh.read(8) != b"\x89PNG\r\n\x1a\n":
            raise Exception("not PNG")
    return png

parts = []
mcount = [0]
fail = []

def repl_mermaid(m):
    mcount[0] += 1
    code = m.group(1)
    name = f"d{mcount[0]:03d}"
    try:
        png = krender(code, name)
        return f"\n\n![]({png})\n\n"
    except Exception as e:
        fail.append((name, str(e)))
        return "\n\n```\n[diagram render failed]\n" + code + "\n```\n\n"

for f in files:
    txt = open(f, encoding="utf-8").read()
    # 네비게이션 blockquote 줄 제거 ('> [' 로 시작)
    txt = "\n".join(l for l in txt.split("\n") if not l.lstrip().startswith("> ["))
    # mermaid → kroki PNG
    txt = re.sub(r"```mermaid\n(.*?)\n```", repl_mermaid, txt, flags=re.DOTALL)
    # 내부 .md / 상대 / http 링크 → 링크 텍스트만 남김 (PDF에서 클릭 의미 없음)
    txt = re.sub(r"\[([^\]]+)\]\([^)]*\.md[^)]*\)", r"\1", txt)
    txt = re.sub(r"\[([^\]]+)\]\((?:\.\./|\./|https?:)[^)]*\)", r"\1", txt)
    # 이모지 치환
    for k, v in EMOJI.items():
        txt = txt.replace(k, v)
    parts.append(txt)

combined = "\n\n\\newpage\n\n".join(parts)
open(os.path.join(OUT, "combined.md"), "w", encoding="utf-8").write(combined)
print("mermaid rendered:", mcount[0], "fail:", len(fail))
for n, e in fail:
    print("  FAIL", n, e[:80])
print("combined chars:", len(combined))
