# LearnDesk

Pin ideas to create or research, keep a learning journal, get quizzed on what
you logged, and keep a to-do list. A Mac desktop widget plus a phone web app,
synced through your own Supabase project.

- `Sources/` and `build-app.sh`: the Mac app.
- `docs/`: the phone web app (served by GitHub Pages).
- `supabase.sql`: the one table sync needs.

## Mac app

Needs macOS 13 or later and the Swift toolchain (Xcode, or `xcode-select --install`).

```bash
./build-app.sh
```

Move `LearnDesk.app` to `/Applications` and open it. It lives under the
graduation cap in the menu bar; Settings are in that menu. Quizzes need
Claude Code installed and signed in (see below).

## Sync and the phone app

### 1. Supabase

1. Create a free project at supabase.com.
2. SQL Editor: paste the contents of `supabase.sql` and run it.
3. Authentication > Users > Add user > Create new user. Enter an email and a
   strong password and tick "Auto Confirm User". This is the login both
   devices use.
4. Authentication > Sign In / Providers: turn off "Allow new users to sign up",
   so nobody else can make an account in your project.
5. Note the Project URL (`https://xxxx.supabase.co`) and the publishable
   (anon) key from the project's API settings. The publishable key is designed
   to be public; the row-level security in `supabase.sql` is what protects
   the data. Never use the secret / service-role key in either app.

### 2. Host the phone app

Push this folder to a GitHub repository, then in the repository:
Settings > Pages > Deploy from a branch > `main`, folder `/docs`.
The app appears at `https://<username>.github.io/<repository>/`.

The page contains no data and no keys; it is only the app's code.

### 3. Connect both devices

- Mac: menu bar icon > Settings > Sync with phone. Enter the Project URL,
  publishable key, email and password.
- Phone: open the Pages address in Chrome, then menu > Add to Home screen.
  In the app's Settings tab enter the same four things.

Changes sync a couple of seconds after you make them and at least once a
minute. The phone app works offline and catches up when it reconnects. If the
same item is edited on both devices before they sync, the later edit wins.

## Quizzes and your Claude subscription

There is no API key and no separate bill. The Mac app writes questions and
checks answers by running Claude Code (`claude -p`), which uses the Claude
subscription Claude Code is signed in with.

Set up once on the Mac:

1. Install Claude Code.
2. Open Terminal, run `claude`, and sign in with your Claude account.
3. In LearnDesk: menu bar icon > Settings > Claude should show where it found
   Claude Code. If not, paste the output of `which claude` into the location
   field.

How it behaves:

- Quiz usage counts against the same subscription allowance as the rest of
  your Claude use. When you reach the limit, LearnDesk says so and pauses
  question-writing and answer-checking until it resets. You can still reveal
  answers and rate yourself.
- The phone has no access to Claude. Entries logged on the phone are marked
  "Waiting for your Mac"; the Mac writes their questions the next time it is
  running and syncs, and they then appear on the phone. Quizzes on the phone
  are self-graded.
- Set the model to `sonnet` or `haiku` in Settings to use less of your allowance.

## Data

- Mac: `~/Library/Application Support/LearnDesk/data.json`.
- Phone: the browser's storage for the app. Clearing site data removes the
  local copy; synced data comes back after signing in.
- Supabase: one row per item in the `items` table.
