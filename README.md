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
| Sign up with a 6-digit email code; log in with username or email (token auth) | `backend/accounts`, `app/lib/screens/login_screen.dart` |
| Found posts: camera photo, GPS captured when the photo is taken, draggable pin, required landmark | `create_post_screen.dart` |
| Handover options with owner guidance (left there / police / desk / kept) | `lostfound/models.py` `HANDOVER_GUIDANCE` |
| Lost posts, so owners can post too | same screen, `postType: lost` |
| Feed: near me, newest, top; filters by type, category, distance; search | `feed_screen.dart`, `GET /api/posts/` |
| Map of posts in view, green = found, orange = lost | `map_screen.dart`, `GET /api/posts/map/` |
| Upvotes and threaded comments | `post_detail_screen.dart` |
| Claims with a verification question; finder approves with a private meetup message, and can cancel an approval | `claims_review_screen.dart`, `/api/posts/{id}/claims/`, `/api/claims/{id}/decide/`, `/revoke/` |
| My activity: my posts (with pending claims) and my claims | `activity_screen.dart` |
| Report posts; 3 reports hide a post for review; Django admin for moderators | `/api/posts/{id}/report/`, `/admin/` |
| Posts leave the feed after 30 days unless renewed; "mark returned" | `/renew/`, `/resolve/` |

### Privacy and safety built in

- **No background location.** Location is read only when a photo is taken or the feed/map opens. The app never tracks you.
- **EXIF stripped.** Every photo is re-encoded on the server, removing the hidden GPS coordinates and phone details.
- **Blur tool.** Draw boxes over ID numbers, card numbers or faces; the server blurs them before storing. Posts in the "ID / documents" category are refused until something is blurred.
- **Approximate location for kept items.** If the finder took the item home, the public sees only a ~250 m area. The point is offset once and stored, and all searching uses that offset point, so distance queries can't be used to find the finder's home. The exact spot is shown only to the finder and to an approved claimant.
- **No public phone numbers.** The finder sends meetup details only to the approved claimant.
- **Verified sign-ups.** New accounts confirm their email with a 6-digit code before they can log in (10-minute codes, 5 tries, one resend a minute).
- **HTTPS option.** One command gives the server a free `https://` address (see *Use HTTPS*).
- **Rate limits** on login, sign-up, posting, claiming and comments.

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

`seed_demo` creates 5 demo users (`asha`, `rahul`, `meera`, `karthik`, `sana`, password `demo-pass-123`) and 9 posts around the point you give, including a kept phone with a pending claim. Pass your campus coordinates for the demo. Demo accounts don't need an email code.

### Sign-up email codes

New accounts get a 6-digit code by email. Until you set up email, the codes are printed in the server log instead:

```bash
docker compose logs api | findstr code      # Windows
docker compose logs api | grep code         # macOS / Linux
```

To send real emails from Gmail:

1. Turn on 2-Step Verification for the Google account.
2. Create an app password at https://myaccount.google.com/apppasswords.
3. In `backend/.env`, set `EMAIL_HOST_USER=you@gmail.com` and `EMAIL_HOST_PASSWORD=` the 16-letter app password.
4. Restart: `docker compose up -d --build`.

### Use HTTPS (and reach the server from anywhere)

This starts a free Cloudflare tunnel next to the API, with no account or install needed:

```bash
docker compose --profile tunnel up -d --build
docker compose logs tunnel | findstr trycloudflare     # Windows
```

Copy the `https://something.trycloudflare.com` address into the app's server setting (the icon on the login screen). Traffic is encrypted, and phones work on any network, so you don't need the same Wi-Fi or a firewall rule. The address changes each time the tunnel restarts.

The tunnel makes your server reachable from the internet, so in `backend/.env` set `DJANGO_DEBUG=false` and a real `DJANGO_SECRET_KEY`:

```bash
docker compose run --rm api python -c "import secrets; print(secrets.token_urlsafe(50))"
```


### Host it online (Render + Supabase, free)

For a fixed `https://` address that works 24/7 without your laptop:

| Service | Does | Free limits that matter |
|---|---|---|
| Render | runs the API from `backend/Dockerfile` (set up by `render.yaml`) | sleeps after 15 min without traffic; disk wiped on restart; email ports blocked |
| Supabase | database (PostGIS) and photo storage | 500 MB database, 1 GB photos; pauses after a week with no database activity |
| UptimeRobot | calls `/api/health/` every 5 min | keeps Render awake, and the health check touches the database, so Supabase stays awake too |
| Brevo (optional) | sends sign-up codes over HTTPS | 300 emails a day |

The server reads its settings from Render's **Environment** tab (see the hosted block in `.env.example`). On every start it runs migrations, creates the admin account from `DJANGO_SUPERUSER_*`, and adds demo data once if `SEED_DEMO=true`. Without `BREVO_API_KEY`, sign-up codes appear in Render's **Logs** tab.

Notes:
- Use Supabase's **Session pooler** connection string. Render can't reach Supabase's direct connection (IPv6 only).
- Enable the `postgis` extension in Supabase (**Database > Extensions**) before the first deploy.
- The `photos` bucket must be **public**, so photo links work in the app.
- Point the app at the Render address with the `API_BASE` repository variable, then rebuild.

### Tests

```bash
python manage.py test lostfound
```

56 tests cover sign-up email codes, auth, photo cleaning, blur enforcement, location privacy, the feed and map queries, the whole claim flow, votes, comments, reports, permissions, hardening checks (bad input, stale logins, zoomed-out maps) and the hosting pieces (health check, startup admin, Brevo email).

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

The server address is built into the app, so users never set it. GitHub builds use the repository variable `API_BASE` (repo **Settings > Secrets and variables > Actions > Variables**); without it, the address in `app/lib/session.dart` is used. When your tunnel address changes, update that variable and re-run the build. Phones pick up the new address when they install the update.

For testing, there's a hidden server setting: tap the logo on the login screen 7 times quickly.

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
| POST | `/api/auth/register/` | creates the account and emails a code (no token yet) |
| POST | `/api/auth/verify-email/` | `{username, code}`, returns `{token, user}` |
| POST | `/api/auth/resend-code/` | `{username}`, one per minute |
| POST | `/api/auth/login/` | returns `{token, user}`; 403 `email_unverified` if the code step is pending |
| GET | `/api/meta/` | categories, handover options + guidance, report reasons |
| GET | `/api/posts/?lat&lng&radius_km&type&category&q&sort` | paged feed |
| GET | `/api/posts/map/?bbox=minLng,minLat,maxLng,maxLat` | up to 300 posts |
| POST | `/api/posts/` | multipart: fields, `images` (repeat), `blur_regions` JSON |
| GET/PATCH/DELETE | `/api/posts/{id}/` | edit/delete by author only |
| POST | `/api/posts/{id}/vote/`, `/resolve/`, `/renew/`, `/report/` | |
| GET/POST | `/api/posts/{id}/comments/` | `parent` for replies |
| GET/POST | `/api/posts/{id}/claims/` | finder sees all, others see their own |
| POST | `/api/claims/{id}/decide/`, `/withdraw/`, `/revoke/` | revoke = finder cancels an approval |
| GET | `/api/me/posts/`, `/api/me/claims/` | |

Send `Authorization: Token <token>` on authenticated calls.

## Before putting this on the public internet

The project is set up for a class demo on a laptop and phones on the same Wi-Fi. For a public server, do these first:

- **HTTPS.** Use the tunnel above, or put the API behind Caddy or Nginx with a free certificate, and use the `https://` address in the app. The app warns if you enter an unencrypted public address.
- **Secrets.** Set `DJANGO_DEBUG=false`, a long random `DJANGO_SECRET_KEY` (the server refuses to start without one when debug is off), a real `POSTGRES_PASSWORD`, and `DJANGO_ALLOWED_HOSTS` to your domain.
- **Demo accounts.** Don't run `seed_demo` on a public server: its accounts share a known password.
- **Email.** Set up real email (above) so sign-up codes reach people.

## Private signing key (for releases)

Test builds are signed with the public key in `app/ci`, which is fine for testing. For a release, sign with your own private key, stored as GitHub secrets so it never sits in the repository. Docker can generate it, so you don't need to install Java.

1. In PowerShell, in a folder **outside** the project (for example `C:\keys`), run this. Replace `YOUR-PASSWORD` with a strong password you'll keep somewhere safe:
   ```powershell
   docker run --rm -v ${PWD}:/keys -w /keys eclipse-temurin:21-jdk keytool -genkeypair -keystore release.keystore -storetype PKCS12 -alias release -keyalg RSA -keysize 2048 -validity 10000 -storepass YOUR-PASSWORD -dname "CN=Finding the Lost"
   ```
2. Copy it as text:
   ```powershell
   [Convert]::ToBase64String([IO.File]::ReadAllBytes("$PWD\release.keystore")) | Set-Clipboard
   ```
3. On GitHub, open the repo's **Settings > Secrets and variables > Actions > New repository secret** and add:

   | Name | Value |
   |---|---|
   | `RELEASE_KEYSTORE_BASE64` | paste from step 2 |
   | `RELEASE_KEYSTORE_PASSWORD` | your password |
   | `RELEASE_KEY_ALIAS` | `release` |

4. Back up `release.keystore` and the password (for example in a password manager). **If you lose them, you can never publish an update to the same app.** Never commit the file; `.gitignore` blocks it.

The next build is signed with your key, and its summary page shows the key's fingerprint. Uninstall the test-key version from your phone once, then updates install normally.

## Next steps (v2 ideas)

- Push notifications when something in your category is found nearby (Firebase Cloud Messaging).
- In-app chat between finder and approved claimant (Django Channels).
- Phone (SMS) verification as well as email, for stronger one-person-one-account.
- AI matching: CLIP image embeddings to suggest "this found item looks like your lost post".
- Your own map tile server or a tile provider for heavy use; the OpenStreetMap public tiles are fine for a class demo but have a fair-use policy.
