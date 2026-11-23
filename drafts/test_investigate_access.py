"""調査Toolの権限の動作確認（誰が通り、誰が拒否されるか）

使い方: terraform.tfvars に enable_test_client = true を書いて apply したあと、リポジトリのルートで  python3 drafts/test_investigate_access.py
（確認が終わったら、enable_test_client を false に戻して apply する）
確認すること（読み取りだけで、AWSの設定やデータは変更しない）:
  - leads / developers のグループの人は、調査Toolを呼べる
  - どのグループにも入っていない人（guest）は、入口で拒否される
  - drift-handler(2LO)のトークンでは、調査Toolを呼べない
  - 人のトークンでは、通知Toolの入口(通知用Gateway)を呼べない
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import base64

env = {**os.environ, "AWS_PAGER": "", "AWS_PROFILE": "dev", "AWS_REGION": "ap-northeast-1"}
SG = "sg-03ad3594a97fac821"
INVESTIGATE_TOOL = "investigate___investigate_security_group"


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True, env=env, check=True).stdout.strip()


def tf_output(name):
    return sh("terraform", "output", "-raw", name)


def gateway_url(name):
    gid = sh("aws", "bedrock-agentcore-control", "list-gateways", "--query",
             f"items[?name==`{name}`].gatewayId", "--output", "text")
    return sh("aws", "bedrock-agentcore-control", "get-gateway", "--gateway-identifier", gid,
              "--query", "gatewayUrl", "--output", "text")


POOL = tf_output("cognito_user_pool_id")
try:
    TEST_CLIENT = tf_output("cognito_test_cli_client_id")
except subprocess.CalledProcessError:
    sys.exit("テスト用のCognitoクライアントがありません。terraform.tfvars に enable_test_client = true を書いて apply してください")
PASSWORD = re.search(r'^test_user_password\s*=\s*"(.*)"', open("terraform.tfvars").read(), re.M).group(1)
INVESTIGATE_URL = gateway_url("kane-investigate-gateway")
NOTIFY_URL = gateway_url("kane-drift-gateway")


def user_access_token(email):
    # 人のログイン(3LO)の代わりに、テスト専用クライアントでアクセストークンを取る
    return sh("aws", "cognito-idp", "admin-initiate-auth", "--user-pool-id", POOL, "--client-id", TEST_CLIENT,
              "--auth-flow", "ADMIN_USER_PASSWORD_AUTH", "--auth-parameters",
              f"USERNAME={email},PASSWORD={PASSWORD}", "--query", "AuthenticationResult.AccessToken",
              "--output", "text")


def system_access_token():
    # drift-handlerと同じ、2LOのトークン
    cid = next(l.split('"')[1] for l in sh("terraform", "state", "show",
               "aws_cognito_user_pool_client.drift_handler").splitlines() if l.strip().startswith("id "))
    secret = sh("aws", "cognito-idp", "describe-user-pool-client", "--user-pool-id", POOL, "--client-id", cid,
                "--query", "UserPoolClient.ClientSecret", "--output", "text")
    acct = sh("aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text")
    url = f"https://kane-drift-{acct}.auth.ap-northeast-1.amazoncognito.com/oauth2/token"
    basic = base64.b64encode(f"{cid}:{secret}".encode()).decode()
    req = urllib.request.Request(url, data=urllib.parse.urlencode(
        {"grant_type": "client_credentials", "scope": "drift-gateway/notify"}).encode(),
        headers={"Authorization": "Basic " + basic})
    return json.load(urllib.request.urlopen(req))["access_token"]


def call_investigate(url, token):
    body = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": INVESTIGATE_TOOL, "arguments": {"resource_id": SG}}}
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        r = urllib.request.urlopen(req)
        return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


results = []


def succeeded(status, text):
    # 200で、Toolがエラーを返していないこと
    if status != 200:
        return False
    try:
        return not json.loads(text)["result"].get("isError")
    except (ValueError, KeyError, TypeError):
        return False


def check(label, expect_ok, status, text):
    ok = succeeded(status, text) if expect_ok else status in (401, 403)
    results.append(ok)
    print(f"{'OK  ' if ok else 'NG  '}{label:<46}[{status}] {text[:110]}")


print("== 調査用Gateway（人のログイン）")
for email, label in [("tanaka@example.com", "田中（developers）は調査できる"),
                     ("sato@example.com", "佐藤（developers）は調査できる"),
                     ("suzuki@example.com", "鈴木（leads）は調査できる"),
                     ("yamada@example.com", "山田（leads）は調査できる")]:
    check(label, True, *call_investigate(INVESTIGATE_URL, user_access_token(email)))
check("guest（グループなし）は拒否される", False, *call_investigate(INVESTIGATE_URL, user_access_token("guest@example.com")))

print("== 入口の分離")
check("drift-handler(2LO)は調査Toolを呼べない", False, *call_investigate(INVESTIGATE_URL, system_access_token()))
check("人のトークンは通知用Gatewayに入れない", False, *call_investigate(NOTIFY_URL, user_access_token("tanaka@example.com")))

print(f"== 結果: OK {sum(results)} 件 / NG {len(results) - sum(results)} 件")
sys.exit(0 if all(results) else 1)
