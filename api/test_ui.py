import os
import re
import unittest

os.environ.setdefault('GROUP_PRECEDENCE', '{}')  # 他のテストの設定を上書きしない
os.environ.update(COGNITO_DOMAIN_URL='https://login.example.com/', CLIENT_ID='client-123',
                  REDIRECT_URI='https://api.example.com/v1/ui')

import ui  # noqa: E402


class UiTest(unittest.TestCase):
    def setUp(self):
        self.response = ui.ui_handler({}, None)
        self.headers = self.response['headers']
        self.body = self.response['body']

    def test_HTMLを返す(self):
        self.assertEqual(self.response['statusCode'], 200)
        self.assertIn('text/html', self.headers['Content-Type'])
        self.assertIn('申告・承認', self.body)

    def test_設定が埋め込まれて置き換え忘れがない(self):
        self.assertIn('client-123', self.body)
        self.assertIn('https://login.example.com/oauth2/authorize', self.body)
        self.assertNotIn('__CONFIG__', self.body)
        self.assertNotIn('__NONCE__', self.body)

    def test_CSPのnonceがスクリプトとスタイルに付く(self):
        nonce = re.search(r"script-src 'nonce-([^']+)'", self.headers['Content-Security-Policy']).group(1)
        self.assertIn(f'<script nonce="{nonce}">', self.body)
        self.assertIn(f'<style nonce="{nonce}">', self.body)

    def test_リクエストごとにnonceが変わる(self):
        other = ui.ui_handler({}, None)['headers']['Content-Security-Policy']
        self.assertNotEqual(self.headers['Content-Security-Policy'], other)

    def test_外部への通信は自分とCognitoだけに限る(self):
        csp = self.headers['Content-Security-Policy']
        self.assertIn("default-src 'none'", csp)
        self.assertIn("connect-src 'self' https://login.example.com", csp)
        self.assertIn("frame-ancestors 'none'", csp)

    def test_ログイン後のURLを外に漏らさない設定(self):
        self.assertEqual(self.headers['Referrer-Policy'], 'no-referrer')
        self.assertEqual(self.headers['Cache-Control'], 'no-store')

    def test_画面のコードは外から来た文字をHTMLとして扱わない(self):
        # 検知の内容や理由は、外から来た文字。textContent で入れる決まりにして、HTMLとして解釈する書き方を使わない
        template = ui.load_template()
        for forbidden in ('innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(', 'new Function'):
            self.assertNotIn(forbidden, template)

    def test_ボタンはサーバーの判定に従って出す(self):
        # 申告者本人に、承認のボタンを出さないため。画面が自分で判断せず、サーバーが返した viewer を使う
        template = ui.load_template()
        for needle in ("v.can_attest", "v.can_approve", "item.viewer", "mine-reason"):
            self.assertIn(needle, template)
        self.assertNotIn("item.status === 'ATTESTED'", template)

    def test_ログインでprofileスコープを要求する(self):
        # profile がないと、IDトークンに custom:iam_arn が入らず、申告の本人確認ができない
        self.assertIn("scope: 'openid email profile'", ui.load_template())

    def test_設定の値にHTMLの記号があっても属性を壊さない(self):
        os.environ['CLIENT_ID'] = 'a"><script>alert(1)</script>'
        try:
            body = ui.ui_handler({}, None)['body']
        finally:
            os.environ['CLIENT_ID'] = 'client-123'
        self.assertNotIn('<script>alert(1)</script>', body)


if __name__ == '__main__':
    unittest.main()
