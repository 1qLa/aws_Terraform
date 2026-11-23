import re
from decimal import Decimal

import boto3
from botocore.exceptions import ClientError

from handlers import get_table

INDEX_NAME = 'resource_id-detected_at-index'  # dynamodb.tf のGSI名と合わせる
SG_ID_PATTERN = re.compile(r'^sg-[0-9a-f]{8,17}$')
DEFAULT_LIMIT = 10
MAX_LIMIT = 50

# EC2のクライアント。テストでは差し替える
_ec2 = None


def get_ec2():
    global _ec2
    if _ec2 is None:
        _ec2 = boto3.client('ec2')
    return _ec2


def to_plain(value):
    # DynamoDBの数値（Decimal）を、JSONで返せる形に直す
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    if isinstance(value, dict):
        return {k: to_plain(v) for k, v in value.items()}
    if isinstance(value, list):
        return [to_plain(v) for v in value]
    return value


def get_history(resource_id, limit):
    # 同じSGのドリフト履歴を、新しい順に取り出す
    result = get_table().query(
        IndexName=INDEX_NAME,
        KeyConditionExpression='resource_id = :r',
        ExpressionAttributeValues={':r': resource_id},
        ScanIndexForward=False,  # 検知日時の降順（新しい順）
        Limit=limit,
    )
    return [to_plain(item) for item in result.get('Items', [])]


def get_current_config(resource_id):
    # EC2のAPIで、いまのSGの設定を照会する。SGがなければ None
    try:
        groups = get_ec2().describe_security_groups(GroupIds=[resource_id])['SecurityGroups']
    except ClientError as e:
        if e.response['Error']['Code'] == 'InvalidGroup.NotFound':
            return None
        raise
    if not groups:
        return None
    group = groups[0]
    return {
        'group_name': group.get('GroupName'),
        'inbound_rules': [
            {
                'protocol': p.get('IpProtocol'),
                'from_port': p.get('FromPort'),
                'to_port': p.get('ToPort'),
                'cidrs': [r.get('CidrIp') for r in p.get('IpRanges', [])],
            }
            for p in group.get('IpPermissions', [])
        ],
    }


def investigate_handler(event, context):
    # AgentCore Gateway の Tool として呼ばれる。入力: {"resource_id": "sg-...", "limit": 10}
    resource_id = event.get('resource_id', '')
    if not SG_ID_PATTERN.match(str(resource_id)):
        return {'error': 'resource_id には sg- で始まるセキュリティグループIDを指定してください'}

    try:
        limit = int(event.get('limit', DEFAULT_LIMIT))
    except (TypeError, ValueError):
        return {'error': 'limit は数値で指定してください'}
    limit = max(1, min(limit, MAX_LIMIT))

    return {
        'resource_id': resource_id,
        'history': get_history(resource_id, limit),
        'current_config': get_current_config(resource_id),
    }
