"""
Send email through Brevo's HTTPS API instead of SMTP.

Hosts such as Render's free tier block the email ports (25, 465, 587), so
SMTP can't connect there. Brevo's free plan sends 300 emails a day over a
normal web request. Set BREVO_API_KEY and a DEFAULT_FROM_EMAIL whose address
is a verified sender in your Brevo account.
"""
import json
import urllib.error
import urllib.request
from email.utils import parseaddr

from django.conf import settings
from django.core.mail.backends.base import BaseEmailBackend

BREVO_URL = "https://api.brevo.com/v3/smtp/email"


class BrevoEmailBackend(BaseEmailBackend):
    def send_messages(self, email_messages):
        sent = 0
        for message in email_messages:
            try:
                self._send(message)
                sent += 1
            except Exception:
                if not self.fail_silently:
                    raise
        return sent

    def _send(self, message):
        name, address = parseaddr(message.from_email or settings.DEFAULT_FROM_EMAIL)
        payload = {
            "sender": {"email": address, **({"name": name} if name else {})},
            "to": [{"email": parseaddr(r)[1]} for r in message.to],
            "subject": message.subject,
            "textContent": message.body,
        }
        if message.cc:
            payload["cc"] = [{"email": parseaddr(r)[1]} for r in message.cc]
        if message.bcc:
            payload["bcc"] = [{"email": parseaddr(r)[1]} for r in message.bcc]
        request = urllib.request.Request(
            BREVO_URL,
            data=json.dumps(payload).encode(),
            headers={
                "api-key": settings.BREVO_API_KEY,
                "content-type": "application/json",
                "accept": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=settings.EMAIL_TIMEOUT) as response:
                if response.status >= 300:
                    raise RuntimeError(f"Brevo answered {response.status}")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")[:300]
            raise RuntimeError(f"Brevo refused the email ({exc.code}): {detail}") from exc
