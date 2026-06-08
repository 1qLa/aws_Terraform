import json
# 外部（今回はSlack）にHTTP通信を送るためのツール
import urllib.request
import os

def lambda_handler(event, context):
    # Terraformで設定した環境変数からSlackのURLを読み込む
    slack_url = os.environ['SLACK_WEBHOOK_URL']
    
    # curlの "payload={...}" に相当する送りたいメッセージを作成
    slack_message = {
        "username": "drift-notice",
        "text": "AWSの構成ドリフト（手動変更）を検知しました。",
        "icon_emoji": ":ghost:"
    }

    # curlの "-X POST" と同じように、PythonでPOST送信の準備
    req = urllib.request.Request(
        slack_url, 
        data=json.dumps(slack_message).encode('utf-8'), 
        headers={'Content-Type': 'application/json'}
    )

    # 送信した際のレスポンスを確認して、成功か失敗かを出力
    try:
        response = urllib.request.urlopen(req)
        print("Slackへの通知に成功しました。")
    except Exception as e:
        print(f"エラーが発生しました: {e}")

    return {
        'statusCode': 200,
        'body': 'Finished drift detection process.'
    }