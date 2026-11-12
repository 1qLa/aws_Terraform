# 用語解説スライドの出典

確認日: 2026-11-05。すべて公式ドキュメント（一次情報）を取得して確認した。

スライドの説明文は、下の公式の記述を日本語で短くまとめたもの。「本研究では」の行は公式の記述ではなく、`architecture/drift-notifier-mcp-extension.drawio` と `task.md` の設計に基づく（認証・承認・調査の部分は、まだ実装していない設計段階）。

## 検知・通知

| 用語 | 出典URL | 公式の記述（要点） |
|---|---|---|
| AWS Config | https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html | AWSリソースの設定の詳細なビューを提供し、過去にどう設定されていたかも見られる。リソースの作成・変更・削除を通知できる。 |
| AWS CloudTrail | https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html | ユーザー・ロール・AWSサービスの操作がイベントとして記録される。誰が（何が）どの操作をしたか、いつ起きたかを確認できる。 |
| Amazon EventBridge | https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-what-is.html | イベントを使ってアプリの各部分をつなぐサーバーレスのサービス。イベントバスは、イベントを受け取って0個以上のターゲットに届けるルーター。 |
| Amazon SNS | https://docs.aws.amazon.com/sns/latest/dg/welcome.html | 発行者から購読者へメッセージを届けるフルマネージドのサービス。発行者は「トピック」にメッセージを送り、購読者がそれを受け取る。 |
| Amazon SQS | https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html | 安全で耐久性のあるホスト型のキュー。分散したソフトウェアのシステムやコンポーネントを、統合し、疎結合にできる。 |
| AWS Lambda | https://docs.aws.amazon.com/lambda/latest/dg/welcome.html | サーバーレスのコンピューティングサービス。サーバーを用意・管理せずにコードを実行できる。トリガーにはAPI Gateway、SQS、EventBridgeなどを接続できる。 |

## 認証・承認・調査

| 用語 | 出典URL | 公式の記述（要点） |
|---|---|---|
| Amazon Cognito | https://docs.aws.amazon.com/cognito/latest/developerguide/what-is-amazon-cognito.html | Webとモバイルアプリ向けのIDプラットフォーム。ユーザーディレクトリ、認証サーバー、OAuth 2.0アクセストークンの認可サービス。ユーザープールは、ユーザーを認証し、JWTを発行する。グループとカスタム属性の機能もある。 |
| Amazon API Gateway | https://docs.aws.amazon.com/apigateway/latest/developerguide/welcome.html | REST・HTTP・WebSocketのAPIを、作成・公開・保守・監視・保護するサービス。アプリが、バックエンドのデータや機能にアクセスするときの「入り口（front door）」になる。認証にCognitoのユーザープールも使える。 |
| Amazon DynamoDB | https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html | サーバーレスでフルマネージドの、分散型NoSQLデータベース。 |
| Amazon Bedrock AgentCore Gateway | https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway.html | エージェントの通信のための、フルマネージドでセキュアな入り口。API、Lambda関数、既存のサービスを、MCP対応のツールに変換する。入口側と出口側の認証を管理する。 |
| Amazon Bedrock AgentCore Identity | https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/identity.html | AIエージェントと自動化されたワークロード向けの、IDと認証情報の管理サービス。エージェントが、ユーザーに代わってAWSや外部のサービスにアクセスするための認証・認可・認証情報の管理を提供する。 |
| Model Context Protocol (MCP) | https://modelcontextprotocol.io/docs/getting-started/intro | AIアプリを外部のシステムにつなぐための、オープンソースの標準規格。 |

## 認可の用語（OAuth・アクセストークン・2LO・3LO）

確認日: 2026-11-12。用語解説③（13枚目）の出典。

| 用語 | 出典URL | 公式の記述（要点） |
|---|---|---|
| OAuth 2.0 | https://datatracker.ietf.org/doc/html/rfc6749 （RFC 6749） | サードパーティのアプリが、HTTPサービスへの限定的なアクセスを得られるようにする認可のフレームワーク。アクセストークンは「保護されたリソースにアクセスするための認証情報」。 |
| Authorization Code（3LO） | https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/common-use-cases.html | ユーザーの明示的な同意のもとで、エージェントがそのユーザー固有のデータにアクセスする。ユーザーが同意の画面に関わる。 |
| Client Credentials（2LO） | 同上 | ユーザーの関与なしに、システム同士が直接認証する。エージェントが自分自身の認証情報で認証し、権限はエージェント単位で決まる。 |

- 「2LO」「3LO」という呼び方は、上の公式ドキュメントには出てこない。2LO＝client credentials、3LO＝authorization code の通称として、スライドに載せた（メモにも「通称」と明記）。
- 研究での使いどころ（②③＝2LO、⑥⑨＝3LO）は、`architecture/drift-notifier-mcp-extension.drawio` と Canva 16枚目「処理の流れ」の設計に基づく（未実装）。

## 載せなかった用語

- Amazon S3（Terraformのstateの保存先）と Terraform は、構成図には出てくるが、スライドの密度を考えて外した。前期のスライドで Terraform は説明済み。
- Slack と Claude Code は、AWSのサービスではないので外した。必要なら、各社の公式ドキュメントで確認してから足す。
