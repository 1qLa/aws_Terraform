# DynamoDB
# 構成ドリフトの台帳（検知内容・操作者・申告理由・承認者を1件ずつ記録する）
resource "aws_dynamodb_table" "drift_events" {
  name         = "${var.prefix}-drift-events" // テーブル名（kane-drift-events）
  billing_mode = "PAY_PER_REQUEST"            // 使った分だけ課金（検証用で件数が少ないため、容量の事前指定をしない）
  hash_key     = "event_id"                   // パーティションキー。申告・承認のリンクからこのIDで1件を引く

  # キーとして使う項目だけを定義する（申告理由や承認者などの項目は、Lambdaが書き込むときに入る）
  attribute {
    name = "event_id" // ドリフト1件ごとのID
    type = "S"        // S = 文字列
  }

  attribute {
    name = "resource_id" // 変更されたSGのID（例: sg-0ae907c5511a2f1bd）
    type = "S"
  }

  attribute {
    name = "detected_at" // 検知日時（ISO 8601の文字列なので、文字列の順で時刻順に並ぶ）
    type = "S"
  }

  # 調査用のインデックス: SG IDごとの履歴を検知日時の順に取得する（investigate Lambdaが使う）
  global_secondary_index {
    name            = "resource_id-detected_at-index" // インデックス名
    hash_key        = "resource_id"                   // SG IDで絞り込む
    range_key       = "detected_at"                   // 同じSGの中では検知日時で並べる
    projection_type = "ALL"                           // 元のテーブルの全項目をインデックスからも読めるようにする
  }

  tags = {
    Name = "${var.prefix}-drift-events" // AWSコンソールで見分けるための名前タグ
  }
}
