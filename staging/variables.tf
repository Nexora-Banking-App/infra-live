variable "alert_email" {
  description = "Email address for Alertmanager"
  type        = string
  sensitive   = true
}

variable "alert_password" {
  description = "Gmail App Password for Alertmanager"
  type        = string
  sensitive   = true
}