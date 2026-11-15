"""
Startup tasks for hosts without a command line (such as Render's free tier).
Runs on every start, and is safe to repeat:

- DJANGO_SUPERUSER_USERNAME / _EMAIL / _PASSWORD: creates that admin account
  for the moderation page, or updates its password if you change it.
- SEED_DEMO=true: adds the demo users and posts once, around SEED_DEMO_LAT /
  SEED_DEMO_LNG. They share a known password, so turn it off for real users.
"""
import os

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.core.management.base import BaseCommand


def _flag(name):
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


class Command(BaseCommand):
    help = "Create the admin account and (optionally) demo data from environment variables."

    def handle(self, *args, **options):
        self._report_email()
        self._ensure_admin()
        if _flag("SEED_DEMO"):
            self._seed_demo()

    def _report_email(self):
        """Say in the log how sign-up codes will be sent, to make email set-up easy to check."""
        from django.conf import settings

        backend = settings.EMAIL_BACKEND.rsplit(".", 1)[-1]
        if backend == "BrevoEmailBackend":
            how = f"Brevo API, from {settings.DEFAULT_FROM_EMAIL}"
        elif backend == "EmailBackend" and "smtp" in settings.EMAIL_BACKEND:
            how = f"SMTP {settings.EMAIL_HOST}:{settings.EMAIL_PORT} as {settings.EMAIL_HOST_USER}"
        elif "console" in settings.EMAIL_BACKEND:
            how = "printed in this log (no BREVO_API_KEY or EMAIL_HOST_USER set)"
        else:
            how = settings.EMAIL_BACKEND
        self.stdout.write(f"Sign-up code emails: {how}.")

    def _ensure_admin(self):
        username = os.environ.get("DJANGO_SUPERUSER_USERNAME", "").strip()
        password = os.environ.get("DJANGO_SUPERUSER_PASSWORD", "")
        email = os.environ.get("DJANGO_SUPERUSER_EMAIL", "").strip()
        if not username or not password:
            self.stdout.write("Admin account: not configured (set DJANGO_SUPERUSER_USERNAME and _PASSWORD).")
            return
        User = get_user_model()
        user, created = User.objects.get_or_create(username=username, defaults={"email": email})
        changed = created
        if not user.is_staff or not user.is_superuser or not user.is_active:
            user.is_staff = user.is_superuser = user.is_active = True
            changed = True
        if email and user.email != email:
            user.email = email
            changed = True
        # Only re-hash when the password actually changed, so restarts don't
        # sign the admin out of the moderation page.
        if not user.check_password(password):
            user.set_password(password)
            changed = True
        if changed:
            user.save()
        self.stdout.write(f"Admin account '{username}': {'created' if created else 'ready'}.")

    def _seed_demo(self):
        if get_user_model().objects.filter(username="sana").exists():
            self.stdout.write("Demo data: already there.")
            return
        lat = float(os.environ.get("SEED_DEMO_LAT", "12.9716"))
        lng = float(os.environ.get("SEED_DEMO_LNG", "77.5946"))
        call_command("seed_demo", lat=lat, lng=lng, stdout=self.stdout)
