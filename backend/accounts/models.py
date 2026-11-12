from django.conf import settings
from django.db import models


class EmailVerification(models.Model):
    """
    Tracks the 6-digit code emailed to a new account.

    Every account created through the app's sign-up gets one of these, and
    can't log in until `verified_at` is set. Accounts without a record (made
    with `createsuperuser`, in the admin, or by `seed_demo`) count as verified.
    """

    user = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="email_verification")
    verified_at = models.DateTimeField(null=True, blank=True)
    # Only a keyed hash of the code is stored, never the code itself.
    code_hash = models.CharField(max_length=128, blank=True)
    code_expires_at = models.DateTimeField(null=True, blank=True)
    attempts = models.PositiveSmallIntegerField(default=0)
    last_sent_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.user} ({'verified' if self.verified_at else 'not verified'})"
