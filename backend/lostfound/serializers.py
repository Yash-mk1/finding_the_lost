import json
import math

from django.conf import settings
from django.contrib.gis.geos import Point
from rest_framework import serializers

from .models import Category, Claim, Comment, Handover, Post, PostImage, Report


def haversine_m(a, b):
    """Distance in metres between two (lng, lat) points."""
    lng1, lat1, lng2, lat2 = map(math.radians, (a.x, a.y, b.x, b.y))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lng2 - lng1) / 2) ** 2
    return 2 * 6_371_000 * math.asin(math.sqrt(h))


class AuthorSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    username = serializers.CharField()
    display_name = serializers.SerializerMethodField()

    def get_display_name(self, user):
        return user.first_name or user.username


class PostImageSerializer(serializers.ModelSerializer):
    url = serializers.SerializerMethodField()

    class Meta:
        model = PostImage
        fields = ["id", "url", "width", "height"]

    def get_url(self, obj):
        request = self.context.get("request")
        url = obj.image.url
        return request.build_absolute_uri(url) if request else url


class PostListSerializer(serializers.ModelSerializer):
    author = AuthorSerializer(read_only=True)
    author_returned_count = serializers.IntegerField(read_only=True, default=0)
    category_label = serializers.CharField(source="get_category_display", read_only=True)
    handover_label = serializers.CharField(source="get_handover_display", read_only=True)
    latitude = serializers.SerializerMethodField()
    longitude = serializers.SerializerMethodField()
    location_is_approximate = serializers.SerializerMethodField()
    approx_radius_m = serializers.SerializerMethodField()
    distance_m = serializers.SerializerMethodField()
    thumbnail = serializers.SerializerMethodField()
    comment_count = serializers.IntegerField(read_only=True, default=0)
    has_voted = serializers.BooleanField(read_only=True, default=False)
    is_owner = serializers.SerializerMethodField()

    class Meta:
        model = Post
        fields = [
            "id", "post_type", "title", "description", "category", "category_label",
            "status", "latitude", "longitude", "location_is_approximate", "approx_radius_m",
            "distance_m", "landmark", "occurred_at", "handover", "handover_label",
            "score", "comment_count", "has_voted", "thumbnail", "author",
            "author_returned_count", "is_owner", "created_at", "expires_at",
        ]

    # --- location: exact only for people allowed to see it -----------------
    def _exact_allowed(self, post):
        cache = self.context.setdefault("_exact_cache", {})
        if post.pk not in cache:
            request = self.context.get("request")
            cache[post.pk] = post.can_see_exact_location(getattr(request, "user", None))
        return cache[post.pk]

    def _shown_point(self, post):
        return post.location if self._exact_allowed(post) else post.public_location

    def get_latitude(self, post):
        return round(self._shown_point(post).y, 6)

    def get_longitude(self, post):
        return round(self._shown_point(post).x, 6)

    def get_location_is_approximate(self, post):
        return post.is_approximate and not self._exact_allowed(post)

    def get_approx_radius_m(self, post):
        return settings.FTL["APPROX_RADIUS_M"] if self.get_location_is_approximate(post) else None

    def get_distance_m(self, post):
        origin = self.context.get("origin")
        if origin is None:
            return None
        metres = haversine_m(origin, self._shown_point(post))
        # Rounded so repeated queries can't be used to pin down a point.
        return int(round(metres / 50.0) * 50)

    def get_thumbnail(self, post):
        images = list(post.images.all())
        if not images:
            return None
        return PostImageSerializer(images[0], context=self.context).data["url"]

    def get_is_owner(self, post):
        request = self.context.get("request")
        return bool(request and request.user.is_authenticated and request.user.pk == post.author_id)


class ClaimSerializer(serializers.ModelSerializer):
    claimant = AuthorSerializer(read_only=True)
    post_id = serializers.IntegerField(read_only=True)
    post_title = serializers.CharField(source="post.title", read_only=True)

    class Meta:
        model = Claim
        fields = [
            "id", "post_id", "post_title", "claimant", "answer", "message",
            "status", "finder_response", "created_at", "decided_at",
        ]
        read_only_fields = ["status", "finder_response", "created_at", "decided_at"]


class PostDetailSerializer(PostListSerializer):
    images = PostImageSerializer(many=True, read_only=True)
    guidance = serializers.CharField(read_only=True)
    claims_enabled = serializers.BooleanField(read_only=True)
    accuracy_m = serializers.SerializerMethodField()
    my_claim = serializers.SerializerMethodField()
    pending_claim_count = serializers.SerializerMethodField()

    class Meta(PostListSerializer.Meta):
        fields = PostListSerializer.Meta.fields + [
            "images", "handover_details", "verification_question", "guidance",
            "claims_enabled", "accuracy_m", "my_claim", "pending_claim_count",
        ]

    def get_accuracy_m(self, post):
        return post.accuracy_m if self._exact_allowed(post) else None

    def get_my_claim(self, post):
        request = self.context.get("request")
        if not request or not request.user.is_authenticated:
            return None
        claim = post.claims.filter(claimant=request.user).first()
        return ClaimSerializer(claim, context=self.context).data if claim else None

    def get_pending_claim_count(self, post):
        if not self.get_is_owner(post):
            return None
        return post.claims.filter(status=Claim.Status.PENDING).count()


class PostCreateSerializer(serializers.ModelSerializer):
    latitude = serializers.FloatField(min_value=-90, max_value=90, write_only=True)
    longitude = serializers.FloatField(min_value=-180, max_value=180, write_only=True)
    images = serializers.ListField(
        child=serializers.ImageField(), required=False, write_only=True, allow_empty=True
    )
    # JSON string: one list of {x, y, w, h} fractions per image, in upload order.
    blur_regions = serializers.CharField(required=False, allow_blank=True, write_only=True)

    class Meta:
        model = Post
        fields = [
            "id", "post_type", "title", "description", "category", "latitude", "longitude",
            "accuracy_m", "landmark", "occurred_at", "handover", "handover_details",
            "verification_question", "images", "blur_regions",
        ]

    def validate_blur_regions(self, value):
        if not value:
            return []
        try:
            data = json.loads(value)
        except json.JSONDecodeError:
            raise serializers.ValidationError("Must be a JSON list.")
        if not isinstance(data, list) or not all(isinstance(item, list) for item in data):
            raise serializers.ValidationError("Must be a list with one list of regions per photo.")
        return data

    def validate(self, attrs):
        errors = {}
        post_type = attrs.get("post_type")
        images = attrs.get("images") or []
        regions = attrs.get("blur_regions") or []
        max_images = settings.FTL["MAX_IMAGES_PER_POST"]

        if len(images) > max_images:
            errors["images"] = f"Add at most {max_images} photos."
        if len(regions) > len(images):
            errors["blur_regions"] = "There are more blur lists than photos."

        if post_type == Post.Type.FOUND:
            handover = attrs.get("handover")
            if not images:
                errors["images"] = "Add at least one photo of the item you found."
            if not handover:
                errors["handover"] = "Tell the owner what you did with the item."
            if not attrs.get("landmark", "").strip():
                errors["landmark"] = "Add a landmark; GPS is often off indoors."
            if handover in (Handover.POLICE, Handover.DESK) and not attrs.get("handover_details", "").strip():
                errors["handover_details"] = (
                    "Name the police station." if handover == Handover.POLICE else "Name the desk or office."
                )
            if handover == Handover.KEPT and not attrs.get("verification_question", "").strip():
                errors["verification_question"] = (
                    "Ask something only the owner would know, e.g. 'What is the phone wallpaper?'"
                )
            if attrs.get("category") == Category.DOCUMENTS and images:
                blurred = any(regions[i] for i in range(min(len(regions), len(images))))
                if not blurred:
                    errors["blur_regions"] = "Blur ID numbers, card numbers and addresses before posting documents."
        elif post_type == Post.Type.LOST:
            # Owners describe their own item; finder-only fields don't apply.
            attrs["handover"] = ""
            attrs["handover_details"] = ""
            attrs["verification_question"] = ""

        if errors:
            raise serializers.ValidationError(errors)
        return attrs

    def create(self, validated_data):
        # Images and blur regions are handled by the view after the post exists.
        validated_data.pop("images", None)
        validated_data.pop("blur_regions", None)
        lat = validated_data.pop("latitude")
        lng = validated_data.pop("longitude")
        validated_data["location"] = Point(lng, lat, srid=4326)
        return super().create(validated_data)


class PostUpdateSerializer(serializers.ModelSerializer):
    """Owners can fix wording, not the location or what kind of post it is."""

    class Meta:
        model = Post
        fields = ["title", "description", "landmark", "handover_details", "verification_question"]


class CommentSerializer(serializers.ModelSerializer):
    author = AuthorSerializer(read_only=True)
    is_post_author = serializers.SerializerMethodField()

    class Meta:
        model = Comment
        fields = ["id", "parent", "author", "is_post_author", "body", "created_at"]
        read_only_fields = ["created_at"]

    def get_is_post_author(self, comment):
        return comment.author_id == comment.post.author_id

    def validate_parent(self, parent):
        post = self.context["post"]
        if parent is not None and parent.post_id != post.pk:
            raise serializers.ValidationError("That reply belongs to a different post.")
        return parent

    def validate_body(self, body):
        if not body.strip():
            raise serializers.ValidationError("Write something first.")
        return body.strip()


class ClaimCreateSerializer(serializers.ModelSerializer):
    class Meta:
        model = Claim
        fields = ["answer", "message"]

    def validate_answer(self, value):
        if not value.strip():
            raise serializers.ValidationError("Answer the finder's question.")
        return value.strip()


class ClaimDecisionSerializer(serializers.Serializer):
    decision = serializers.ChoiceField(choices=["approve", "reject"])
    response = serializers.CharField(max_length=1000, required=False, allow_blank=True)

    def validate(self, attrs):
        if attrs["decision"] == "approve" and not attrs.get("response", "").strip():
            raise serializers.ValidationError(
                {"response": "Tell the owner where and when to collect the item."}
            )
        return attrs


class ReportSerializer(serializers.ModelSerializer):
    class Meta:
        model = Report
        fields = ["reason", "details"]


class MyPostSerializer(PostListSerializer):
    pending_claims = serializers.IntegerField(read_only=True, default=0)

    class Meta(PostListSerializer.Meta):
        fields = PostListSerializer.Meta.fields + ["pending_claims"]
