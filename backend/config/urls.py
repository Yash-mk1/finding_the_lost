from django.conf import settings
from django.contrib import admin
from django.urls import include, path, re_path
from django.views.static import serve
from rest_framework.routers import DefaultRouter

from accounts.views import LoginView, LogoutView, MeView, RegisterView, ResendCodeView, VerifyEmailView
from lostfound.views import ClaimViewSet, MyClaimsViewSet, MyPostsViewSet, PostViewSet, health, meta

router = DefaultRouter()
router.register("posts", PostViewSet, basename="post")
router.register("claims", ClaimViewSet, basename="claim")
router.register("me/posts", MyPostsViewSet, basename="my-post")
router.register("me/claims", MyClaimsViewSet, basename="my-claim")

admin.site.site_header = "Findit — moderation"

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/auth/register/", RegisterView.as_view()),
    path("api/auth/login/", LoginView.as_view()),
    path("api/auth/verify-email/", VerifyEmailView.as_view()),
    path("api/auth/resend-code/", ResendCodeView.as_view()),
    path("api/auth/logout/", LogoutView.as_view()),
    path("api/auth/me/", MeView.as_view()),
    path("api/meta/", meta),
    path("api/health/", health),
    path("api/", include(router.urls)),
]

# Uploaded photos, and the admin's CSS/JS (collected by `collectstatic`).
# Django only serves these by itself under `runserver`, so under gunicorn they
# are served explicitly; put Nginx or a CDN in front for real traffic.
# With S3_BUCKET set, photos are served by the storage service instead.
if settings.DEBUG or settings.SERVE_MEDIA:
    if not settings.S3_BUCKET:
        urlpatterns.append(re_path(r"^media/(?P<path>.*)$", serve, {"document_root": settings.MEDIA_ROOT}))
    urlpatterns.append(re_path(r"^static/(?P<path>.*)$", serve, {"document_root": settings.STATIC_ROOT}))
