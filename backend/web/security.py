"""Honeypot check for public forms, and the admin lockout response."""
from django.conf import settings
from django.http import HttpResponse, JsonResponse
from rest_framework import status
from rest_framework.response import Response

HONEYPOT_FIELD = "website"
HONEYPOT_MESSAGE = (
    "This looked like an automated submission, so it wasn't sent. If you're a person, "
    "clear the field marked 'Leave this field empty' and try again."
)


def honeypot_response(request):
    """
    The website's forms carry a hidden field named `website` that people never
    see or fill in; form-filling bots usually do. The app doesn't send it.

    The request is refused with a clear message instead of being silently
    dropped, so a real person caught by mistake finds out.
    Returns a Response to send back, or None if the request is fine.
    """
    data = getattr(request, "data", None)
    value = data.get(HONEYPOT_FIELD) if hasattr(data, "get") else None
    if value and str(value).strip():
        return Response({"detail": HONEYPOT_MESSAGE, "code": "honeypot"}, status=status.HTTP_400_BAD_REQUEST)
    return None


def lockout_response(request, *args, **kwargs):
    """
    What django-axes shows after too many failed log-ins for one
    (address, username) pair: JSON for the app and website, a page for the
    admin.
    """
    hours = settings.AXES_COOLOFF_TIME
    message = f"Too many failed log-in attempts. Try again in {hours} hour{'s' if hours != 1 else ''}."
    if request.path.startswith("/api/"):
        return JsonResponse({"detail": message, "code": "locked_out"}, status=429)
    return HttpResponse(
        f"<!doctype html><meta charset='utf-8'><title>Locked</title>"
        f"<p style='font-family:sans-serif;padding:2rem'>{message}</p>",
        status=429,
    )
