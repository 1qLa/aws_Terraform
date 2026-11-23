import io
import json
import os
import unittest
from unittest import mock

os.environ.update(CLIENT_ID='cid', CLIENT_SECRET_ID='sid', TOKEN_URL='https://token.example/oauth2/token',
                  GATEWAY_URL='https://gw.example/mcp')

import gateway_client as gc  # noqa: E402


def fake_response(body):
    return io.BytesIO(json.dumps(body).encode())


class FakeSecrets:
    calls = 0

    def get_secret_value(self, SecretId):
        FakeSecrets.calls += 1
        return {'SecretString': 'the-secret'}


class Base(unittest.TestCase):
    def setUp(self):
        gc._secrets_client, gc._client_secret = FakeSecrets(), None
        gc._token.update(value=None, expires_at=0.0)
        FakeSecrets.calls = 0
        self.requests = []

    def urlopen(self, responses):
        # 呼ばれたリクエストを記録し、決まった順に返事を返す
        it = iter(responses)

        def fake(request, timeout=None):
            self.requests.append(request)
            return fake_response(next(it))
        return mock.patch('gateway_client.urllib.request.urlopen', fake)


class TokenTest(Base):
    def test_トークンを取得して使い回す(self):
        with self.urlopen([{'access_token': 'tok', 'expires_in': 3600}]):
            self.assertEqual(gc.get_token(), 'tok')
            self.assertEqual(gc.get_token(), 'tok')
        self.assertEqual(len(self.requests), 1)  # 2回目は取りにいかない
        self.assertEqual(FakeSecrets.calls, 1)

    def test_期限が近いトークンは取り直す(self):
        with self.urlopen([{'access_token': 'a', 'expires_in': 30}, {'access_token': 'b', 'expires_in': 3600}]):
            self.assertEqual(gc.get_token(), 'a')
            self.assertEqual(gc.get_token(), 'b')

    def test_シークレットはBasic認証で送る(self):
        with self.urlopen([{'access_token': 'tok', 'expires_in': 3600}]):
            gc.get_token()
        self.assertTrue(self.requests[0].get_header('Authorization').startswith('Basic '))
        self.assertIn(b'client_credentials', self.requests[0].data)


class NotifyTest(Base):
    def tool_response(self, payload, is_error=False):
        return {'jsonrpc': '2.0', 'id': 1, 'result': {'isError': is_error,
                                                       'content': [{'type': 'text', 'text': json.dumps(payload)}]}}

    def test_Slackに送れる(self):
        with self.urlopen([{'access_token': 't', 'expires_in': 3600}, self.tool_response({'ok': True, 'ts': '1'})]):
            result = gc.post_slack_message('C1', 'こんにちは')
        self.assertTrue(result['ok'])
        sent = json.loads(self.requests[1].data)
        self.assertEqual(sent['params']['name'], 'notify___postMessage')
        self.assertEqual(sent['params']['arguments'], {'channel': 'C1', 'text': 'こんにちは'})
        self.assertEqual(self.requests[1].get_header('Authorization'), 'Bearer t')

    def test_Slackがエラーなら例外(self):
        with self.urlopen([{'access_token': 't', 'expires_in': 3600},
                           self.tool_response({'ok': False, 'error': 'channel_not_found'})]):
            with self.assertRaisesRegex(gc.GatewayError, 'channel_not_found'):
                gc.post_slack_message('C1', 'x')

    def test_Gatewayがエラーなら例外(self):
        with self.urlopen([{'access_token': 't', 'expires_in': 3600}, self.tool_response({}, is_error=True)]):
            with self.assertRaises(gc.GatewayError):
                gc.post_slack_message('C1', 'x')


if __name__ == '__main__':
    unittest.main()
