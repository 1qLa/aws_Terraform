import json
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

# 台帳（DynamoDB）。テストでは差し替える
_table = None


def get_table():
    global _table
    if _table is None:
        _table = boto3.resource('dynamodb').Table(os.environ['DRIFT_TABLE_NAME'])
    return _table


def group_precedence():
    # グループ名とPrecedenceの対応表（例: {"leads": 10, "developers": 20}）。Terraformから環境変数で渡す
    return json.loads(os.environ.get('GROUP_PRECEDENCE', '{}'))


def response(status, body):
    return {
        'statusCode': status,
        'headers': {'Content-Type': 'application/json'},
        'body': json.dumps(body, ensure_ascii=False),
    }


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def get_claims(event):
    # API GatewayのCognito認可が検証済みのトークンの中身（ログインした人の情報）
    return event.get('requestContext', {}).get('authorizer', {}).get('claims', {})


def get_groups(claims):
    # cognito:groups は、1つなら文字列、複数なら "[a b]" の形で届くことがある
    raw = claims.get('cognito:groups', '')
    if isinstance(raw, list):
        return raw
    return [g for g in raw.strip('[]').replace(',', ' ').split() if g]


def best_precedence(groups):
    # 所属グループのうち、いちばん権限が高い（Precedenceが小さい）値。グループがなければ None
    table = group_precedence()
    values = [table[g] for g in groups if g in table]
    return min(values) if values else None


def get_event_item(event):
    event_id = (event.get('pathParameters') or {}).get('event_id')
    if not event_id:
        return None, response(400, {'message': 'event_id がありません'})
    item = get_table().get_item(Key={'event_id': event_id}).get('Item')
    if not item:
        return None, response(404, {'message': '該当するドリフトがありません'})
    return item, None


def attest_handler(event, context):
    # 申告: ログインした人が、実際に変更した人と一致するときだけ、理由を記録する
    claims = get_claims(event)
    login_arn = claims.get('custom:iam_arn')
    login_email = claims.get('email')
    if not login_arn:
        return response(403, {'message': 'ログイン情報に iam_arn がありません'})

    item, error = get_event_item(event)
    if error:
        return error
    if item.get('status') != 'DETECTED':
        return response(409, {'message': f"すでに申告済みです（状態: {item.get('status')}）"})
    if login_arn != item.get('operator_arn'):
        return response(403, {'message': 'ログインした人が、変更した人と一致しません'})

    reason = json.loads(event.get('body') or '{}').get('reason', '').strip()
    if not reason:
        return response(400, {'message': '理由を入力してください'})

    precedence = best_precedence(get_groups(claims))
    try:
        # 同時に2回申告されても、先の1件だけが通る
        get_table().update_item(
            Key={'event_id': item['event_id']},
            UpdateExpression='SET #s = :new, reason = :r, attested_by = :by, '
                             'attester_precedence = :p, attested_at = :t',
            ConditionExpression='#s = :old',
            ExpressionAttributeNames={'#s': 'status'},
            ExpressionAttributeValues={
                ':new': 'ATTESTED', ':old': 'DETECTED', ':r': reason,
                ':by': login_email, ':p': precedence if precedence is not None else -1,
                ':t': now(),
            },
        )
    except ClientError as e:
        if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
            return response(409, {'message': 'すでに申告済みです'})
        raise
    return response(200, {'message': '申告を記録しました'})


def approve_handler(event, context):
    # 承認: 申告者より権限が高いグループの人だけが承認できる。同じ権限の人や本人は承認できない
    claims = get_claims(event)
    approver_email = claims.get('email')
    approver_precedence = best_precedence(get_groups(claims))
    if approver_precedence is None:
        return response(403, {'message': '承認できるグループに入っていません'})

    item, error = get_event_item(event)
    if error:
        return error
    if item.get('status') != 'ATTESTED':
        return response(409, {'message': f"承認できる状態ではありません（状態: {item.get('status')}）"})
    if approver_email == item.get('attested_by'):
        return response(403, {'message': '申告者本人は承認できません'})

    attester_precedence = item.get('attester_precedence', -1)
    if attester_precedence == -1:
        return response(403, {'message': '申告者のグループが不明なため承認できません'})
    if not approver_precedence < attester_precedence:
        return response(403, {'message': '申告者より権限が高い人だけが承認できます'})

    try:
        get_table().update_item(
            Key={'event_id': item['event_id']},
            UpdateExpression='SET #s = :new, approved_by = :by, approved_at = :t',
            ConditionExpression='#s = :old',
            ExpressionAttributeNames={'#s': 'status'},
            ExpressionAttributeValues={
                ':new': 'APPROVED', ':old': 'ATTESTED', ':by': approver_email, ':t': now(),
            },
        )
    except ClientError as e:
        if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
            return response(409, {'message': 'すでに承認済みです'})
        raise
    return response(200, {'message': '承認を記録しました'})
