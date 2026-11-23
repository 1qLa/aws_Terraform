import json
import os
import unittest

os.environ['GROUP_PRECEDENCE'] = json.dumps({'leads': 10, 'developers': 20})

import handlers  # noqa: E402

TANAKA_ARN = 'arn:aws:iam::1:user/tanaka'


class FakeTable:
    def __init__(self, item):
        self.item = item

    def get_item(self, Key):
        return {'Item': self.item} if self.item and self.item['event_id'] == Key['event_id'] else {}

    def update_item(self, Key, UpdateExpression, ConditionExpression, ExpressionAttributeNames, ExpressionAttributeValues):
        v = ExpressionAttributeValues
        assert self.item['status'] == v[':old']
        self.item['status'] = v[':new']
        if v[':new'] == 'ATTESTED':
            self.item.update(reason=v[':r'], attested_by=v[':by'], attester_precedence=v[':p'])
        else:
            self.item.update(approved_by=v[':by'])


def req(email, groups, arn=None, body=None):
    claims = {'email': email, 'cognito:groups': groups}
    if arn:
        claims['custom:iam_arn'] = arn
    return {'requestContext': {'authorizer': {'claims': claims}},
            'pathParameters': {'event_id': 'e1'}, 'body': json.dumps(body or {})}


class Base(unittest.TestCase):
    def setUp(self):
        self.item = {'event_id': 'e1', 'status': 'DETECTED', 'operator_arn': TANAKA_ARN}
        handlers._table = FakeTable(self.item)


class AttestTest(Base):
    def test_本人は申告できる(self):
        r = handlers.attest_handler(req('tanaka@x', 'developers', TANAKA_ARN, {'reason': '検証'}), None)
        self.assertEqual(r['statusCode'], 200)
        self.assertEqual(self.item['status'], 'ATTESTED')
        self.assertEqual(self.item['attester_precedence'], 20)

    def test_本人以外は申告できない(self):
        r = handlers.attest_handler(req('sato@x', 'developers', 'arn:aws:iam::1:user/sato', {'reason': 'x'}), None)
        self.assertEqual(r['statusCode'], 403)
        self.assertEqual(self.item['status'], 'DETECTED')

    def test_理由が空なら拒否(self):
        r = handlers.attest_handler(req('tanaka@x', 'developers', TANAKA_ARN, {'reason': ' '}), None)
        self.assertEqual(r['statusCode'], 400)

    def test_申告済みは再申告できない(self):
        self.item['status'] = 'ATTESTED'
        r = handlers.attest_handler(req('tanaka@x', 'developers', TANAKA_ARN, {'reason': 'x'}), None)
        self.assertEqual(r['statusCode'], 409)


class ApproveTest(Base):
    def setUp(self):
        super().setUp()
        self.item.update(status='ATTESTED', attested_by='tanaka@x', attester_precedence=20)

    def test_上位の人は承認できる(self):
        r = handlers.approve_handler(req('suzuki@x', 'leads'), None)
        self.assertEqual(r['statusCode'], 200)
        self.assertEqual(self.item['status'], 'APPROVED')
        self.assertEqual(self.item['approved_by'], 'suzuki@x')

    def test_同じ権限の人は承認できない(self):
        r = handlers.approve_handler(req('sato@x', 'developers'), None)
        self.assertEqual(r['statusCode'], 403)
        self.assertEqual(self.item['status'], 'ATTESTED')

    def test_申告者本人は承認できない(self):
        # 本人が上位グループにも入っていても、承認できない
        r = handlers.approve_handler(req('tanaka@x', '[leads developers]'), None)
        self.assertEqual(r['statusCode'], 403)

    def test_グループなしは承認できない(self):
        r = handlers.approve_handler(req('x@x', ''), None)
        self.assertEqual(r['statusCode'], 403)

    def test_未申告は承認できない(self):
        self.item['status'] = 'DETECTED'
        r = handlers.approve_handler(req('suzuki@x', 'leads'), None)
        self.assertEqual(r['statusCode'], 409)


class TopGroupApproveTest(Base):
    # 最上位のグループ（leads）の人が申告したとき
    def setUp(self):
        super().setUp()
        self.item.update(status='ATTESTED', attested_by='suzuki@x', attester_precedence=10)

    def test_最上位の別の人は承認できる(self):
        r = handlers.approve_handler(req('yamada@x', 'leads'), None)
        self.assertEqual(r['statusCode'], 200)
        self.assertEqual(self.item['approved_by'], 'yamada@x')

    def test_最上位でも申告者本人は承認できない(self):
        r = handlers.approve_handler(req('suzuki@x', 'leads'), None)
        self.assertEqual(r['statusCode'], 403)
        self.assertEqual(self.item['status'], 'ATTESTED')

    def test_下位の人は承認できない(self):
        r = handlers.approve_handler(req('tanaka@x', 'developers'), None)
        self.assertEqual(r['statusCode'], 403)

    def test_最上位以外の同じ権限は承認できない(self):
        # developers（20）の申告は、同じ developers の人が承認できない
        self.item.update(attested_by='tanaka@x', attester_precedence=20)
        r = handlers.approve_handler(req('sato@x', 'developers'), None)
        self.assertEqual(r['statusCode'], 403)


class GetEventTest(Base):
    def setUp(self):
        super().setUp()
        self.item.update(status='ATTESTED', resource_id='sg-1', resource_name='kane-bastion-sg', diff='追加',
                         reason='確認', attested_by='tanaka@x', attester_precedence=20, secret_note='見せない')

    def test_グループの人は内容を読める(self):
        r = handlers.get_event_handler(req('sato@x', 'developers'), None)
        self.assertEqual(r['statusCode'], 200)
        body = json.loads(r['body'])
        self.assertEqual((body['status'], body['resource_name'], body['reason']), ('ATTESTED', 'kane-bastion-sg', '確認'))

    def test_画面に出さない項目は返さない(self):
        body = json.loads(handlers.get_event_handler(req('sato@x', 'developers'), None)['body'])
        self.assertNotIn('secret_note', body)
        self.assertNotIn('attester_precedence', body)

    def test_グループなしは読めない(self):
        r = handlers.get_event_handler(req('guest@x', ''), None)
        self.assertEqual(r['statusCode'], 403)

    def test_存在しないIDは404(self):
        event = req('sato@x', 'developers'); event['pathParameters'] = {'event_id': 'nothing'}
        self.assertEqual(handlers.get_event_handler(event, None)['statusCode'], 404)


class ViewerActionsTest(Base):
    def viewer(self, email, groups, arn=None):
        r = handlers.get_event_handler(req(email, groups, arn), None)
        self.assertEqual(r['statusCode'], 200)
        return json.loads(r['body'])['viewer']

    def test_変更した本人は申告できる(self):
        v = self.viewer('tanaka@x', 'developers', TANAKA_ARN)
        self.assertTrue(v['can_attest'])
        self.assertFalse(v['can_approve'])

    def test_本人以外は申告できない理由が出る(self):
        v = self.viewer('sato@x', 'developers', 'arn:aws:iam::1:user/sato')
        self.assertFalse(v['can_attest'])
        self.assertIn('本人ではない', v['note'])

    def test_申告した本人は承認できずそのことが分かる(self):
        self.item.update(status='ATTESTED', attested_by='tanaka@x', attester_precedence=20, reason='確認')
        v = self.viewer('tanaka@x', '[leads developers]', TANAKA_ARN)
        self.assertFalse(v['can_approve'])
        self.assertIn('あなたが申告しました', v['note'])

    def test_上位の人は承認できる(self):
        self.item.update(status='ATTESTED', attested_by='tanaka@x', attester_precedence=20)
        self.assertTrue(self.viewer('suzuki@x', 'leads')['can_approve'])

    def test_同じ権限の人は承認できず理由が出る(self):
        self.item.update(status='ATTESTED', attested_by='tanaka@x', attester_precedence=20)
        v = self.viewer('sato@x', 'developers')
        self.assertFalse(v['can_approve'])
        self.assertIn('権限が高い人だけ', v['note'])

    def test_最上位の申告は最上位の別の人が承認できる(self):
        self.item.update(status='ATTESTED', attested_by='suzuki@x', attester_precedence=10)
        self.assertTrue(self.viewer('yamada@x', 'leads')['can_approve'])
        self.assertFalse(self.viewer('suzuki@x', 'leads')['can_approve'])

    def test_画面の判定と承認APIの判定が一致する(self):
        # 画面でボタンが出る人は、承認APIでも通り、出ない人は、承認APIでも拒否される
        self.item.update(status='ATTESTED', attested_by='tanaka@x', attester_precedence=20)
        for email, groups in [('suzuki@x', 'leads'), ('sato@x', 'developers'), ('tanaka@x', '[leads developers]')]:
            shown = self.viewer(email, groups)['can_approve']
            self.item.update(status='ATTESTED')
            allowed = handlers.approve_handler(req(email, groups), None)['statusCode'] == 200
            self.assertEqual(shown, allowed, email)
            self.item.update(status='ATTESTED')

    def test_承認済みは操作できない(self):
        self.item.update(status='APPROVED')
        v = self.viewer('suzuki@x', 'leads')
        self.assertFalse(v['can_attest'] or v['can_approve'])


class FakeScanTable:
    # 一覧用の台帳。2回に分けて返し、続きの読み取りも確かめる
    def __init__(self, items):
        self.items = items
        self.calls = 0

    def scan(self, **kwargs):
        self.calls += 1
        if 'ExclusiveStartKey' in kwargs:
            return {'Items': self.items[2:]}
        return {'Items': self.items[:2], 'LastEvaluatedKey': {'event_id': 'next'}}


class ListEventsTest(unittest.TestCase):
    def setUp(self):
        self.table = FakeScanTable([
            {'event_id': 'a', 'resource_id': 'sg-1', 'detected_at': '2026-11-01T00:00:00Z', 'status': 'APPROVED'},
            {'event_id': 'c', 'resource_id': 'sg-1', 'detected_at': '2026-11-03T00:00:00Z', 'status': 'DETECTED'},
            {'event_id': 'b', 'resource_id': 'sg-2', 'detected_at': '2026-11-02T00:00:00Z', 'status': 'ATTESTED'},
        ])
        handlers._table = self.table

    def test_新しい順に返す(self):
        r = handlers.list_events_handler(req('sato@x', 'developers'), None)
        self.assertEqual(r['statusCode'], 200)
        self.assertEqual([e['event_id'] for e in json.loads(r['body'])['events']], ['c', 'b', 'a'])

    def test_続きがあれば全部読む(self):
        handlers.list_events_handler(req('sato@x', 'developers'), None)
        self.assertEqual(self.table.calls, 2)

    def test_グループなしは読めない(self):
        self.assertEqual(handlers.list_events_handler(req('guest@x', ''), None)['statusCode'], 403)
        self.assertEqual(self.table.calls, 0)

    def test_件数は50件までに収める(self):
        self.table.items = [{'event_id': f'e{i:03d}', 'detected_at': f'2026-11-01T00:{i // 60:02d}:{i % 60:02d}Z',
                             'status': 'DETECTED'} for i in range(120)]
        events = json.loads(handlers.list_events_handler(req('sato@x', 'developers'), None)['body'])['events']
        self.assertEqual(len(events), handlers.LIST_LIMIT)


if __name__ == '__main__':
    unittest.main()
