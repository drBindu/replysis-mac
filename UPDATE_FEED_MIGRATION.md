# Sparkle update feed: migrating off the moto123a account

## What changed in 1.0.245

`SUFeedURL` now points at the new account:

    old  https://raw.githubusercontent.com/moto123a/interview-copilot-mac/main/appcast.xml
    new  https://raw.githubusercontent.com/drBindu/replysis-mac/main/appcast.xml

The signing key is unchanged — `SUPublicEDKey` is still
`Z/GmlGrdWA8lVxVMbukzNBwqDBRLZi9YbOqSH4hClsI=`, so every already-installed copy
will accept an update signed with the same EdDSA private key. Do not regenerate
that key. Replacing it strands every existing user permanently: their installed
copy verifies against the old public key and will refuse anything signed with a
new one, and there is no in-app path to recover.

## Why this is a bridge and not a switch

An installed 1.0.244 does not know the new URL. It polls the OLD feed, and it
will keep polling the old feed until it installs a build that carries the new
one. So the migration is:

1. Publish 1.0.245 to the **old** appcast. Existing users are offered it there.
2. They install it. That build carries the new `SUFeedURL`.
3. From then on they poll the new feed.

Publishing 1.0.245 only to the new feed updates nobody, because nobody is
looking at it yet.

## A second problem this has to fix

The old appcast is stale. It tops out at **1.0.237** while releases run to
**1.0.244** — builds 238 through 244 were published to GitHub Releases but never
added to the appcast. Auto-update has therefore been dead since 17 July 2026 for
anyone on 238+, and anyone on an older build is being offered 237 rather than
the newest.

That means 1.0.245 must be added to the old appcast with a `sparkle:version` of
245, which is above every version any user can be running.

## What must stay available after release

Until telemetry shows the population has moved to 1.0.245 or later:

- `moto123a/interview-copilot-mac` must remain **readable**, with
  `appcast.xml` on `main` and its release assets downloadable.
- **Archiving is safe.** An archived GitHub repository stays public and
  readable; raw.githubusercontent and release downloads continue to work.
- **Deleting or renaming it is not.** Both break the feed for every user still
  on 1.0.244 or earlier, with no in-app recovery — they would have to download
  the app again by hand. GitHub also allows a freed name to be re-registered by
  somebody else, so the namespace should not simply be released.

Keep it for at least one full update cycle. There is no cost to keeping it.

## Publishing 1.0.245 (not done here)

This needs a signed, notarized Release build and the Sparkle EdDSA private key,
so it is a release-engineering step rather than a code change:

1. Archive a Release build (hardened runtime is already YES for Release).
2. Sign with Developer ID, notarize, staple.
3. Zip as `InterviewCopilot-update.zip`.
4. Sign it: `sign_update InterviewCopilot-update.zip` — the private key lives in
   this machine's login keychain under service `https://sparkle-project.org`,
   account `ed25519`.
5. Attach the zip to a `v1.0.245` release on `drBindu/replysis-mac`.
6. Add an identical `<item>` to BOTH appcasts, with the enclosure URL pointing
   at the drBindu release asset:
   - `moto123a/interview-copilot-mac/appcast.xml`  (reaches existing users)
   - `drBindu/replysis-mac/appcast.xml`            (reaches them afterwards)

## Verify before announcing

    curl -sI <enclosure url>                     # 200, correct byte length
    curl -s <new feed> | grep sparkle:version    # 245 present
    curl -s <old feed> | grep sparkle:version    # 245 present

Then install 1.0.244 from the old release, let it check for updates, and confirm
it offers and installs 245. That is the only test that proves the bridge works.
