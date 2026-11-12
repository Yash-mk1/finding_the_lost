import math

from django.conf import settings
from django.contrib.gis.db.models import PointField
from django.contrib.gis.db.models.functions import Distance
from django.contrib.gis.geos import Point, Polygon
from django.contrib.gis.measure import D
from django.db import IntegrityError, transaction
from django.db.models import Count, Exists, IntegerField, OuterRef, Q, Subquery, Value
from django.db.models.functions import Cast, Coalesce
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import mixins, permissions, status, viewsets
from rest_framework.decorators import action, api_view, authentication_classes, permission_classes
from rest_framework.exceptions import PermissionDenied, ValidationError
from rest_framework.response import Response

from .images import ImageError, clean_image
from .models import HANDOVER_GUIDANCE, Category, Claim, Handover, Post, PostImage, Report, Vote
from .serializers import (
    ClaimCreateSerializer,
    ClaimDecisionSerializer,
    ClaimSerializer,
    CommentSerializer,
    MyPostSerializer,
    PostCreateSerializer,
    PostDetailSerializer,
    PostListSerializer,
    PostUpdateSerializer,
    ReportSerializer,
)


class IsAuthorOrReadOnly(permissions.BasePermission):
    def has_object_permission(self, request, view, obj):
        if request.method in permissions.SAFE_METHODS:
            return True
        return request.user.is_authenticated and obj.author_id == request.user.pk


def parse_point(params):
    """Read ?lat=&lng= into a Point, or None if they are missing."""
    lat, lng = params.get("lat"), params.get("lng")
    if lat in (None, "") or lng in (None, ""):
        return None
    try:
        lat, lng = float(lat), float(lng)
    except ValueError:
        raise ValidationError({"lat": "lat and lng must be numbers."})
    # NaN fails every comparison, so this also rejects "nan" and "inf".
    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        raise ValidationError({"lat": "lat/lng out of range."})
    return Point(lng, lat, srid=4326)


def annotate_for_user(queryset, user):
    returned_by_author = (
        Post.objects.filter(author=OuterRef("author"), post_type=Post.Type.FOUND, status=Post.Status.RETURNED)
        .order_by()
        .values("author")
        .annotate(n=Count("id"))
        .values("n")
    )
    queryset = queryset.annotate(
        comment_count=Count("comments", distinct=True),
        author_returned_count=Coalesce(Subquery(returned_by_author, output_field=IntegerField()), Value(0)),
    )
    if user.is_authenticated:
        queryset = queryset.annotate(has_voted=Exists(Vote.objects.filter(post=OuterRef("pk"), user=user)))
    return queryset.select_related("author").prefetch_related("images")


class PostViewSet(viewsets.ModelViewSet):
    """
    Feed, map and CRUD for posts.

    GET  /api/posts/?lat=&lng=&radius_km=&type=found|lost&category=&q=&sort=near|new|top&include_returned=1
    GET  /api/posts/map/?bbox=minLng,minLat,maxLng,maxLat&type=&category=
    POST /api/posts/  (multipart: fields + images[] + blur_regions)
    """

    permission_classes = [permissions.IsAuthenticatedOrReadOnly, IsAuthorOrReadOnly]
    http_method_names = ["get", "post", "patch", "delete", "head", "options"]

    def get_throttles(self):
        if self.action == "create":
            self.throttle_scope = "post_create"
        elif self.action == "claims" and self.request.method == "POST":
            self.throttle_scope = "claim"
        elif self.action in ("comments", "report") and self.request.method == "POST":
            self.throttle_scope = "comment"
        return super().get_throttles()

    def get_serializer_class(self):
        if self.action == "create":
            return PostCreateSerializer
        if self.action == "partial_update":
            return PostUpdateSerializer
        if self.action == "retrieve":
            return PostDetailSerializer
        return PostListSerializer

    def get_serializer_context(self):
        context = super().get_serializer_context()
        origin = getattr(self, "_origin", None)
        if origin is None and self.action == "retrieve":
            origin = parse_point(self.request.query_params)  # optional ?lat=&lng= for "x m away"
        context["origin"] = origin
        return context

    def base_queryset(self):
        user = self.request.user
        visible = ~Q(status=Post.Status.HIDDEN)
        if user.is_authenticated:
            visible |= Q(author=user)  # authors still see their own hidden posts
        return annotate_for_user(Post.objects.filter(visible), user)

    def _post(self, pk):
        """A post the current user is allowed to see (hidden posts only for their author)."""
        user = self.request.user
        visible = ~Q(status=Post.Status.HIDDEN)
        if user.is_authenticated:
            visible |= Q(author=user)
        return get_object_or_404(Post.objects.filter(visible), pk=pk)

    def get_queryset(self):
        queryset = self.base_queryset()
        if self.action not in ("list", "map"):
            return queryset

        params = self.request.query_params
        live = Q(expires_at__gt=timezone.now(), status__in=[Post.Status.OPEN, Post.Status.CLAIMED])
        if params.get("include_returned") in ("1", "true"):
            live |= Q(status=Post.Status.RETURNED)
        queryset = queryset.filter(live).exclude(status=Post.Status.HIDDEN)

        post_type = params.get("type")
        if post_type in Post.Type.values:
            queryset = queryset.filter(post_type=post_type)
        category = params.get("category")
        if category in Category.values:
            queryset = queryset.filter(category=category)
        query = params.get("q", "").strip()
        if query:
            queryset = queryset.filter(
                Q(title__icontains=query) | Q(description__icontains=query) | Q(landmark__icontains=query)
            )

        # All public searching and sorting uses public_location, never the exact point.
        origin = parse_point(params)
        self._origin = origin
        if origin is not None:
            try:
                radius_km = float(params.get("radius_km") or 5)
            except ValueError:
                raise ValidationError({"radius_km": "Must be a number."})
            if not math.isfinite(radius_km):
                raise ValidationError({"radius_km": "Must be a number."})
            radius_km = min(max(radius_km, 0.1), 100)
            queryset = queryset.filter(public_location__dwithin=(origin, D(km=radius_km)))
            queryset = queryset.annotate(distance=Distance("public_location", origin))

        sort = params.get("sort") or ("near" if origin is not None else "new")
        if sort == "near" and origin is not None:
            queryset = queryset.order_by("distance", "-created_at")
        elif sort == "top":
            queryset = queryset.order_by("-score", "-created_at")
        else:
            queryset = queryset.order_by("-created_at")
        return queryset

    @transaction.atomic
    def create(self, request, *args, **kwargs):
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        images = serializer.validated_data.get("images") or []
        regions = serializer.validated_data.get("blur_regions") or []
        post = serializer.save(author=request.user)

        for index, upload in enumerate(images):
            try:
                content, width, height = clean_image(upload, regions[index] if index < len(regions) else None)
            except ImageError as exc:
                transaction.set_rollback(True)
                return Response({"images": [str(exc)]}, status=status.HTTP_400_BAD_REQUEST)
            image = PostImage(post=post, width=width, height=height, position=index)
            image.image.save(content.name, content, save=True)

        post = self.base_queryset().get(pk=post.pk)
        data = PostDetailSerializer(post, context=self.get_serializer_context()).data
        return Response(data, status=status.HTTP_201_CREATED)

    def partial_update(self, request, *args, **kwargs):
        post = self.get_object()
        serializer = PostUpdateSerializer(post, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        serializer.save()
        post = self.base_queryset().get(pk=post.pk)
        return Response(PostDetailSerializer(post, context=self.get_serializer_context()).data)

    @action(detail=False, methods=["get"])
    def map(self, request):
        """Up to 300 posts inside the visible map area, without paging."""
        bbox = request.query_params.get("bbox", "")
        queryset = self.get_queryset()
        if bbox:
            try:
                min_lng, min_lat, max_lng, max_lat = (float(v) for v in bbox.split(","))
            except ValueError:
                raise ValidationError({"bbox": "Use bbox=minLng,minLat,maxLng,maxLat."})
            if not all(math.isfinite(v) for v in (min_lng, min_lat, max_lng, max_lat)):
                raise ValidationError({"bbox": "Use bbox=minLng,minLat,maxLng,maxLat."})
            min_lat, max_lat = max(min_lat, -90.0), min(max_lat, 90.0)
            if min_lng < -180 or max_lng > 180 or min_lng >= max_lng:
                # Zoomed out past the edge of the world map: search every longitude.
                min_lng, max_lng = -180.0, 180.0
            if min_lat < max_lat:
                area = Polygon.from_bbox((min_lng, min_lat, max_lng, max_lat))
                area.srid = 4326
                # Compare as flat geometry. On the geography type a big box is
                # read as a shape on the globe, which errors or matches nothing
                # once the map is zoomed out.
                queryset = queryset.annotate(
                    public_geom=Cast("public_location", PointField(srid=4326))
                ).filter(public_geom__intersects=area)
        serializer = PostListSerializer(queryset[:300], many=True, context=self.get_serializer_context())
        return Response(serializer.data)

    @action(detail=True, methods=["post"], permission_classes=[permissions.IsAuthenticated])
    def vote(self, request, pk=None):
        """Toggle an upvote. Upvotes push a post up the feed so more people see it."""
        post = self._post(pk)
        with transaction.atomic():
            # get_or_create so a double tap can't raise a duplicate-vote error.
            vote, created = Vote.objects.get_or_create(post=post, user=request.user)
            if created:
                voted = True
            else:
                vote.delete()
                voted = False
            post.score = post.votes.count()
            post.save(update_fields=["score", "updated_at"])
        return Response({"has_voted": voted, "score": post.score})

    @action(detail=True, methods=["get", "post"])
    def comments(self, request, pk=None):
        post = self._post(pk)
        if request.method == "GET":
            comments = post.comments.select_related("author", "post")
            return Response(CommentSerializer(comments, many=True).data)
        if not request.user.is_authenticated:
            raise PermissionDenied("Log in to comment.")
        serializer = CommentSerializer(data=request.data, context={"post": post})
        serializer.is_valid(raise_exception=True)
        comment = serializer.save(post=post, author=request.user)
        return Response(CommentSerializer(comment).data, status=status.HTTP_201_CREATED)

    @action(detail=True, methods=["get", "post"], permission_classes=[permissions.IsAuthenticated])
    def claims(self, request, pk=None):
        """
        GET:  the finder sees every claim; anyone else sees only their own.
        POST: an owner claims a "kept it with me" item by answering the question.
        """
        post = self._post(pk)
        if request.method == "GET":
            claims = post.claims.select_related("claimant", "post")
            if post.author_id != request.user.pk:
                claims = claims.filter(claimant=request.user)
            return Response(ClaimSerializer(claims, many=True).data)

        if post.author_id == request.user.pk:
            raise ValidationError({"detail": "You can't claim your own post."})
        if not post.claims_enabled:
            raise ValidationError({"detail": "Claims are only for items the finder kept. Follow the guidance on the post."})
        if post.status != Post.Status.OPEN:
            raise ValidationError({"detail": "This item has already been claimed."})
        serializer = ClaimCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            with transaction.atomic():
                claim = serializer.save(post=post, claimant=request.user)
        except IntegrityError:
            raise ValidationError({"detail": "You've already sent a claim for this item."})
        return Response(ClaimSerializer(claim).data, status=status.HTTP_201_CREATED)

    @action(detail=True, methods=["post"], permission_classes=[permissions.IsAuthenticated])
    def resolve(self, request, pk=None):
        """Author marks the item as back with its owner."""
        post = self._post(pk)
        if post.author_id != request.user.pk:
            raise PermissionDenied("Only the person who posted this can mark it returned.")
        post.status = Post.Status.RETURNED
        post.save(update_fields=["status", "updated_at"])
        return Response({"status": post.status})

    @action(detail=True, methods=["post"], permission_classes=[permissions.IsAuthenticated])
    def renew(self, request, pk=None):
        """Keep a post in the feed for another lifetime period."""
        post = self._post(pk)
        if post.author_id != request.user.pk:
            raise PermissionDenied("Only the person who posted this can renew it.")
        post.renew()
        return Response({"expires_at": post.expires_at})

    @action(detail=True, methods=["post"], permission_classes=[permissions.IsAuthenticated])
    def report(self, request, pk=None):
        post = self._post(pk)
        if post.author_id == request.user.pk:
            raise ValidationError({"detail": "You can't report your own post."})
        serializer = ReportSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            with transaction.atomic():
                serializer.save(post=post, reporter=request.user)
        except IntegrityError:
            raise ValidationError({"detail": "You've already reported this post."})
        if post.reports.count() >= settings.FTL["AUTO_HIDE_REPORTS"] and post.status != Post.Status.HIDDEN:
            post.status = Post.Status.HIDDEN
            post.save(update_fields=["status", "updated_at"])
        return Response({"detail": "Thanks. Our moderators will take a look."}, status=status.HTTP_201_CREATED)


class ClaimViewSet(mixins.RetrieveModelMixin, viewsets.GenericViewSet):
    serializer_class = ClaimSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        user = self.request.user
        return Claim.objects.select_related("post", "claimant").filter(Q(claimant=user) | Q(post__author=user))

    @action(detail=True, methods=["post"])
    def decide(self, request, pk=None):
        claim = self.get_object()
        if claim.post.author_id != request.user.pk:
            raise PermissionDenied("Only the finder can approve or reject claims.")
        if claim.status != Claim.Status.PENDING:
            raise ValidationError({"detail": "This claim has already been decided."})
        serializer = ClaimDecisionSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        with transaction.atomic():
            post = Post.objects.select_for_update().get(pk=claim.post_id)
            if serializer.validated_data["decision"] == "approve":
                if post.claims.filter(status=Claim.Status.APPROVED).exists():
                    raise ValidationError({"detail": "You've already approved another claim for this item."})
                claim.status = Claim.Status.APPROVED
                post.status = Post.Status.CLAIMED
                post.save(update_fields=["status", "updated_at"])
            else:
                claim.status = Claim.Status.REJECTED
            claim.finder_response = serializer.validated_data.get("response", "").strip()
            claim.decided_at = timezone.now()
            claim.save(update_fields=["status", "finder_response", "decided_at"])
        return Response(ClaimSerializer(claim).data)

    @action(detail=True, methods=["post"])
    def revoke(self, request, pk=None):
        """
        The finder takes back an approval (wrong person, no-show, answer turned
        out to be a lucky guess). The claimant loses access to the exact
        location and the item is open for claims again.
        """
        claim = self.get_object()
        if claim.post.author_id != request.user.pk:
            raise PermissionDenied("Only the finder can cancel an approval.")
        reason = str(request.data.get("response", "") if hasattr(request.data, "get") else "").strip()[:1000]
        with transaction.atomic():
            post = Post.objects.select_for_update().get(pk=claim.post_id)
            claim.refresh_from_db()
            if claim.status != Claim.Status.APPROVED:
                raise ValidationError({"detail": "Only an approved claim can be cancelled."})
            if post.status == Post.Status.RETURNED:
                raise ValidationError({"detail": "This item is already marked as returned."})
            claim.status = Claim.Status.REVOKED
            claim.finder_response = reason or "The finder cancelled this approval."
            claim.decided_at = timezone.now()
            claim.save(update_fields=["status", "finder_response", "decided_at"])
            post.status = Post.Status.OPEN
            post.save(update_fields=["status", "updated_at"])
        return Response(ClaimSerializer(claim).data)

    @action(detail=True, methods=["post"])
    def withdraw(self, request, pk=None):
        claim = self.get_object()
        if claim.claimant_id != request.user.pk:
            raise PermissionDenied("Only the person who sent the claim can withdraw it.")
        # Only waiting claims can be withdrawn. Otherwise a rejected claimant
        # could withdraw and claim again as often as they like.
        if claim.status != Claim.Status.PENDING:
            raise ValidationError({"detail": "This claim has already been decided."})
        claim.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


class MyPostsViewSet(viewsets.ReadOnlyModelViewSet):
    """The signed-in user's own posts, including returned and hidden ones."""

    serializer_class = MyPostSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        return annotate_for_user(Post.objects.filter(author=self.request.user), self.request.user).annotate(
            pending_claims=Count("claims", filter=Q(claims__status=Claim.Status.PENDING), distinct=True)
        )


class MyClaimsViewSet(viewsets.ReadOnlyModelViewSet):
    serializer_class = ClaimSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        return Claim.objects.select_related("post", "claimant").filter(claimant=self.request.user)


@api_view(["GET"])
@authentication_classes([])  # public; a stale saved token must not break it
@permission_classes([permissions.AllowAny])
def meta(request):
    """Choices and guidance the app shows in its forms, kept in one place."""
    return Response(
        {
            "categories": [{"value": v, "label": l} for v, l in Category.choices],
            "handover_options": [
                {"value": v, "label": l, "guidance": HANDOVER_GUIDANCE[Handover(v)]}
                for v, l in Handover.choices
            ],
            "report_reasons": [{"value": v, "label": l} for v, l in Report.Reason.choices],
            "approx_radius_m": settings.FTL["APPROX_RADIUS_M"],
            "max_images": settings.FTL["MAX_IMAGES_PER_POST"],
            "post_lifetime_days": settings.FTL["POST_LIFETIME_DAYS"],
        }
    )


def health(request):
    """
    Uptime check: answers 200 only if the database answers too. Pinging it
    every few minutes keeps a free Render server from sleeping and a free
    Supabase database from pausing. Plain Django view: no auth, no throttle.
    """
    from django.db import connection
    from django.http import JsonResponse

    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()
    except Exception:
        return JsonResponse({"status": "database unavailable"}, status=503)
    return JsonResponse({"status": "ok"})
