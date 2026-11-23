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


if __name__ == '__main__':
    unittest.main()
