"""
Email verification codes.

A code is 6 digits, valid for 10 minutes, and allows 5 wrong guesses before
a new one must be requested. A new code can be sent at most once a minute.
"""
import hashlib
import hmac
import secrets
from datetime import timedelta

from django.conf import settings
from django.core.mail import send_mail
from django.utils import timezone

from .models import EmailVerification

CODE_LIFETIME = timedelta(minutes=10)
RESEND_COOLDOWN = timedelta(seconds=60)
MAX_ATTEMPTS = 5
# Unverified sign-ups older than this no longer hold on to their username and
# email, so a typo'd or abandoned sign-up can't block anyone for long.
STALE_AFTER = timedelta(hours=24)


class VerificationError(Exception):
    pass


class EmailSendError(Exception):
    pass


def is_verified(user):
    record = EmailVerification.objects.filter(user=user).first()
    return record is None or record.verified_at is not None


def mask_email(email):
    """a***@gmail.com — enough to recognise, not enough to harvest."""
    name, _, domain = email.partition("@")
    if not domain:
        return "your email"
    return f"{name[:1]}***@{domain}"


def _hash(user_id, code):
    message = f"{user_id}:{code}".encode()
    return hmac.new(settings.SECRET_KEY.encode(), message, hashlib.sha256).hexdigest()


def send_code(user, force=False):
    """
    Email a fresh code. Returns the seconds to wait if one was sent too
    recently (and nothing was sent), otherwise 0.
    """
    record, _ = EmailVerification.objects.get_or_create(user=user)
    now = timezone.now()
    if not force and record.last_sent_at and now - record.last_sent_at < RESEND_COOLDOWN:
        return int((RESEND_COOLDOWN - (now - record.last_sent_at)).total_seconds()) + 1

    code = f"{secrets.randbelow(1_000_000):06d}"
    try:
        send_mail(
            subject=f"Your Findit code: {code}",
            message=(
                f"Hi {user.first_name or user.username},\n\n"
                f"Your Findit verification code is {code}\n\n"
                "It expires in 10 minutes. If you didn't sign up, you can ignore this email.\n"
            ),
            from_email=settings.DEFAULT_FROM_EMAIL,
            recipient_list=[user.email],
            fail_silently=False,
        )
    except Exception as exc:  # SMTP down, wrong password, no network...
        raise EmailSendError(str(exc)) from exc

    record.code_hash = _hash(user.pk, code)
    record.code_expires_at = now + CODE_LIFETIME
    record.attempts = 0
    record.last_sent_at = now
    record.save(update_fields=["code_hash", "code_expires_at", "attempts", "last_sent_at"])
    return 0


def check_code(user, code):
    """Mark the user verified if the code is right; raise VerificationError if not."""
    record = EmailVerification.objects.filter(user=user).first()
    if record is None or record.verified_at:
        return  # already verified
    code = "".join(ch for ch in str(code) if ch.isdigit())
    if not record.code_hash:
        raise VerificationError("Request a new code first.")
    if record.attempts >= MAX_ATTEMPTS:
        raise VerificationError("Too many wrong codes. Tap 'Send a new code'.")
    if record.code_expires_at and timezone.now() > record.code_expires_at:
        raise VerificationError("That code has expired. Tap 'Send a new code'.")
    if not hmac.compare_digest(record.code_hash, _hash(user.pk, code)):
        record.attempts += 1
        record.save(update_fields=["attempts"])
        left = MAX_ATTEMPTS - record.attempts
        if left <= 0:
            raise VerificationError("Too many wrong codes. Tap 'Send a new code'.")
        raise VerificationError(f"That code isn't right. {left} tries left.")
    record.verified_at = timezone.now()
    record.code_hash = ""
    record.save(update_fields=["verified_at", "code_hash"])


def free_stale_signups(username="", email=""):
    """Delete abandoned, never-verified sign-ups that hold this username or email."""
    from django.contrib.auth import get_user_model
    from django.db.models import Q

    if not username and not email:
        return
    match = Q()
    if username:
        match |= Q(username__iexact=username)
    if email:
        match |= Q(email__iexact=email)
    get_user_model().objects.filter(
        match,
        email_verification__verified_at__isnull=True,
        email_verification__created_at__lt=timezone.now() - STALE_AFTER,
    ).delete()
