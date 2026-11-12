# Finding the Lost

A community lost-and-found app. A finder photographs an item, the phone tags where it was found, and the finder says what they did with it (left it there, gave it to the police, gave it to a desk, or kept it). Owners browse a Reddit-style feed or a map, and claim kept items by answering a question only the real owner would know.

```
finding-the-lost/
├── backend/   Django + Django REST Framework + GeoDjango (PostGIS)
└── app/       Flutter Android app
```

## What's built (MVP)

| Feature | Where |
|---|---|
| Sign up / log in with username or email (token auth) | `backend/accounts`, `app/lib/screens/login_screen.dart` |
| Found posts: camera photo, GPS captured when the photo is taken, draggable pin, required landmark | `create_post_screen.dart` |
| Handover options with owner guidance (left there / police / desk / kept) | `lostfound/models.py` `HANDOVER_GUIDANCE` |
| Lost posts, so owners can post too | same screen, `postType: lost` |
| Feed: near me, newest, top; filters by type, category, distance; search | `feed_screen.dart`, `GET /api/posts/` |
| Map of posts in view, green = found, orange = lost | `map_screen.dart`, `GET /api/posts/map/` |
| Upvotes and threaded comments | `post_detail_screen.dart` |
| Claims with a verification question; finder approves with a private meetup message | `claims_review_screen.dart`, `/api/posts/{id}/claims/`, `/api/claims/{id}/decide/` |
| My activity: my posts (with pending claims) and my claims | `activity_screen.dart` |
| Report posts; 3 reports hide a post for review; Django admin for moderators | `/api/posts/{id}/report/`, `/admin/` |
| Posts leave the feed after 30 days unless renewed; "mark returned" | `/renew/`, `/resolve/` |

### Privacy and safety built in

- **No background location.** Location is read only when a photo is taken or the feed/map opens. The app never tracks you.
- **EXIF stripped.** Every photo is re-encoded on the server, removing the hidden GPS coordinates and phone details.
- **Blur tool.** Draw boxes over ID numbers, card numbers or faces; the server blurs them before storing. Posts in the "ID / documents" category are refused until something is blurred.
- **Approximate location for kept items.** If the finder took the item home, the public sees only a ~250 m area. The point is offset once and stored, and all searching uses that offset point, so distance queries can't be used to find the finder's home. The exact spot is shown only to the finder and to an approved claimant.
- **No public phone numbers.** The finder sends meetup details only to the approved claimant.
- **Rate limits** on login, sign-up, posting and claiming.

## 1. Run the backend

### Option A: Docker (easiest, any OS)

```bash
cd backend
cp .env.example .env
docker compose up --build
```

In a second terminal:

```bash
docker compose exec api python manage.py createsuperuser
docker compose exec api python manage.py seed_demo --lat 12.9716 --lng 77.5946
```

The API is at http://localhost:8000/api/ and the moderation admin at http://localhost:8000/admin/.

### Option B: Without Docker

You need Python 3.12+, PostgreSQL with PostGIS, and GDAL.

- **Ubuntu/Debian:** `sudo apt install postgresql postgis gdal-bin`
- **macOS:** `brew install postgresql postgis gdal`
- **Windows:** install PostgreSQL with the PostGIS add-on (Stack Builder), and GDAL via OSGeo4W. Then set `GDAL_LIBRARY_PATH` and `GEOS_LIBRARY_PATH` in `.env` (see `.env.example`). Docker is much easier on Windows.

```bash
# create the database once
psql -U postgres -c "CREATE USER ftl WITH PASSWORD 'ftl' SUPERUSER;"
psql -U postgres -c "CREATE DATABASE ftl OWNER ftl;"
psql -U postgres -d ftl -c "CREATE EXTENSION postgis;"

cd backend
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
export POSTGRES_HOST=localhost                        # Windows: set POSTGRES_HOST=localhost
python manage.py migrate
python manage.py createsuperuser
python manage.py seed_demo --lat 12.9716 --lng 77.5946
python manage.py runserver 0.0.0.0:8000
```

`seed_demo` creates 5 demo users (`asha`, `rahul`, `meera`, `karthik`, `sana`, password `demo-pass-123`) and 9 posts around the point you give, including a kept phone with a pending claim. Pass your campus coordinates for the demo.

### Tests

```bash
python manage.py test lostfound
```

36 tests cover auth, photo cleaning, blur enforcement, location privacy, the feed and map queries, the whole claim flow, votes, comments, reports, permissions, and a set of hardening checks (bad input, stale logins, zoomed-out maps).

## 2. Run the Android app

You need Flutter 3.35 or newer and Android Studio (for the Android SDK and an emulator).

```bash
cd app
flutter create --platforms=android --org com.findingthelost --project-name finding_the_lost .
flutter pub get
flutter run
```

`flutter create .` adds the standard Android project files around the code here. It does not overwrite files that already exist, so the `AndroidManifest.xml` with the location and internet permissions is kept.

**Pointing the app at your server**

- **Emulator:** works as-is; `10.0.2.2` is the emulator's name for your computer.
- **Real phone on the same Wi-Fi:** find your computer's IP (`ipconfig` on Windows, `ip addr` on Linux, System Settings on macOS), then either run `flutter run --dart-define=API_BASE=http://192.168.1.20:8000` or tap the server icon on the login screen and enter it there.

**Build an APK to install on any phone**

```bash
flutter build apk --release --dart-define=API_BASE=http://<your-server>:8000
# output: build/app/outputs/flutter-apk/app-release.apk
```

## 3. Demo script (5 minutes)

1. Log in as `sana`. Open the Feed: posts are sorted by distance; switch to the Map.
2. Open "Black wallet near bus stop": the guidance card says it's at Rajajinagar Police Station and what to carry.
3. Open "Samsung phone, cracked screen": the map shows only an approximate circle. Sana's claim is waiting.
4. Log out, log in as `karthik` (the finder). My activity shows "1 claim". Review it, approve with a meetup message.
5. Log back in as `sana`: the claim shows the finder's message and the exact location.
6. Post a new found item with the camera; show the GPS tag, drag the pin, pick "Handed it to the police".
7. Pick the "ID / documents" category and show that posting is blocked until you blur the card number.

## API summary

| Method | Path | Notes |
|---|---|---|
| POST | `/api/auth/register/`, `/api/auth/login/` | returns `{token, user}` |
| GET | `/api/meta/` | categories, handover options + guidance, report reasons |
| GET | `/api/posts/?lat&lng&radius_km&type&category&q&sort` | paged feed |
| GET | `/api/posts/map/?bbox=minLng,minLat,maxLng,maxLat` | up to 300 posts |
| POST | `/api/posts/` | multipart: fields, `images` (repeat), `blur_regions` JSON |
| GET/PATCH/DELETE | `/api/posts/{id}/` | edit/delete by author only |
| POST | `/api/posts/{id}/vote/`, `/resolve/`, `/renew/`, `/report/` | |
| GET/POST | `/api/posts/{id}/comments/` | `parent` for replies |
| GET/POST | `/api/posts/{id}/claims/` | finder sees all, others see their own |
| POST | `/api/claims/{id}/decide/`, `/api/claims/{id}/withdraw/` | |
| GET | `/api/me/posts/`, `/api/me/claims/` | |

Send `Authorization: Token <token>` on authenticated calls.

## Before putting this on the public internet

The project is set up for a class demo on a laptop and phones on the same Wi-Fi. For a public server, do these first:

- **HTTPS.** The app talks plain `http://` on the local network, so passwords are not encrypted in transit. Put the API behind HTTPS (for example Caddy or Nginx with a free certificate) and use an `https://` server address.
- **Secrets.** Set `DJANGO_DEBUG=false`, a long random `DJANGO_SECRET_KEY` (the server refuses to start without one when debug is off), a real `POSTGRES_PASSWORD`, and `DJANGO_ALLOWED_HOSTS` to your domain.
- **Demo accounts.** Don't run `seed_demo` on a public server: its accounts share a known password.
- **Sign-up checks.** Accounts are not verified by email or phone yet, so one person can make several. That matters for claims and for the "3 reports hide a post" rule. Add OTP verification (see v2 ideas).
- **Signing key.** `app/ci/debug.keystore` is a public test key. Create a private key for a Play Store release.

## Next steps (v2 ideas)

- Push notifications when something in your category is found nearby (Firebase Cloud Messaging).
- In-app chat between finder and approved claimant (Django Channels).
- Phone/email OTP verification at sign-up to cut fake accounts.
- AI matching: CLIP image embeddings to suggest "this found item looks like your lost post".
- Your own map tile server or a tile provider for heavy use; the OpenStreetMap public tiles are fine for a class demo but have a fair-use policy.
