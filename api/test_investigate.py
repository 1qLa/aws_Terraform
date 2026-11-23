import os
import unittest
from decimal import Decimal

os.environ.setdefault('GROUP_PRECEDENCE', '{}')

import handlers  # noqa: E402
import investigate  # noqa: E402
from botocore.exceptions import ClientError  # noqa: E402

SG = 'sg-0ae907c5511a2f1bd'


class FakeTable:
    def __init__(self, items):
        self.items = items
        self.kwargs = None

    def query(self, **kwargs):
        self.kwargs = kwargs
        items = [i for i in self.items if i['resource_id'] == kwargs['ExpressionAttributeValues'][':r']]
        items.sort(key=lambda i: i['detected_at'], reverse=not kwargs['ScanIndexForward'])
        return {'Items': items[:kwargs['Limit']]}


class FakeEc2:
    def __init__(self, groups=None, error_code=None):
        self.groups, self.error_code = groups, error_code

    def describe_security_groups(self, GroupIds):
        if self.error_code:
            raise ClientError({'Error': {'Code': self.error_code, 'Message': 'x'}}, 'DescribeSecurityGroups')
        return {'SecurityGroups': self.groups}


ITEMS = [
    {'event_id': 'a', 'resource_id': SG, 'detected_at': '2026-11-01T00:00:00Z', 'attester_precedence': Decimal('20')},
    {'event_id': 'b', 'resource_id': SG, 'detected_at': '2026-11-03T00:00:00Z'},
    {'event_id': 'c', 'resource_id': 'sg-ffffffffffffffff', 'detected_at': '2026-11-02T00:00:00Z'},
]
GROUP = {'GroupName': 'kane-alb-sg', 'IpPermissions': [
    {'IpProtocol': 'tcp', 'FromPort': 22, 'ToPort': 22, 'IpRanges': [{'CidrIp': '0.0.0.0/0'}]}]}


class InvestigateTest(unittest.TestCase):
    def setUp(self):
        self.table = FakeTable(ITEMS)
        handlers._table = self.table
        investigate._ec2 = FakeEc2([GROUP])

    def test_履歴は新しい順で同じSGだけ返る(self):
        r = investigate.investigate_handler({'resource_id': SG}, None)
        self.assertEqual([h['event_id'] for h in r['history']], ['b', 'a'])
        self.assertFalse(self.table.kwargs['ScanIndexForward'])

    def test_現在の設定を返す(self):
        r = investigate.investigate_handler({'resource_id': SG}, None)
        rule = r['current_config']['inbound_rules'][0]
        self.assertEqual((rule['from_port'], rule['cidrs']), (22, ['0.0.0.0/0']))

    def test_数値はJSONで返せる形になる(self):
        r = investigate.investigate_handler({'resource_id': SG}, None)
        self.assertEqual(r['history'][1]['attester_precedence'], 20)
        self.assertIsInstance(r['history'][1]['attester_precedence'], int)

    def test_件数は上限に収める(self):
        investigate.investigate_handler({'resource_id': SG, 'limit': 999}, None)
        self.assertEqual(self.table.kwargs['Limit'], investigate.MAX_LIMIT)
        investigate.investigate_handler({'resource_id': SG, 'limit': 0}, None)
        self.assertEqual(self.table.kwargs['Limit'], 1)

    def test_SG_IDの形でなければ拒否(self):
        for bad in ['', 'i-123', "sg-1' OR 1=1", None]:
            r = investigate.investigate_handler({'resource_id': bad}, None)
            self.assertIn('error', r)

    def test_limitが数値でなければ拒否(self):
        r = investigate.investigate_handler({'resource_id': SG, 'limit': 'abc'}, None)
        self.assertIn('error', r)

    def test_削除済みSGは現在の設定がNone(self):
        investigate._ec2 = FakeEc2(error_code='InvalidGroup.NotFound')
        r = investigate.investigate_handler({'resource_id': SG}, None)
        self.assertIsNone(r['current_config'])
        self.assertEqual(len(r['history']), 2)

    def test_その他のEC2エラーはそのまま投げる(self):
        investigate._ec2 = FakeEc2(error_code='UnauthorizedOperation')
        with self.assertRaises(ClientError):
            investigate.investigate_handler({'resource_id': SG}, None)


if __name__ == '__main__':
    unittest.main()
