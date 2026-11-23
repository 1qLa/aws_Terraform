"""申告・承認の画面(フロントエンド)の動作確認

使い方: terraform.tfvars に enable_test_client = true を書いて apply したあと、
        リポジトリのルートで  python3 drafts/test_ui.py
        （確認が終わったら、enable_test_client を false に戻して apply する）
確認すること:
  - 画面(HTML)が、ログインなしで開け、安全な設定(CSP など)が付いている
  - Cognitoのログイン画面への入口が、正しく登録されている（戻り先の不一致がない）
  - 内容を見るAPIは、ログインがないと拒否され、leads / developers の人だけが読める
  - 台帳には、テスト用のデータを1件入れ、終了時に必ず削除する
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

env = {**os.environ, "AWS_PAGER": "", "AWS_PROFILE": "dev", "AWS_REGION": "ap-northeast-1"}
EVENT_ID = "00000000-0000-5000-8000-0000000000ff"   # 画面の形式(UUID)に合わせた、テスト用のID
TABLE = "kane-drift-events"


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True, env=env, check=True).stdout.strip()


def out(name):
    return sh("terraform", "output", "-raw", name)


try:
    TEST_CLIENT = out("cognito_test_cli_client_id")
except subprocess.CalledProcessError:
    sys.exit("テスト用のCognitoクライアントがありません。terraform.tfvars に enable_test_client = true を書いて apply してください")

UI_URL = out("ui_url")
API_BASE = UI_URL.rsplit("/ui", 1)[0]
POOL = out("cognito_user_pool_id")
PASSWORD = re.search(r'^test_user_password\s*=\s*"(.*)"', open("terraform.tfvars").read(), re.M).group(1)
WEB_CLIENT = next(l.split('"')[1] for l in sh("terraform", "state", "show", "aws_cognito_user_pool_client.web").splitlines()
                  if l.strip().startswith("id "))
acct = sh("aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text")
COGNITO = f"https://kane-drift-{acct}.auth.ap-northeast-1.amazoncognito.com"


def id_token(email):
    return sh("aws", "cognito-idp", "admin-initiate-auth", "--user-pool-id", POOL, "--client-id", TEST_CLIENT,
              "--auth-flow", "ADMIN_USER_PASSWORD_AUTH", "--auth-parameters", f"USERNAME={email},PASSWORD={PASSWORD}",
              "--query", "AuthenticationResult.IdToken", "--output", "text")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def request(url, token=None):
    req = urllib.request.Request(url, headers={"Authorization": token} if token else {})
    try:
        r = urllib.request.build_opener(NoRedirect).open(req)
        return r.status, dict(r.headers), r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode()


results = []


def check(label, ok, detail=""):
    results.append(ok)
    print(f"{'OK  ' if ok else 'NG  '}{label}  {detail}")


def put_event():
    item = {"event_id": {"S": EVENT_ID}, "resource_id": {"S": "sg-00000000test0000"},
            "resource_name": {"S": "テスト用のSG"}, "detected_at": {"S": "2026-11-23T00:00:00Z"},
            "operator": {"S": "tester"}, "operator_arn": {"S": "arn:aws:iam::1:user/tester"},
            "diff": {"S": "🔵 [追加] SSH (ポート:22) | 許可IP: 0.0.0.0/0"}, "status": {"S": "DETECTED"}}
    sh("aws", "dynamodb", "put-item", "--table-name", TABLE, "--item", json.dumps(item))


try:
    put_event()

    print("== 画面（HTML）")
    status, headers, body = request(UI_URL)
    csp = headers.get("Content-Security-Policy", "")
    check("ログインなしで画面が開く", status == 200 and "text/html" in headers.get("Content-Type", ""), f"[{status}]")
    check("CSP: 外への通信は自分とCognitoだけ", "default-src 'none'" in csp and COGNITO in csp)
    check("ログイン後のURLを外に漏らさない", headers.get("Referrer-Policy") == "no-referrer")
    check("設定が埋め込まれ、置き換え忘れがない", "__CONFIG__" not in body and "__NONCE__" not in body and WEB_CLIENT in body)

    print("== Cognitoのログイン画面への入口")
    query = urllib.parse.urlencode({
        "response_type": "code", "client_id": WEB_CLIENT, "redirect_uri": UI_URL, "scope": "openid email profile",
        "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "code_challenge_method": "S256", "state": "x"})
    status, headers, _ = request(f"{COGNITO}/oauth2/authorize?{query}")
    location = headers.get("Location", "")
    check("戻り先が登録されていて、ログイン画面へ進める", status == 302 and "/login" in location, f"[{status}]")
    bad = urllib.parse.urlencode({
        "response_type": "code", "client_id": WEB_CLIENT, "redirect_uri": "https://example.com/evil", "scope": "openid email profile",
        "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "code_challenge_method": "S256", "state": "x"})
    status, headers, _ = request(f"{COGNITO}/oauth2/authorize?{bad}")
    check("登録していない戻り先は、拒否される", not (status == 302 and "/login" in headers.get("Location", "")), f"[{status}]")

    print("== 内容を見るAPI（GET /events/{id}）")
    status, _, _ = request(f"{API_BASE}/events/{EVENT_ID}")
    check("ログインなしは拒否される", status == 401, f"[{status}]")
    for email, label in [("tanaka@example.com", "田中（developers）は読める"), ("suzuki@example.com", "鈴木（leads）は読める")]:
        status, _, text = request(f"{API_BASE}/events/{EVENT_ID}", id_token(email))
        ok = status == 200 and json.loads(text).get("status") == "DETECTED"
        check(label, ok, f"[{status}]")
    status, _, text = request(f"{API_BASE}/events/{EVENT_ID}", id_token("guest@example.com"))
    check("guest（グループなし）は読めない", status == 403, f"[{status}] {text[:60]}")
finally:
    sh("aws", "dynamodb", "delete-item", "--table-name", TABLE, "--key", json.dumps({"event_id": {"S": EVENT_ID}}))

print(f"== 結果: OK {sum(results)} 件 / NG {len(results) - sum(results)} 件（テストデータは削除済み）")
sys.exit(0 if all(results) else 1)
