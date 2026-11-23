import base64
import json
import os
import time
import urllib.parse
import urllib.request

import boto3

# AgentCore Gateway を呼ぶための部品。
# 流れ: Cognito から 2LO(client credentials)でトークンを取る → そのトークンで Gateway の Tool を呼ぶ

TOKEN_SCOPE = 'drift-gateway/notify'
NOTIFY_TOOL = 'notify___postMessage'  # Gateway上の名前は「対象名___操作名」

# 実行環境が再利用される間は、トークンとシークレットを使い回す(毎回取りにいかない)
_secrets_client = None
_client_secret = None
_token = {'value': None, 'expires_at': 0.0}


class GatewayError(Exception):
    pass


def _get_client_secret():
    # 2LOのクライアントシークレットは、Secrets Managerから取得する(環境変数には置かない)
    global _secrets_client, _client_secret
    if _client_secret is None:
        if _secrets_client is None:
            _secrets_client = boto3.client('secretsmanager')
        _client_secret = _secrets_client.get_secret_value(
            SecretId=os.environ['CLIENT_SECRET_ID'])['SecretString']
    return _client_secret


def get_token():
    now = time.time()
    if _token['value'] and now < _token['expires_at'] - 60:
        return _token['value']

    basic = base64.b64encode(
        f"{os.environ['CLIENT_ID']}:{_get_client_secret()}".encode()).decode()
    request = urllib.request.Request(
        os.environ['TOKEN_URL'],
        data=urllib.parse.urlencode({'grant_type': 'client_credentials', 'scope': TOKEN_SCOPE}).encode(),
        headers={'Authorization': f'Basic {basic}', 'Content-Type': 'application/x-www-form-urlencoded'},
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        body = json.load(response)
    _token['value'] = body['access_token']
    _token['expires_at'] = now + body.get('expires_in', 3600)
    return _token['value']


def call_tool(name, arguments):
    # GatewayのToolを呼び、Toolが返した本文(JSON)を辞書で返す
    request = urllib.request.Request(
        os.environ['GATEWAY_URL'],
        data=json.dumps({
            'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
            'params': {'name': name, 'arguments': arguments},
        }).encode(),
        headers={'Authorization': f'Bearer {get_token()}', 'Content-Type': 'application/json'},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        body = json.load(response)

    result = body.get('result')
    if 'error' in body or not result or result.get('isError'):
        raise GatewayError(f'Gatewayがエラーを返しました: {json.dumps(body, ensure_ascii=False)[:300]}')
    text = result['content'][0]['text']
    try:
        return json.loads(text)
    except ValueError:
        raise GatewayError(f'Toolの返答を読み取れません: {text[:200]}')


def post_slack_message(channel, text):
    # Slackに送れなかったとき(ok=false)も、例外にする
    payload = call_tool(NOTIFY_TOOL, {'channel': channel, 'text': text})
    if not payload.get('ok'):
        raise GatewayError(f"Slackがエラーを返しました: {payload.get('error')}")
    return payload
