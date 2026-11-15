"""
Rate limits stored in the database (shared by every gunicorn worker).

DRF's built-in ScopedRateThrottle keeps its counters in Django's cache, which
by default is a separate in-memory store inside each worker process. With 2
workers a client gets about twice the limit, and every restart resets it.
This throttle keeps the same scopes and rates (REST_FRAMEWORK
"DEFAULT_THROTTLE_RATES") but counts in the ClientHit table instead.

Only write requests (POST, PUT, PATCH, DELETE) are counted. Every one of them
counts, valid or not, because the check runs before the request is handled,
so a bot posting garbage is throttled as well.
"""
import hashlib
import hmac
from datetime import timedelta

from django.conf import settings
from django.db import transaction
from django.utils import timezone
from rest_framework.permissions import SAFE_METHODS
from rest_framework.throttling import BaseThrottle

from .models import ClientHit

PERIODS = {"s": 1, "m": 60, "h": 3600, "d": 86400}


def parse_rate(rate):
    """'30/min' -> (30, 60). Accepts s, sec, m, min, h, hour, d, day."""
    num, period = rate.split("/")
    return int(num), PERIODS[period.strip()[0].lower()]


def client_address(request):
    """
    The visitor's address. Behind Render's proxy the real one is the leftmost
    entry of X-Forwarded-For; locally it is REMOTE_ADDR.

    X-Forwarded-For can be forged by a client, so this is a speed bump against
    scripts, not an identity. Raising that bar needs a WAF in front.
    """
    forwarded = request.META.get("HTTP_X_FORWARDED_FOR", "")
    if forwarded:
        first = forwarded.split(",")[0].strip()
        if first:
            return first
    return request.META.get("REMOTE_ADDR", "") or "unknown"


def client_token(request):
    """
    A salted hash of the client, so the table never stores an IP address (or a
    user id) that could identify someone. Salted with SECRET_KEY, so the hash
    can't be reversed by trying every possible address.
    """
    user = getattr(request, "user", None)
    if user is not None and user.is_authenticated:
        raw = f"user:{user.pk}"
    else:
        raw = f"ip:{client_address(request)}"
    return hmac.new(settings.SECRET_KEY.encode(), raw.encode(), hashlib.sha256).hexdigest()


class DatabaseScopedRateThrottle(BaseThrottle):
    """Drop-in replacement for ScopedRateThrottle that counts in the database."""

    scope_attr = "throttle_scope"

    def allow_request(self, request, view):
        if request.method in SAFE_METHODS:
            return True
        scope = getattr(view, self.scope_attr, None)
        rate = settings.REST_FRAMEWORK.get("DEFAULT_THROTTLE_RATES", {}).get(scope) if scope else None
        if not rate:
            return True
        self.num, self.period = parse_rate(rate)
        client = client_token(request)
        now = timezone.now()
        window_start = now - timedelta(seconds=self.period)
        with transaction.atomic():
            # Tidy up as we go, so no scheduled clean-up job is needed.
            ClientHit.objects.filter(scope=scope, created_at__lt=window_start).delete()
            recent = list(
                ClientHit.objects.filter(scope=scope, client=client, created_at__gte=window_start)
                .order_by("created_at")
                .values_list("created_at", flat=True)[: self.num]
            )
            if len(recent) >= self.num:
                self.wait_seconds = max(1, int((recent[0] + timedelta(seconds=self.period) - now).total_seconds()))
                return False
            ClientHit.objects.create(scope=scope, client=client)
        return True

    def wait(self):
        return getattr(self, "wait_seconds", None)
