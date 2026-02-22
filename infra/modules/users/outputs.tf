output "user_credentials" {
  description = "Map of username → {access_key_id, secret_access_key}. Handle with care."
  sensitive   = true
  value = {
    for username in var.usernames : username => {
      access_key_id     = aws_iam_access_key.users[username].id
      secret_access_key = aws_iam_access_key.users[username].secret
      iam_user_name     = aws_iam_user.users[username].name
    }
  }
}
