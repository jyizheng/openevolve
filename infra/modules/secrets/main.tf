resource "aws_secretsmanager_secret" "gemini_api_key" {
  name                    = "${var.prefix}/gemini-api-key"
  description             = "Gemini API key for OpenEvolve LLM calls"
  recovery_window_in_days = 7
}

# Create an empty placeholder version so the ARN is stable and ready to reference.
# After deploying, populate the real key:
#   aws secretsmanager put-secret-value \
#     --secret-id <ARN> \
#     --secret-string "your-actual-gemini-api-key"
resource "aws_secretsmanager_secret_version" "gemini_api_key" {
  secret_id     = aws_secretsmanager_secret.gemini_api_key.id
  secret_string = "PLACEHOLDER_REPLACE_ME"

  lifecycle {
    # Prevent Terraform from overwriting the key once a human has set it
    ignore_changes = [secret_string]
  }
}
