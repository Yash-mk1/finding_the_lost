import io
import json
import math

from django.contrib.auth import get_user_model
from django.contrib.gis.geos import Point
from django.core.files.uploadedfile import SimpleUploadedFile
from django.core.cache import cache
from PIL import Image
from rest_framework.test import APITestCase

from .models import Claim, Handover, Post

User = get_user_model()
BANGALORE = (12.9716, 77.5946)


def photo_with_gps(name="item.jpg", size=(1200, 900)):
    """A JPEG carrying EXIF GPS data, like a real phone photo."""
    img = Image.new("RGB", size, "#3366aa")
    exif = Image.Exif()
    exif[0x010F] = "PhoneMaker"  # Make
    exif[0x8825] = {1: "N", 2: (12.0, 58.0, 17.0), 3: "E", 4: (77.0, 35.0, 40.0)}  # GPSInfo
    buffer = io.BytesIO()
    img.save(buffer, format="JPEG", exif=exif)
    return SimpleUploadedFile(name, buffer.getvalue(), content_type="image/jpeg")


def metres_between(a, b):
    lng1, lat1, lng2, lat2 = map(math.radians, (a[1], a[0], b[1], b[0]))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lng2 - lng1) / 2) ** 2
    return 2 * 6_371_000 * math.asin(math.sqrt(h))


class ApiTestCase(APITestCase):
    def setUp(self):
        cache.clear()  # throttle counters live in the cache
        self.finder = self.register("finder")
        self.owner = self.register("owner")
        self.stranger = self.register("stranger")

    def register(self, username):
        response = self.client.post("/api/auth/register/", {
            "username": username, "email": f"{username}@example.com", "password": "a-strong-pass-42",
        })
        self.assertEqual(response.status_code, 201, response.data)
        return {"token": response.data["token"], "id": response.data["user"]["id"]}

    def as_user(self, who):
        self.client.credentials(HTTP_AUTHORIZATION=f"Token {who['token']}")

    def anonymous(self):
        self.client.credentials()

    def create_found(self, who=None, handover=Handover.KEPT, lat=BANGALORE[0], lng=BANGALORE[1], **extra):
        self.as_user(who or self.finder)
        data = {
            "post_type": "found", "title": "Black phone", "category": "electronics",
            "latitude": lat, "longitude": lng, "accuracy_m": 8, "landmark": "Near Gate 2",
            "handover": handover, "images": [photo_with_gps()],
        }
        if handover == Handover.KEPT:
            data["verification_question"] = "What is the wallpaper?"
        if handover in (Handover.POLICE, Handover.DESK):
            data["handover_details"] = "Rajajinagar Police Station"
        data.update(extra)
        response = self.client.post("/api/posts/", data, format="multipart")
        self.assertEqual(response.status_code, 201, response.data)
        return response.data


class AuthTests(ApiTestCase):
    def test_login_with_username_or_email(self):
        self.anonymous()
        for identifier in ("finder", "finder@example.com"):
            response = self.client.post("/api/auth/login/", {"username": identifier, "password": "a-strong-pass-42"})
            self.assertEqual(response.status_code, 200)
            self.assertIn("token", response.data)

    def test_wrong_password(self):
        response = self.client.post("/api/auth/login/", {"username": "finder", "password": "nope"})
        self.assertEqual(response.status_code, 400)

    def test_duplicate_username_rejected(self):
        response = self.client.post("/api/auth/register/", {
            "username": "Finder", "email": "x@example.com", "password": "a-strong-pass-42",
        })
        self.assertEqual(response.status_code, 400)


class PostCreationTests(ApiTestCase):
    def test_photo_metadata_is_stripped_and_resized(self):
        post = self.create_found(handover=Handover.POLICE)
        stored = Post.objects.get(pk=post["id"]).images.first()
        with stored.image.open("rb") as handle:
            img = Image.open(handle)
            self.assertEqual(len(img.getexif()), 0, "EXIF (including GPS) must be removed")
            self.assertLessEqual(max(img.size), 1600)

    def test_found_post_requires_photo_handover_and_landmark(self):
        self.as_user(self.finder)
        response = self.client.post("/api/posts/", {
            "post_type": "found", "title": "Keys", "category": "keys", "latitude": 12.9, "longitude": 77.5,
        }, format="multipart")
        self.assertEqual(response.status_code, 400)
        for field in ("images", "handover", "landmark"):
            self.assertIn(field, response.data)

    def test_kept_needs_verification_question(self):
        self.as_user(self.finder)
        response = self.client.post("/api/posts/", {
            "post_type": "found", "title": "Watch", "category": "jewellery", "latitude": 12.9, "longitude": 77.5,
            "landmark": "Library", "handover": "kept", "images": [photo_with_gps()],
        }, format="multipart")
        self.assertEqual(response.status_code, 400)
        self.assertIn("verification_question", response.data)

    def test_police_needs_station_name(self):
        self.as_user(self.finder)
        response = self.client.post("/api/posts/", {
            "post_type": "found", "title": "Wallet", "category": "wallet", "latitude": 12.9, "longitude": 77.5,
            "landmark": "Bus stop", "handover": "police", "images": [photo_with_gps()],
        }, format="multipart")
        self.assertEqual(response.status_code, 400)
        self.assertIn("handover_details", response.data)

    def test_documents_must_be_blurred(self):
        self.as_user(self.finder)
        base = {
            "post_type": "found", "title": "Aadhaar card", "category": "documents", "latitude": 12.9,
            "longitude": 77.5, "landmark": "Metro", "handover": "police", "handover_details": "Station",
        }
        response = self.client.post("/api/posts/", {**base, "images": [photo_with_gps()]}, format="multipart")
        self.assertEqual(response.status_code, 400)
        self.assertIn("blur_regions", response.data)

        regions = json.dumps([[{"x": 0.1, "y": 0.4, "w": 0.6, "h": 0.2}]])
        response = self.client.post(
            "/api/posts/", {**base, "images": [photo_with_gps()], "blur_regions": regions}, format="multipart"
        )
        self.assertEqual(response.status_code, 201, response.data)

    def test_lost_post_without_photo(self):
        self.as_user(self.owner)
        response = self.client.post("/api/posts/", {
            "post_type": "lost", "title": "Lost umbrella", "category": "other",
            "latitude": 12.9, "longitude": 77.5, "handover": "kept",
        }, format="multipart")
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data["handover"], "")

    def test_anonymous_cannot_post(self):
        self.anonymous()
        response = self.client.post("/api/posts/", {"post_type": "lost"}, format="multipart")
        self.assertEqual(response.status_code, 401)


class LocationPrivacyTests(ApiTestCase):
    def test_kept_item_location_is_approximate_for_public(self):
        post = self.create_found(handover=Handover.KEPT)
        self.anonymous()
        public = self.client.get(f"/api/posts/{post['id']}/").data
        self.assertTrue(public["location_is_approximate"])
        self.assertIsNone(public["accuracy_m"])
        moved = metres_between(BANGALORE, (public["latitude"], public["longitude"]))
        self.assertGreater(moved, 50)
        self.assertLess(moved, 260)

        # The finder still sees the exact point.
        self.as_user(self.finder)
        mine = self.client.get(f"/api/posts/{post['id']}/").data
        self.assertFalse(mine["location_is_approximate"])
        self.assertAlmostEqual(mine["latitude"], BANGALORE[0], places=5)

    def test_public_location_is_stable(self):
        post = self.create_found(handover=Handover.KEPT)
        self.anonymous()
        first = self.client.get(f"/api/posts/{post['id']}/").data
        second = self.client.get(f"/api/posts/{post['id']}/").data
        self.assertEqual((first["latitude"], first["longitude"]), (second["latitude"], second["longitude"]))

    def test_left_there_location_is_exact(self):
        post = self.create_found(handover=Handover.LEFT_THERE)
        self.anonymous()
        data = self.client.get(f"/api/posts/{post['id']}/").data
        self.assertFalse(data["location_is_approximate"])
        self.assertAlmostEqual(data["latitude"], BANGALORE[0], places=5)

    def test_approved_claimant_sees_exact_location(self):
        post = self.create_found(handover=Handover.KEPT)
        self.as_user(self.owner)
        claim = self.client.post(f"/api/posts/{post['id']}/claims/", {"answer": "A beach"}).data
        self.as_user(self.finder)
        self.client.post(f"/api/claims/{claim['id']}/decide/", {"decision": "approve", "response": "Gate 2, 5 pm"})
        self.as_user(self.owner)
        data = self.client.get(f"/api/posts/{post['id']}/").data
        self.assertFalse(data["location_is_approximate"])


class FeedTests(ApiTestCase):
    def test_near_me_filters_by_radius_and_sorts_by_distance(self):
        near = self.create_found(handover=Handover.LEFT_THERE, lat=12.9720, lng=77.5950, title="Near")
        mid = self.create_found(handover=Handover.LEFT_THERE, lat=12.9900, lng=77.5946, title="Mid")
        self.create_found(handover=Handover.LEFT_THERE, lat=13.3, lng=77.6, title="Far")  # ~36 km away
        self.anonymous()
        response = self.client.get("/api/posts/", {"lat": BANGALORE[0], "lng": BANGALORE[1], "radius_km": 5})
        ids = [p["id"] for p in response.data["results"]]
        self.assertEqual(ids, [near["id"], mid["id"]])
        self.assertIsNotNone(response.data["results"][0]["distance_m"])

    def test_type_and_category_filters(self):
        self.create_found(handover=Handover.LEFT_THERE)
        self.as_user(self.owner)
        self.client.post("/api/posts/", {
            "post_type": "lost", "title": "Lost keys", "category": "keys", "latitude": 12.97, "longitude": 77.59,
        }, format="multipart")
        self.anonymous()
        lost = self.client.get("/api/posts/", {"type": "lost"}).data["results"]
        self.assertEqual([p["title"] for p in lost], ["Lost keys"])
        keys = self.client.get("/api/posts/", {"category": "keys"}).data["results"]
        self.assertEqual(len(keys), 1)

    def test_map_bbox(self):
        self.create_found(handover=Handover.LEFT_THERE, lat=12.97, lng=77.59)
        self.create_found(handover=Handover.LEFT_THERE, lat=28.61, lng=77.21)  # Delhi
        self.anonymous()
        data = self.client.get("/api/posts/map/", {"bbox": "77.4,12.8,77.8,13.1"}).data
        self.assertEqual(len(data), 1)

    def test_returned_posts_leave_the_feed(self):
        post = self.create_found(handover=Handover.LEFT_THERE)
        self.as_user(self.finder)
        self.client.post(f"/api/posts/{post['id']}/resolve/")
        self.anonymous()
        self.assertEqual(self.client.get("/api/posts/").data["count"], 0)
        self.assertEqual(self.client.get("/api/posts/", {"include_returned": 1}).data["count"], 1)


class ClaimTests(ApiTestCase):
    def test_full_claim_flow(self):
        post = self.create_found(handover=Handover.KEPT)

        self.as_user(self.owner)
        response = self.client.post(f"/api/posts/{post['id']}/claims/", {"answer": "A beach", "message": "Mine!"})
        self.assertEqual(response.status_code, 201)
        claim_id = response.data["id"]
        # One claim per person.
        self.assertEqual(self.client.post(f"/api/posts/{post['id']}/claims/", {"answer": "x"}).status_code, 400)
        # The owner can't decide their own claim.
        self.assertEqual(self.client.post(f"/api/claims/{claim_id}/decide/", {"decision": "approve"}).status_code, 403)

        # A stranger's claim is visible only to them and the finder.
        self.as_user(self.stranger)
        self.client.post(f"/api/posts/{post['id']}/claims/", {"answer": "A dog"})
        self.assertEqual(len(self.client.get(f"/api/posts/{post['id']}/claims/").data), 1)

        self.as_user(self.finder)
        self.assertEqual(len(self.client.get(f"/api/posts/{post['id']}/claims/").data), 2)
        # Approving needs a meetup message.
        self.assertEqual(self.client.post(f"/api/claims/{claim_id}/decide/", {"decision": "approve"}).status_code, 400)
        response = self.client.post(
            f"/api/claims/{claim_id}/decide/", {"decision": "approve", "response": "Gate 2 at 5 pm"}
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(Post.objects.get(pk=post["id"]).status, Post.Status.CLAIMED)

        self.as_user(self.owner)
        mine = self.client.get("/api/me/claims/").data["results"]
        self.assertEqual(mine[0]["status"], Claim.Status.APPROVED)
        self.assertEqual(mine[0]["finder_response"], "Gate 2 at 5 pm")

    def test_cannot_claim_items_not_kept(self):
        post = self.create_found(handover=Handover.POLICE)
        self.as_user(self.owner)
        response = self.client.post(f"/api/posts/{post['id']}/claims/", {"answer": "x"})
        self.assertEqual(response.status_code, 400)

    def test_finder_cannot_claim_own_post(self):
        post = self.create_found(handover=Handover.KEPT)
        self.as_user(self.finder)
        self.assertEqual(self.client.post(f"/api/posts/{post['id']}/claims/", {"answer": "x"}).status_code, 400)


class CommunityTests(ApiTestCase):
    def test_vote_toggles(self):
        post = self.create_found(handover=Handover.LEFT_THERE)
        self.as_user(self.owner)
        self.assertEqual(self.client.post(f"/api/posts/{post['id']}/vote/").data, {"has_voted": True, "score": 1})
        self.assertEqual(self.client.post(f"/api/posts/{post['id']}/vote/").data, {"has_voted": False, "score": 0})

    def test_threaded_comments(self):
        post = self.create_found(handover=Handover.LEFT_THERE)
        self.as_user(self.owner)
        parent = self.client.post(f"/api/posts/{post['id']}/comments/", {"body": "Is it still there?"}).data
        self.as_user(self.finder)
        reply = self.client.post(
            f"/api/posts/{post['id']}/comments/", {"body": "Yes, on the gate.", "parent": parent["id"]}
        ).data
        self.assertEqual(reply["parent"], parent["id"])
        self.assertTrue(reply["is_post_author"])
        self.anonymous()
        self.assertEqual(len(self.client.get(f"/api/posts/{post['id']}/comments/").data), 2)

    def test_three_reports_hide_a_post(self):
        post = self.create_found(handover=Handover.LEFT_THERE)
        for name in ("reporter1", "reporter2", "reporter3"):
            self.as_user(self.register(name))
            self.client.post(f"/api/posts/{post['id']}/report/", {"reason": "scam"})
        self.anonymous()
        self.assertEqual(self.client.get(f"/api/posts/{post['id']}/").status_code, 404)
        # The author still sees it.
        self.as_user(self.finder)
        self.assertEqual(self.client.get(f"/api/posts/{post['id']}/").data["status"], "hidden")

    def test_only_author_can_edit_or_delete(self):
        post = self.create_found(handover=Handover.LEFT_THERE)
        self.as_user(self.stranger)
        self.assertEqual(self.client.patch(f"/api/posts/{post['id']}/", {"title": "Mine now"}).status_code, 403)
        self.assertEqual(self.client.delete(f"/api/posts/{post['id']}/").status_code, 403)
        self.as_user(self.finder)
        self.assertEqual(self.client.patch(f"/api/posts/{post['id']}/", {"title": "Black phone (Samsung)"}).status_code, 200)

    def test_meta(self):
        data = self.client.get("/api/meta/").data
        self.assertEqual(len(data["handover_options"]), 4)
        self.assertTrue(all(option["guidance"] for option in data["handover_options"]))
