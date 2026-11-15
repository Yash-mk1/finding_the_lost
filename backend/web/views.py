from django.conf import settings
from django.shortcuts import render
from django.views.decorators.http import require_GET

# Bump when app.js / app.css change, so browsers fetch the new files.
ASSET_VERSION = "2"


def _photo_host():
    options = settings.STORAGES["default"].get("OPTIONS", {})
    domain = options.get("custom_domain") or ""
    return "https://" + domain.split("/")[0] if domain else ""


@require_GET
def index(request):
    """The website: one page; app.js draws every screen and talks to /api/."""
    response = render(request, "web/index.html", {"v": ASSET_VERSION})
    photos = _photo_host()
    # Only our own scripts may run, so injected text can never execute.
    response["Content-Security-Policy"] = "; ".join([
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        f"img-src 'self' data: blob: https://tile.openstreetmap.org {photos}".strip(),
        "font-src 'self'",
        "connect-src 'self'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'self'",
        "frame-ancestors 'none'",
    ])
    response["Referrer-Policy"] = "same-origin"
    response["Permissions-Policy"] = "geolocation=(self), camera=(self)"
    return response
