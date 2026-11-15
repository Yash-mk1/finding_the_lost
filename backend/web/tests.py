"""Tests for the website and the webpiov2 security layer."""
import importlib

from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import clear_url_caches, reverse

from lostfound.models import Handover
from lostfound.tests import ApiTestCase, photo_with_gps

from .models import ClientHit
from .throttling import client_token

User = get_user_model()


class WebsiteTests(TestCase):
    def test_home_page_serves_the_app_with_a_strict_policy(self):
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        html = response.content.decode()
        self.assertIn("web/app.js", html)
        self.assertIn("leaflet.js", html)
        csp = response["Content-Security-Policy"]
        self.assertIn("script-src 'self'", csp)
        self.assertNotIn("unsafe-eval", csp)
        self.assertIn("frame-ancestors 'none'", csp)

    def test_static_files_are_served(self):
        for path in ("/static/web/app.js", "/static/web/app.css", "/static/web/icons.js", "/static/web/vendor/leaflet/leaflet.js"):
            response = self.client.get(path)
            self.assertEqual(response.status_code, 200, path)

    def test_api_still_works_next_to_the_site(self):
        self.assertEqual(self.client.get("/api/meta/").status_code, 200)
        self.assertEqual(self.client.get("/api/health/").status_code, 200)


class HoneypotTests(ApiTestCase):
    """Every public form refuses a request with the hidden `website` field filled."""

    def assertBlocked(self, response):
        self.assertEqual(response.status_code, 400, getattr(response, "data", response.content))
        self.assertEqual(response.data["code"], "honeypot")
        self.assertIn("Leave this field empty", response.data["detail"])  # tells a real person what to do

    def test_signup_and_login(self):
        self.anonymous()
        self.assertBlocked(self.client.post("/api/auth/register/", {
            "username": "botty", "email": "bot@example.com", "password": "a-strong-pass-42", "website": "http://spam.example"}))
        self.assertFalse(User.objects.filter(username="botty").exists())
        self.assertBlocked(self.client.post("/api/auth/login/", {"username": "finder", "password": "a-strong-pass-42", "website": "x"}))
        # An empty honeypot (what the website sends) is fine.
        ok = self.client.post("/api/auth/login/", {"username": "finder", "password": "a-strong-pass-42", "website": ""})
        self.assertEqual(ok.status_code, 200)

    def test_post_comment_claim_report(self):
        self.as_user(self.finder)
        response = self.client.post("/api/posts/", {
            "post_type": "found", "title": "Phone", "category": "electronics", "latitude": 12.97, "longitude": 77.59,
            "landmark": "Gate 2", "handover": Handover.LEFT_THERE, "images": [photo_with_gps()], "website": "x"}, format="multipart")
        self.assertBlocked(response)
        post = self.create_found()
        self.as_user(self.owner)
        self.assertBlocked(self.client.post(f"/api/posts/{post['id']}/comments/", {"body": "mine", "website": "x"}))
        self.assertBlocked(self.client.post(f"/api/posts/{post['id']}/claims/", {"answer": "cat", "website": "x"}))
        self.assertBlocked(self.client.post(f"/api/posts/{post['id']}/report/", {"reason": "spam", "website": "x"}))
        # Same requests without the honeypot go through.
        self.assertEqual(self.client.post(f"/api/posts/{post['id']}/comments/", {"body": "mine", "website": ""}).status_code, 201)
        self.assertEqual(self.client.post(f"/api/posts/{post['id']}/claims/", {"answer": "cat"}).status_code, 201)


@override_settings(REST_FRAMEWORK={**settings.REST_FRAMEWORK, "DEFAULT_THROTTLE_RATES": {
    **settings.REST_FRAMEWORK["DEFAULT_THROTTLE_RATES"], "comment": "3/hour"}})
class DatabaseThrottleTests(ApiTestCase):
    def test_limit_holds_across_workers_and_counts_bad_requests(self):
        post = self.create_found()
        self.as_user(self.owner)
        url = f"/api/posts/{post['id']}/comments/"
        self.assertEqual(self.client.post(url, {"body": "one"}).status_code, 201)
        self.assertEqual(self.client.post(url, {"body": ""}).status_code, 400)  # invalid, still counted
        cache.clear()  # what a second gunicorn worker (or a restart) would see
        self.assertEqual(self.client.post(url, {"body": "three"}).status_code, 201)
        cache.clear()
        blocked = self.client.post(url, {"body": "four"})
        self.assertEqual(blocked.status_code, 429)
        # Reading is never limited by this throttle.
        self.assertEqual(self.client.get(url).status_code, 200)

    def test_addresses_are_stored_hashed(self):
        self.anonymous()
        self.client.post("/api/auth/login/", {"username": "x", "password": "y"}, REMOTE_ADDR="203.0.113.7")
        hits = list(ClientHit.objects.values_list("client", flat=True))
        self.assertTrue(hits)
        self.assertFalse(any("203.0.113.7" in h for h in hits))
        self.assertTrue(all(len(h) == 64 for h in hits))

    def test_forwarded_for_is_used_behind_the_proxy(self):
        class Req:
            META = {"HTTP_X_FORWARDED_FOR": "198.51.100.4, 10.0.0.1", "REMOTE_ADDR": "10.0.0.1"}
            user = None

        class Req2(Req):
            META = {"HTTP_X_FORWARDED_FOR": "198.51.100.5, 10.0.0.1", "REMOTE_ADDR": "10.0.0.1"}

        self.assertNotEqual(client_token(Req), client_token(Req2))


class LockoutTests(ApiTestCase):
    def fail(self, username, ip="198.51.100.10"):
        return self.client.post("/api/auth/login/", {"username": username, "password": "wrong"}, HTTP_X_FORWARDED_FOR=ip)

    def test_five_failures_lock_that_name_from_that_address(self):
        self.anonymous()
        for _ in range(settings.AXES_FAILURE_LIMIT - 1):
            self.assertEqual(self.fail("finder").status_code, 400)
        self.assertEqual(self.fail("finder").status_code, 429)  # the 5th failure locks
        locked = self.client.post("/api/auth/login/", {"username": "finder", "password": "a-strong-pass-42"},
                                  HTTP_X_FORWARDED_FOR="198.51.100.10")
        self.assertEqual(locked.status_code, 429)
        self.assertEqual(locked.json()["code"], "locked_out")
        # Someone else on the same network is not locked out...
        other = self.client.post("/api/auth/login/", {"username": "owner", "password": "a-strong-pass-42"},
                                 HTTP_X_FORWARDED_FOR="198.51.100.10")
        self.assertEqual(other.status_code, 200)
        # ...and the real owner from another address still gets in.
        home = self.client.post("/api/auth/login/", {"username": "finder", "password": "a-strong-pass-42"},
                                HTTP_X_FORWARDED_FOR="203.0.113.50")
        self.assertEqual(home.status_code, 200)

    def test_a_typo_then_success_resets_the_count(self):
        self.anonymous()
        for _ in range(settings.AXES_FAILURE_LIMIT - 1):
            self.fail("finder")
        ok = self.client.post("/api/auth/login/", {"username": "finder", "password": "a-strong-pass-42"},
                              HTTP_X_FORWARDED_FOR="198.51.100.10")
        self.assertEqual(ok.status_code, 200)
        self.assertEqual(self.fail("finder").status_code, 400)  # counting starts again

    def test_admin_login_locks_out(self):
        User.objects.create_superuser("boss", "boss@example.com", "boss-pass-123")
        url = reverse("admin:login")
        for _ in range(settings.AXES_FAILURE_LIMIT):
            self.client.post(url, {"username": "boss", "password": "nope"}, HTTP_X_FORWARDED_FOR="198.51.100.20")
        locked = self.client.post(url, {"username": "boss", "password": "boss-pass-123"}, HTTP_X_FORWARDED_FOR="198.51.100.20")
        self.assertEqual(locked.status_code, 429)


class AdminUrlTests(TestCase):
    def reload_urls(self):
        import config.urls

        clear_url_caches()
        importlib.reload(config.urls)

    def tearDown(self):
        self.reload_urls()

    def test_admin_moves_with_the_setting(self):
        with override_settings(ADMIN_URL="desk-test42/"):
            self.reload_urls()
            self.assertEqual(reverse("admin:index"), "/desk-test42/")
            self.assertEqual(self.client.get("/desk-test42/").status_code, 302)  # to its login page
            self.assertEqual(self.client.get("/admin/").status_code, 404)
