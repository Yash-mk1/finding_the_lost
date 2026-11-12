import math
import secrets
from datetime import timedelta

from django.conf import settings
from django.contrib.gis.db import models
from django.contrib.gis.geos import Point
from django.db.models.signals import post_delete
from django.dispatch import receiver
from django.utils import timezone


def default_expiry():
    return timezone.now() + timedelta(days=settings.FTL["POST_LIFETIME_DAYS"])


class Category(models.TextChoices):
    ELECTRONICS = "electronics", "Phone / electronics"
    WALLET = "wallet", "Wallet / purse"
    KEYS = "keys", "Keys"
    DOCUMENTS = "documents", "ID / documents / cards"
    BAG = "bag", "Bag / backpack"
    JEWELLERY = "jewellery", "Jewellery / watch"
    CLOTHING = "clothing", "Clothing / accessories"
    BOOKS = "books", "Books / stationery"
    PET = "pet", "Pet"
    OTHER = "other", "Other"


class Handover(models.TextChoices):
    LEFT_THERE = "left_there", "Left it where I found it"
    POLICE = "police", "Handed it to the police"
    DESK = "desk", "Gave it to security / a lost-and-found desk"
    KEPT = "kept", "Kept it with me"


# What the owner should do next, for each thing a finder can do with the item.
# The app shows this on every found post so the owner knows where to go.
HANDOVER_GUIDANCE = {
    Handover.LEFT_THERE: (
        "The item was left where it was found. Go to the pinned spot as soon as "
        "you can; it may be moved or picked up by someone else."
    ),
    Handover.POLICE: (
        "The item is with the police. Visit the station named below and carry an "
        "ID or proof of ownership (bill, photo of the item, unlock code)."
    ),
    Handover.DESK: (
        "The item is with a security or lost-and-found desk. Go to the desk named "
        "below; they will usually ask you to describe the item before returning it."
    ),
    Handover.KEPT: (
        "The finder is keeping the item safe. Send a claim and answer their "
        "question. If they approve it, you'll see their message about where to meet. "
        "Meet in a public place and never pay anyone to get your item back."
    ),
}


class Post(models.Model):
    class Type(models.TextChoices):
        FOUND = "found", "Found"
        LOST = "lost", "Lost"

    class Status(models.TextChoices):
        OPEN = "open", "Open"
        CLAIMED = "claimed", "Claimed"
        RETURNED = "returned", "Returned"
        HIDDEN = "hidden", "Hidden for review"

    author = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="posts")
    post_type = models.CharField(max_length=10, choices=Type.choices)
    title = models.CharField(max_length=120)
    description = models.TextField(blank=True)
    category = models.CharField(max_length=20, choices=Category.choices, default=Category.OTHER)

    # Exact point captured on the phone when the photo was taken (WGS84).
    # Only the author (and an approved claimant) ever sees this.
    location = models.PointField(geography=True, srid=4326)
    # What everyone else sees, searches and sorts by. Equal to `location`
    # except for "kept it with me" posts, where it is moved a random distance
    # inside the approximate radius once and then stored, so distance
    # filters can't be used to work out the real spot.
    public_location = models.PointField(geography=True, srid=4326, null=True, blank=True)
    accuracy_m = models.FloatField(null=True, blank=True)
    landmark = models.CharField(max_length=200, blank=True)
    occurred_at = models.DateTimeField(default=timezone.now)

    # Found posts only.
    handover = models.CharField(max_length=20, choices=Handover.choices, blank=True)
    handover_details = models.CharField(
        max_length=200, blank=True, help_text="Police station or desk name, if any."
    )
    verification_question = models.CharField(max_length=200, blank=True)

    status = models.CharField(max_length=10, choices=Status.choices, default=Status.OPEN)
    score = models.IntegerField(default=0)
    expires_at = models.DateTimeField(default=default_expiry)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["status", "expires_at"]),
            models.Index(fields=["post_type", "category"]),
        ]

    def __str__(self):
        return f"[{self.post_type}] {self.title}"

    @property
    def is_approximate(self):
        """Kept-with-me items may sit at the finder's home, so hide the exact spot."""
        return self.post_type == self.Type.FOUND and self.handover == Handover.KEPT

    @property
    def claims_enabled(self):
        return self.post_type == self.Type.FOUND and self.handover == Handover.KEPT

    @property
    def guidance(self):
        if self.post_type != self.Type.FOUND or not self.handover:
            return ""
        return HANDOVER_GUIDANCE[Handover(self.handover)]

    def _fuzzed_point(self):
        radius_m = settings.FTL["APPROX_RADIUS_M"]
        rng = secrets.SystemRandom()
        angle = rng.uniform(0, 2 * math.pi)
        # Between 40% and 90% of the radius, so the real point is never the centre.
        distance = radius_m * rng.uniform(0.4, 0.9)
        lat = self.location.y
        dlat = (distance * math.cos(angle)) / 111_320
        dlng = (distance * math.sin(angle)) / (111_320 * math.cos(math.radians(lat)))
        return Point(self.location.x + dlng, lat + dlat, srid=4326)

    def refresh_public_location(self):
        self.public_location = self._fuzzed_point() if self.is_approximate else self.location

    def save(self, *args, **kwargs):
        if self.public_location is None:
            self.refresh_public_location()
        elif self.pk:
            old = Post.objects.filter(pk=self.pk).values("handover", "location").first()
            if old and (old["handover"] != self.handover or old["location"] != self.location):
                self.refresh_public_location()
                if kwargs.get("update_fields"):
                    kwargs["update_fields"] = set(kwargs["update_fields"]) | {"public_location"}
        super().save(*args, **kwargs)

    def can_see_exact_location(self, user):
        if not self.is_approximate:
            return True
        if not user or not user.is_authenticated:
            return False
        if user.pk == self.author_id:
            return True
        return self.claims.filter(claimant=user, status=Claim.Status.APPROVED).exists()

    def renew(self):
        self.expires_at = default_expiry()
        self.save(update_fields=["expires_at", "updated_at"])


def post_image_path(instance, filename):
    return f"posts/{instance.post_id}/{timezone.now():%Y%m%d%H%M%S%f}.jpg"


class PostImage(models.Model):
    post = models.ForeignKey(Post, on_delete=models.CASCADE, related_name="images")
    image = models.ImageField(upload_to=post_image_path)
    width = models.PositiveIntegerField(default=0)
    height = models.PositiveIntegerField(default=0)
    position = models.PositiveSmallIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["position", "id"]


@receiver(post_delete, sender=PostImage)
def delete_photo_file(sender, instance, **kwargs):
    """Remove the photo from disk when its post (or the photo row) is deleted."""
    if instance.image:
        instance.image.delete(save=False)


class Comment(models.Model):
    post = models.ForeignKey(Post, on_delete=models.CASCADE, related_name="comments")
    author = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="comments")
    parent = models.ForeignKey("self", null=True, blank=True, on_delete=models.CASCADE, related_name="replies")
    body = models.TextField(max_length=2000)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["created_at"]


class Vote(models.Model):
    post = models.ForeignKey(Post, on_delete=models.CASCADE, related_name="votes")
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="votes")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["post", "user"], name="one_vote_per_user")]


class Claim(models.Model):
    class Status(models.TextChoices):
        PENDING = "pending", "Pending"
        APPROVED = "approved", "Approved"
        REJECTED = "rejected", "Rejected"

    post = models.ForeignKey(Post, on_delete=models.CASCADE, related_name="claims")
    claimant = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="claims")
    answer = models.CharField(max_length=300, help_text="Answer to the finder's verification question.")
    message = models.TextField(max_length=1000, blank=True)
    status = models.CharField(max_length=10, choices=Status.choices, default=Status.PENDING)
    # Written by the finder when deciding; on approval this is how they say
    # where and when to meet, without putting a phone number on a public post.
    finder_response = models.TextField(max_length=1000, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    decided_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]
        constraints = [models.UniqueConstraint(fields=["post", "claimant"], name="one_claim_per_user")]


class Report(models.Model):
    class Reason(models.TextChoices):
        SPAM = "spam", "Spam or advertising"
        FAKE = "fake", "Fake or misleading"
        SCAM = "scam", "Scam / asking for money"
        PRIVATE = "private", "Shows private information"
        OFFENSIVE = "offensive", "Offensive content"
        OTHER = "other", "Other"

    post = models.ForeignKey(Post, on_delete=models.CASCADE, related_name="reports")
    reporter = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="reports")
    reason = models.CharField(max_length=20, choices=Reason.choices)
    details = models.CharField(max_length=500, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["post", "reporter"], name="one_report_per_user")]
