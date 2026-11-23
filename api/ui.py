import html
import json
import os
import secrets

# 申告・承認の画面(HTML)を返す。画面は、このLambdaが配信する(S3やCloudFrontは使わない)。
# 設定(Cognitoのログイン先など)は、環境変数から、HTMLに埋め込む。

TEMPLATE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'web', 'index.html')


def load_template():
    with open(TEMPLATE_PATH, encoding='utf-8') as f:
        return f.read()


def build_config():
    domain = os.environ['COGNITO_DOMAIN_URL'].rstrip('/')
    redirect_uri = os.environ['REDIRECT_URI']
    return {
        'authorizeUrl': f'{domain}/oauth2/authorize',
        'tokenUrl': f'{domain}/oauth2/token',
        'logoutUrl': f'{domain}/logout',
        'clientId': os.environ['CLIENT_ID'],
        'redirectUri': redirect_uri,
    }


def ui_handler(event, context):
    nonce = secrets.token_urlsafe(16)
    config = build_config()
    body = (load_template()
            .replace('__NONCE__', nonce)
            .replace('__CONFIG__', html.escape(json.dumps(config), quote=True)))

    # 画面の外へは通信しない。許可するのは、自分自身(API)と、Cognitoのログイン先だけ
    cognito_origin = os.environ['COGNITO_DOMAIN_URL'].rstrip('/')
    csp = "; ".join([
        "default-src 'none'",
        f"script-src 'nonce-{nonce}'",
        f"style-src 'nonce-{nonce}'",
        f"connect-src 'self' {cognito_origin}",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'none'",
    ])
    return {
        'statusCode': 200,
        'headers': {
            'Content-Type': 'text/html; charset=utf-8',
            'Content-Security-Policy': csp,
            'X-Content-Type-Options': 'nosniff',
            'Referrer-Policy': 'no-referrer',  # ログイン後のURLの code を、外に漏らさない
            'Cache-Control': 'no-store',
        },
        'body': body,
    }
