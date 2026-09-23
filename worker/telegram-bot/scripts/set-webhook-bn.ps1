$ErrorActionPreference = "Stop"

Write-Host "CPAY Telegram webhook setup" -ForegroundColor Cyan
Write-Host "Token এবং secret শুধু এই local prompt-এ দিন; chat-এ পাঠাবেন না." -ForegroundColor Yellow

$token = (Read-Host "1) Telegram bot token").Trim()
$workerUrl = (Read-Host "2) Deployed Worker URL (https://...workers.dev)").Trim().TrimEnd('/')
$secret = (Read-Host "3) TELEGRAM_WEBHOOK_SECRET").Trim()

if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($workerUrl) -or [string]::IsNullOrWhiteSpace($secret)) {
  throw "Token, Worker URL এবং webhook secret—তিনটিই দরকার।"
}

if (-not $workerUrl.StartsWith("https://")) {
  throw "Worker URL অবশ্যই https:// দিয়ে শুরু হতে হবে।"
}

$base = "https://api.telegram.org/bot$token"
$payload = @{
  url = "$workerUrl/telegram"
  secret_token = $secret
  allowed_updates = @("message", "my_chat_member")
  drop_pending_updates = $false
} | ConvertTo-Json -Depth 5

$result = Invoke-RestMethod "$base/setWebhook" -Method Post -ContentType "application/json" -Body $payload
if (-not $result.ok) { throw "Telegram webhook set হয়নি: $($result.description)" }

Write-Host "Webhook set হয়েছে:" -ForegroundColor Green
Write-Host "$workerUrl/telegram"

$info = Invoke-RestMethod "$base/getWebhookInfo"
Write-Host ""
Write-Host "Webhook status:" -ForegroundColor Cyan
$info.result | Select-Object url, pending_update_count, last_error_message, last_error_date | Format-List

$me = Invoke-RestMethod "$base/getMe"
Write-Host "Bot: @$($me.result.username)" -ForegroundColor Green
Write-Host "এখন group-এ /today লিখে test করুন।" -ForegroundColor Green
