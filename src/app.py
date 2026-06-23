import json
import os
import urllib.request
import boto3
from datetime import datetime, timedelta

# 環境変数からSlackのURLを取得
slack_url = os.environ['SLACK_WEBHOOK_URL']

# CloudTrailを検索するためのクライアントを準備
cloudtrail = boto3.client('cloudtrail')
ec2_client = boto3.client('ec2') # SGの名前を取得するためのEC2クライアント

# よく使われるポートとプロトコル名の対応表
PORT_NAMES = {
    22: "SSH",
    80: "HTTP",
    443: "HTTPS",
    3306: "MySQL / Aurora",
    5432: "PostgreSQL",
    6379: "Redis",
    8080: "カスタムWeb (8080)",
    -1: "すべて許可" # セキュリティグループで -1 は「すべて」を意味します
}

def get_port_name(port_num):
    # ポート番号（数値や文字列）を受け取り、対応する名前があれば返す関数
    # なければそのままの番号を返す
    try:
        port_int = int(float(port_num)) # "22.0" のような文字が来ても安全に整数に変換
        return PORT_NAMES.get(port_int, str(port_int))
    except (ValueError, TypeError):
        return str(port_num)
    
def get_sg_name(sg_id):
    """
    セキュリティグループIDから、そのSGの名前(GroupName)を取得する関数
    """
    try:
        response = ec2_client.describe_security_groups(GroupIds=[sg_id])
        if response['SecurityGroups']:
            return response['SecurityGroups'][0].get('GroupName', 'Unknown')
    except Exception as e:
        print(f"SG名の取得エラー ({sg_id}): {e}")
    return "Unknown"    

# Configの複雑なDiff（差分）JSONから、ポート番号やIPアドレスを分かりやすい日本語に翻訳する関数
def parse_sg_diff(diff_data):
    # 変更されたプロパティを取得
    changed_props = diff_data.get('changedProperties', {})

    # 変更内容を格納するリスト
    diff_messages = []

    for key, value in changed_props.items():
        # インバウンドルール（IpPermissions）の変更を検知
        if 'IpPermissions' in key:
            change_type = value.get('changeType', 'UNKNOWN')
            
            # 追加・変更の場合は updatedValue、削除の場合は previousValue を見る
            target_data = value.get('updatedValue') if change_type in ['CREATE', 'UPDATE'] else value.get('previousValue')
            
            # ルールの詳細を抽出
            if isinstance(target_data, dict):
                from_port = target_data.get('fromPort', 'All')
                to_port = target_data.get('toPort', 'All')
                protocol = target_data.get('ipProtocol', 'All')
                
                # ここで関数を呼び出して、ポート番号を名前に変換
                from_port_name = get_port_name(from_port)
                to_port_name = get_port_name(to_port)
                
                # 表示の調整（22-22なら "SSH(22)"、範囲なら "8000-9000" のようにする）
                if from_port == to_port:
                    port_display = f"{from_port_name} (ポート:{from_port})" if from_port_name != str(from_port) else f"ポート:{from_port}"
                else:
                    port_display = f"ポート:{from_port}〜{to_port}"

                # IPアドレス(CIDR)の抽出
                ip_ranges = [r.get('cidrIp') for r in target_data.get('ipv4Ranges', [])]
                ip_str = ", ".join(ip_ranges) if ip_ranges else "特定のIPなし"
                
                # 絵文字で視覚的にわかりやすく
                icon = "🔵 [追加]" if change_type == 'CREATE' else "🔴 [削除]" if change_type == 'DELETE' else "🟡 [変更]"
                
                diff_messages.append(f"{icon} {port_display} (プロトコル: {protocol}) | 許可IP: {ip_str}")
        
        # タグが変更された場合の処理（おまけ）
        elif 'Tags' in key:
            diff_messages.append("🏷️ [変更] セキュリティグループのタグが更新されました")

    if not diff_messages:
        return "  詳細な差分データなし"
    
    return "\n  ".join(diff_messages)

def lambda_handler(event, context):
    for record in event['Records']:
        # SQS → SNS → EventBridge の順でイベントが流れてくるため、SNSのMessage部分を取り出す
        sns_message = json.loads(record['body'])['Message']
        config_event = json.loads(sns_message)

        # Configから変更されたリソースと時間を抽出
        detail = config_event.get('detail', {})
        config_item = detail.get('configurationItem', {})
        
        resource_id = config_item.get('resourceId', 'Unknown')
        resource_type = config_item.get('resourceType', 'Unknown')
        event_time_str = config_event.get('time') # 例: "2026-06-15T09:00:00Z"

        # SGの名前を取得する処理
        resource_name = "Unknown"
        if resource_type == 'AWS::EC2::SecurityGroup':
            resource_name = get_sg_name(resource_id)

        # 作った翻訳関数にDiffデータを渡す
        diff_data = detail.get('configurationItemDiff', {})
        parsed_diff_text = parse_sg_diff(diff_data)

        # CloudTrailへの検索
        username = "Unknown User"

        if event_time_str and resource_id != 'Unknown':
            try:
                event_time = datetime.strptime(event_time_str, "%Y-%m-%dT%H:%M:%SZ")
                start_time = event_time - timedelta(minutes=15)
                end_time = event_time + timedelta(minutes=15)

                response = cloudtrail.lookup_events(
                    LookupAttributes=[{'AttributeKey': 'ResourceName', 'AttributeValue': resource_id}],
                    StartTime=start_time,
                    EndTime=end_time,
                    MaxResults=1
                )
                
                events = response.get('Events', [])
                if events:
                    # 履歴が見つかったら、ユーザー名を抽出
                    username = events[0].get('Username', 'Unknown')
                    
            except Exception as e:
                print(f"CloudTrail検索エラー: {e}")
                username = "Error (権限不足)"

        # Slack通知メッセージの作成（Configの差分情報 ＋ CloudTrailの犯人情報）
        message = "--------------------------------------------------\n"
        message += "⚠️ *【構成ドリフト検知】*\n"
        message += f"*- 対象リソース:* `{resource_type}` (`{resource_id}`)\n"
        message += f"*- 操作者:* `{username}`\n"
        message += f"*- 変更内容:* {parsed_diff_text}\n"
        message += "--------------------------------------------------\n"

        # Slackへ送信
        payload = {
            'text': message,
            'username': 'drift-notice',  # ボットの名前
            'icon_emoji': ':ghost:'      # お化けのアイコン
        }

        req = urllib.request.Request(
            slack_url,
            data=json.dumps(payload).encode('utf-8'),
            headers={'Content-Type': 'application/json'}
        )
        urllib.request.urlopen(req)

    return {'statusCode': 200, 'body': 'Success'}