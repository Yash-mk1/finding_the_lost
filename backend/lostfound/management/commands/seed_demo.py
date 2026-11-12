"""
Fill the app with believable demo posts around a point, for screenshots and
the class demo:

    python manage.py seed_demo --lat 12.9716 --lng 77.5946

Every demo user's password is "demo-pass-123". Run with --clear to remove
earlier demo data first.
"""
import io
import random
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.contrib.gis.geos import Point
from django.core.files.base import ContentFile
from django.core.management.base import BaseCommand
from django.utils import timezone
from PIL import Image, ImageDraw

from lostfound.models import Category, Claim, Comment, Handover, Post, PostImage, Vote

User = get_user_model()
DEMO_PASSWORD = "demo-pass-123"

DEMO_USERS = [
    ("asha", "Asha"), ("rahul", "Rahul"), ("meera", "Meera"), ("karthik", "Karthik"), ("sana", "Sana"),
]

FOUND = [
    ("Black wallet near bus stop", Category.WALLET, Handover.POLICE, "Rajajinagar Police Station",
     "Found on the bench at the bus stop, cash inside untouched.", "Bus stop opposite the metro exit", ""),
    ("Blue backpack with laptop", Category.BAG, Handover.DESK, "Mall security desk, ground floor",
     "Left under a food court table around 8 pm.", "Food court, 3rd floor", ""),
    ("Set of keys with red keychain", Category.KEYS, Handover.LEFT_THERE, "",
     "Hung them on the gate so the owner can spot them.", "Park main gate, east side", ""),
    ("Samsung phone, cracked screen", Category.ELECTRONICS, Handover.KEPT, "",
     "Phone is locked, battery low. I'm charging it.", "Near the coffee shop on 2nd Cross",
     "What is the lock screen wallpaper?"),
    ("Silver watch", Category.JEWELLERY, Handover.KEPT, "",
     "Found in the college library, 2nd floor reading room.", "College library, 2nd floor",
     "What is engraved on the back?"),
    ("Grey hoodie", Category.CLOTHING, Handover.LEFT_THERE, "",
     "Folded it and left it on the bench.", "Playground bench near the canteen", ""),
]

LOST = [
    ("Lost: brown leather purse", Category.WALLET, "Has my college ID and a photo inside. Please help!",
     "Between the temple and the vegetable market"),
    ("Lost: AirPods case (white)", Category.ELECTRONICS, "Dropped somewhere on the evening walk.",
     "Lake walking track"),
    ("Lost: golden retriever, answers to Bruno", Category.PET, "Wearing a blue collar. Very friendly.",
     "Near 4th Block park"),
]

COLOURS = ["#4F7CAC", "#C0504D", "#9BBB59", "#8064A2", "#F79646", "#4BACC6", "#7F7F7F"]


def demo_photo(label, colour):
    img = Image.new("RGB", (900, 675), colour)
    draw = ImageDraw.Draw(img)
    draw.rectangle([40, 40, 860, 635], outline="white", width=6)
    draw.text((70, 300), label[:40], fill="white")
    draw.text((70, 340), "Findit - demo photo", fill="white")
    buffer = io.BytesIO()
    img.save(buffer, format="JPEG", quality=85)
    return ContentFile(buffer.getvalue(), name="demo.jpg")


def nearby(lat, lng, max_m):
    rng = random.Random()
    dlat = rng.uniform(-max_m, max_m) / 111_320
    dlng = rng.uniform(-max_m, max_m) / 111_320
    return Point(lng + dlng, lat + dlat, srid=4326)


class Command(BaseCommand):
    help = "Create demo users and posts around a location."

    def add_arguments(self, parser):
        parser.add_argument("--lat", type=float, default=12.9716)
        parser.add_argument("--lng", type=float, default=77.5946)
        parser.add_argument("--spread-m", type=int, default=1500)
        parser.add_argument("--clear", action="store_true")

    def handle(self, *args, **opts):
        usernames = [u for u, _ in DEMO_USERS]
        if opts["clear"]:
            deleted, _ = User.objects.filter(username__in=usernames).delete()
            self.stdout.write(f"Removed {deleted} demo objects.")

        users = []
        for username, name in DEMO_USERS:
            user, created = User.objects.get_or_create(
                username=username, defaults={"email": f"{username}@demo.local", "first_name": name}
            )
            if created:
                user.set_password(DEMO_PASSWORD)
                user.save()
            users.append(user)

        lat, lng, spread = opts["lat"], opts["lng"], opts["spread_m"]
        now = timezone.now()
        posts = []
        for i, (title, cat, handover, details, desc, landmark, question) in enumerate(FOUND):
            post = Post.objects.create(
                author=users[i % len(users)], post_type=Post.Type.FOUND, title=title, description=desc,
                category=cat, location=nearby(lat, lng, spread), accuracy_m=12, landmark=landmark,
                occurred_at=now - timedelta(hours=3 * i + 1), handover=handover,
                handover_details=details, verification_question=question,
            )
            img = PostImage(post=post, width=900, height=675)
            img.image.save("demo.jpg", demo_photo(title, COLOURS[i % len(COLOURS)]), save=True)
            posts.append(post)

        for i, (title, cat, desc, landmark) in enumerate(LOST):
            posts.append(Post.objects.create(
                author=users[(i + 2) % len(users)], post_type=Post.Type.LOST, title=title, description=desc,
                category=cat, location=nearby(lat, lng, spread), landmark=landmark,
                occurred_at=now - timedelta(days=i + 1),
            ))

        # A little activity so the feed looks alive.
        for post in posts:
            for voter in random.sample(users, k=random.randint(0, 3)):
                if voter != post.author:
                    Vote.objects.get_or_create(post=post, user=voter)
            post.score = post.votes.count()
            post.save(update_fields=["score"])
        Comment.objects.create(post=posts[0], author=users[2], body="I think this might be my neighbour's. Tagging him!")
        Comment.objects.create(post=posts[0], author=posts[0].author, body="Sure, it's at the station front desk.")
        phone = posts[3]
        Claim.objects.get_or_create(
            post=phone, claimant=users[4],
            defaults={"answer": "A photo of a beach at sunset", "message": "It's mine, I lost it yesterday evening."},
        )

        self.stdout.write(self.style.SUCCESS(
            f"Created {len(posts)} demo posts around {lat}, {lng}. "
            f"Log in as any of {', '.join(usernames)} with password {DEMO_PASSWORD}."
        ))
