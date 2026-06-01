# WAF Web ACL
resource "aws_wafv2_web_acl" "main" {
  name        = "${var.prefix}-web-acl"
  description = "WAF Web ACL for ${var.prefix}"
  scope       = "REGIONAL" // ALBに使用する場合は REGIONAL を指定

    // デフォルトのアクション（どのルールにも合致しない場合は通す）
    default_action {
        allow {}
    }

    # AWSが管理するCore Rule Set（一般的なWeb攻撃を網羅したセット）を防ぐルール
    rule {
        name     = "AWSManagedRulesCommonRuleSet"
        priority = 1

        override_action {
            none {}
        }

        statement {
            managed_rule_group_statement {
                name        = "AWSManagedRulesCommonRuleSet"
                vendor_name = "AWS"
            }
        }

        visibility_config {
            sampled_requests_enabled = true
            cloudwatch_metrics_enabled = true
            metric_name = "AWSManagedRulesCommonRuleSetMetric"
        }
    }

    # SQLインジェクションやクロスサイトスクリプティングなどの攻撃を防ぐルール
    rule {
        name     = "AWSManagedRulesSQLiRuleSet"
        priority = 2

        override_action {
            none {}
        }

        statement {
            managed_rule_group_statement {
                name        = "AWSManagedRulesSQLiRuleSet"
                vendor_name = "AWS"
            }
        }

        visibility_config {
            sampled_requests_enabled = true
            cloudwatch_metrics_enabled = true
            metric_name = "${var.prefix}-sqli-rule-set"
        }
    }

    # WAF自体のモニタリングの設定
    visibility_config {
        sampled_requests_enabled = true
        cloudwatch_metrics_enabled = true
        metric_name = "${var.prefix}-waf-metrics"
    }
}

# WAFをALBに関連付ける
resource "aws_wafv2_web_acl_association" "main" {
  resource_arn = aws_alb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}