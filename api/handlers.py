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


def can_approve(approver_precedence, attester_precedence):
    # 申告者より権限が高い（Precedenceが小さい）人は、承認できる。
    # 例外: 最上位のグループには、その上がいない。そのため、申告者も承認者も最上位のグループなら、
    # 同じ権限でも承認できる（本人かどうかは、呼び出し側で別に確認する）
    if approver_precedence < attester_precedence:
        return True
    table = group_precedence()
    top = min(table.values()) if table else None
    return top is not None and approver_precedence == top and attester_precedence == top


def check_approver(item, approver_email, approver_precedence):
    # 承認できるなら None。できないなら (HTTPコード, 理由)。承認と、画面のボタンの表示で、同じ判定を使う
    if item.get('status') != 'ATTESTED':
        return 409, f"承認できる状態ではありません（状態: {item.get('status')}）"
    if approver_email == item.get('attested_by'):
        return 403, '申告者本人は承認できません'
    attester_precedence = item.get('attester_precedence', -1)
    if attester_precedence == -1:
        return 403, '申告者のグループが不明なため承認できません'
    if not can_approve(approver_precedence, attester_precedence):
        return 403, '申告者より権限が高い人だけが承認できます'
    return None


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
    # 承認: 申告者より権限が高いグループの人が承認できる。本人は承認できない。
    # 最上位のグループだけは、同じ最上位の別の人も承認できる
    claims = get_claims(event)
    approver_email = claims.get('email')
    approver_precedence = best_precedence(get_groups(claims))
    if approver_precedence is None:
        return response(403, {'message': '承認できるグループに入っていません'})

    item, error = get_event_item(event)
    if error:
        return error
    denied = check_approver(item, approver_email, approver_precedence)
    if denied:
        return response(*denied)

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


# 画面に出す項目(申告・承認の判断に必要なものだけ)
EVENT_FIELDS = (
    'event_id', 'resource_id', 'resource_name', 'resource_type', 'detected_at', 'diff',
    'operator', 'operator_arn', 'status', 'reason', 'attested_by', 'attested_at',
    'approved_by', 'approved_at',
)


def viewer_actions(item, claims):
    # ログインした人が、この1件に対してできる操作と、できないときの理由。画面は、これに従ってボタンを出す
    email = claims.get('email')
    status = item.get('status')
    actions = {'email': email, 'can_attest': False, 'can_approve': False, 'note': ''}
    if status == 'DETECTED':
        if claims.get('custom:iam_arn') and claims.get('custom:iam_arn') == item.get('operator_arn'):
            actions['can_attest'] = True
        else:
            actions['note'] = 'この変更を行った本人ではないため、申告できません。'
    elif status == 'ATTESTED':
        if email == item.get('attested_by'):
            actions['note'] = 'あなたが申告しました。承認は、申告者より権限が高い、別の人が行います。'
        else:
            denied = check_approver(item, email, best_precedence(get_groups(claims)))
            if denied is None:
                actions['can_approve'] = True
            else:
                actions['note'] = denied[1] + '。'
    elif status == 'APPROVED':
        actions['note'] = '承認済みです。'
    return actions


def get_event_handler(event, context):
    # 内容の表示: leads か developers のグループの人だけが、1件の内容を読める。読み取り専用
    claims = get_claims(event)
    if best_precedence(get_groups(claims)) is None:
        return response(403, {'message': '内容を見られるグループに入っていません'})

    item, error = get_event_item(event)
    if error:
        return error
    body = {key: item[key] for key in EVENT_FIELDS if key in item}
    body['viewer'] = viewer_actions(item, claims)
    return response(200, body)


LIST_FIELDS = ('event_id', 'resource_id', 'resource_name', 'detected_at', 'status', 'diff')
LIST_LIMIT = 50


def list_events_handler(event, context):
    # 一覧: 新しい順に、最大50件。leads か developers のグループの人だけが読める。読み取り専用
    # 台帳は、研究用で件数が少ないため、全体を読んで並べ替える(件数が増えたら、検索用のインデックスを使う形に変える)
    if best_precedence(get_groups(get_claims(event))) is None:
        return response(403, {'message': '内容を見られるグループに入っていません'})

    items, start_key = [], None
    while True:
        kwargs = {'ProjectionExpression': '#id, resource_id, resource_name, detected_at, #s, diff',
                  'ExpressionAttributeNames': {'#id': 'event_id', '#s': 'status'}}
        if start_key:
            kwargs['ExclusiveStartKey'] = start_key
        result = get_table().scan(**kwargs)
        items.extend(result.get('Items', []))
        start_key = result.get('LastEvaluatedKey')
        if not start_key:
            break

    items.sort(key=lambda i: i.get('detected_at', ''), reverse=True)
    return response(200, {'events': [{k: i[k] for k in LIST_FIELDS if k in i} for i in items[:LIST_LIMIT]]})

