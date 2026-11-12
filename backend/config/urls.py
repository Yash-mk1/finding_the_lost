from django.conf import settings
from django.contrib import admin
from django.urls import include, path, re_path
from django.views.static import serve
from rest_framework.routers import DefaultRouter

from accounts.views import LoginView, LogoutView, MeView, RegisterView
from lostfound.views import ClaimViewSet, MyClaimsViewSet, MyPostsViewSet, PostViewSet, meta

router = DefaultRouter()
router.register("posts", PostViewSet, basename="post")
router.register("claims", ClaimViewSet, basename="claim")
router.register("me/posts", MyPostsViewSet, basename="my-post")
router.register("me/claims", MyClaimsViewSet, basename="my-claim")

admin.site.site_header = "Finding the Lost — moderation"

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/auth/register/", RegisterView.as_view()),
    path("api/auth/login/", LoginView.as_view()),
    path("api/auth/logout/", LogoutView.as_view()),
    path("api/auth/me/", MeView.as_view()),
    path("api/meta/", meta),
    path("api/", include(router.urls)),
]

# Uploaded photos. django.conf.urls.static.static() only works with DEBUG on,
# so serve them explicitly; put Nginx or a CDN in front for real traffic.
if settings.DEBUG or settings.SERVE_MEDIA:
    urlpatterns += [
        re_path(r"^media/(?P<path>.*)$", serve, {"document_root": settings.MEDIA_ROOT}),
    ]
