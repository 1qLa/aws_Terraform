#!/usr/bin/env bash
# 申告・承認APIの動作確認（田中・佐藤・鈴木のシナリオ）
# 使い方: リポジトリのルートで  bash drafts/test_api.sh
# 台帳にテスト用のデータ(test-001, test-002)を入れ、確認後に削除する
set -u
cd "$(dirname "$0")/.."

export AWS_PROFILE=dev AWS_REGION=ap-northeast-1 AWS_PAGER=""
URL=$(terraform output -raw api_base_url)
POOL=$(terraform output -raw cognito_user_pool_id)
CLIENT=$(terraform output -raw cognito_test_cli_client_id)
TABLE=$(terraform output -raw drift_events_table_name)
PW=$(sed -n 's/^test_user_password *= *"\(.*\)"/\1/p' terraform.tfvars)

token() { # 引数: メールアドレス。IDトークンを返す
  aws cognito-idp admin-initiate-auth --user-pool-id "$POOL" --client-id "$CLIENT" \
    --auth-flow ADMIN_USER_PASSWORD_AUTH \
    --auth-parameters "USERNAME=$1,PASSWORD=$PW" \
    --query AuthenticationResult.IdToken --output text
}

user_arn() { # 引数: メールアドレス。そのユーザーの custom:iam_arn を返す
  aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$1" \
    --query "UserAttributes[?Name=='custom:iam_arn'].Value" --output text
}
TANAKA_ARN=$(user_arn tanaka@example.com)
SUZUKI_ARN=$(user_arn suzuki@example.com)

seed() { # 引数: event_id [変更した人のARN]。既定は、田中が変更した、というデータを入れる
  local arn=${2:-$TANAKA_ARN}
  aws dynamodb put-item --table-name "$TABLE" --item "{
    \"event_id\": {\"S\": \"$1\"}, \"resource_id\": {\"S\": \"sg-00000000test0000\"},
    \"detected_at\": {\"S\": \"2026-11-23T00:00:00Z\"}, \"operator_arn\": {\"S\": \"$arn\"},
    \"status\": {\"S\": \"DETECTED\"}}"
}

cleanup() { # 途中で止まっても、テストデータは必ず削除する
  rm -f "$BODY_FILE"
  for id in test-001 test-002 test-003; do
    aws dynamodb delete-item --table-name "$TABLE" --key "{\"event_id\":{\"S\":\"$id\"}}"
  done
}
BODY_FILE=$(mktemp); trap cleanup EXIT
PASS=0; FAIL=0
check() { # 引数: 名前 期待するHTTPコード パス メール 本文
  local name=$1 expect=$2 path=$3 who=$4 body=${5:-\{\}}
  local code
  code=$(curl -s -o "$BODY_FILE" -w '%{http_code}' -X POST "$URL/$path" \
    -H "Authorization: $(token "$who")" -H 'Content-Type: application/json' -d "$body")
  if [ "$code" = "$expect" ]; then PASS=$((PASS+1)); mark="OK  "; else FAIL=$((FAIL+1)); mark="NG  "; fi
  echo "${mark}${name}（期待 ${expect} / 実際 ${code}）$(cat "$BODY_FILE")"
}

echo "== 準備: テストデータを入れる"
seed test-001; seed test-002; seed test-003 "$SUZUKI_ARN"

echo "== 申告"
check "佐藤（本人以外）は申告できない"      403 attest/test-001  sato@example.com   '{"reason":"x"}'
check "田中は理由なしでは申告できない"      400 attest/test-001  tanaka@example.com '{"reason":""}'
check "田中（本人）は申告できる"            200 attest/test-001  tanaka@example.com '{"reason":"動作確認"}'
check "田中は再申告できない"                409 attest/test-001  tanaka@example.com '{"reason":"もう一度"}'
echo "== 承認"
check "未申告のデータは承認できない"        409 approve/test-002 suzuki@example.com
check "田中（申告者本人）は承認できない"    403 approve/test-001 tanaka@example.com
check "佐藤（同じ権限）は承認できない"      403 approve/test-001 sato@example.com
check "鈴木（上位）は承認できる"            200 approve/test-001 suzuki@example.com
check "鈴木は再承認できない"                409 approve/test-001 suzuki@example.com

echo "== 最上位（leads）の人が申告したとき"
check "鈴木（最上位）が申告できる"                  200 attest/test-003  suzuki@example.com '{"reason":"緊急対応"}'
check "鈴木は自分の申告を承認できない"              403 approve/test-003 suzuki@example.com
check "田中（下位）は最上位の申告を承認できない"    403 approve/test-003 tanaka@example.com
check "山田（最上位の別の人）は承認できる"          200 approve/test-003 yamada@example.com

echo "== 台帳の最終状態（test-001）"
aws dynamodb get-item --table-name "$TABLE" --key '{"event_id":{"S":"test-001"}}' \
  --query 'Item.{status:status.S,reason:reason.S,attested_by:attested_by.S,approved_by:approved_by.S}' --output json

echo "（テストデータは、終了時に自動で削除されます）"
echo "== 結果: OK $PASS 件 / NG $FAIL 件"
[ "$FAIL" = 0 ]
