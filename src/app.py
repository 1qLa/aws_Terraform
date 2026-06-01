import json

def lambda_handler(event, context):
    # SQSから受け取ったメッセージをログに出力するだけのシンプルなプログラム
    print("=== ドリフト検知アラートを受信 ===")
    print(json.dumps(event, indent=2))
    
    # 最終的にはここに「Slackへ通知を送る処理」などを書き足していきます
    
    return {
        'statusCode': 200,
        'body': json.dumps('処理成功！')
    }