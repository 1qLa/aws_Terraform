import json
import os
import unittest
from unittest import mock

os.environ.update(AWS_DEFAULT_REGION='ap-northeast-1', AWS_ACCESS_KEY_ID='x', AWS_SECRET_ACCESS_KEY='x',
                  DRIFT_TABLE_NAME='t', SLACK_CHANNEL_ID='C1', APPROVAL_API_URL='https://api.example/v1',
                  CLIENT_ID='c', CLIENT_SECRET_ID='s', TOKEN_URL='https://t', GATEWAY_URL='https://g')

import app  # noqa: E402
from botocore.exceptions import ClientError  # noqa: E402

ARN = 'arn:aws:iam::1:user/tanaka'


def sqs_event(message_id='m-1'):
    config_event = {
        'time': '2026-11-23T01:00:00Z',
        'detail': {'configurationItem': {'resourceId': 'sg-0123456789abcdef0',
                                         'resourceType': 'AWS::EC2::SecurityGroup'},
                   'configurationItemDiff': {'changedProperties': {}}},
    }
    return {'Records': [{'messageId': message_id, 'body': json.dumps({'Message': json.dumps(config_event)})}]}


class HandlerTest(unittest.TestCase):
    def setUp(self):
        self.table = mock.Mock()
        self.sent = []
        patches = [
            mock.patch.object(app, 'drift_table', self.table),
            mock.patch.object(app, 'get_sg_name', return_value='kane-alb-sg'),
            mock.patch.object(app.cloudtrail, 'lookup_events', return_value={'Events': [{
                'Username': 'tanaka', 'CloudTrailEvent': json.dumps({'userIdentity': {'arn': ARN}})}]}),
            mock.patch.object(app.gateway_client, 'post_slack_message',
                              side_effect=lambda ch, text: self.sent.append((ch, text))),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def test_台帳に記録してからGateway経由で通知する(self):
        app.lambda_handler(sqs_event(), None)
        item = self.table.put_item.call_args.kwargs['Item']
        self.assertEqual((item['operator_arn'], item['status'], item['resource_id']),
                         (ARN, 'DETECTED', 'sg-0123456789abcdef0'))
        channel, text = self.sent[0]
        self.assertEqual(channel, 'C1')
        self.assertIn(item['event_id'], text)
        self.assertIn(f"POST https://api.example/v1/attest/{item['event_id']}", text)
        self.assertIn(f"POST https://api.example/v1/approve/{item['event_id']}", text)

    def test_再配信されても同じevent_idになる(self):
        app.lambda_handler(sqs_event('m-1'), None)
        app.lambda_handler(sqs_event('m-1'), None)
        ids = [c.kwargs['Item']['event_id'] for c in self.table.put_item.call_args_list]
        self.assertEqual(ids[0], ids[1])
        app.lambda_handler(sqs_event('m-2'), None)
        self.assertNotEqual(ids[0], self.table.put_item.call_args.kwargs['Item']['event_id'])

    def test_既に記録がある場合は上書きせず通知は続ける(self):
        self.table.put_item.side_effect = ClientError(
            {'Error': {'Code': 'ConditionalCheckFailedException', 'Message': 'x'}}, 'PutItem')
        app.lambda_handler(sqs_event(), None)
        self.assertEqual(len(self.sent), 1)
        self.assertIn('attribute_not_exists', self.table.put_item.call_args.kwargs['ConditionExpression'])

    def test_台帳への記録に失敗しても通知は送る(self):
        self.table.put_item.side_effect = RuntimeError('dynamodb down')
        app.lambda_handler(sqs_event(), None)
        self.assertEqual(len(self.sent), 1)

    def test_通知に失敗したら例外にして再配信させる(self):
        app.gateway_client.post_slack_message.side_effect = app.gateway_client.GatewayError('x')
        with self.assertRaises(app.gateway_client.GatewayError):
            app.lambda_handler(sqs_event(), None)


if __name__ == '__main__':
    unittest.main()
