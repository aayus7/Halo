# Animated covers (Apple Music motion artwork)

Halo plays an album's animated cover behind the player when Apple Music has one.
It uses the **official Apple Music API**, which needs a *developer token* signed with a
MusicKit key from **your own** Apple developer account. Halo never scrapes Apple's web player.

Hi-res static covers don't need any of this (they come from the public iTunes Search API).

## 1. Make a MusicKit key (once)

1. Go to <https://developer.apple.com/account/resources/authkeys/list> → **+**.
2. Name it "Halo", tick **Media Services (MusicKit, ShazamKit, Apple Music Feed)**, configure it
   with a Media ID if asked, and **Download** the `AuthKey_XXXXXXXXXX.p8` file. Keep it private.
3. Note the **Key ID** (10 characters) and your **Team ID** (top right of the developer site).

## 2. Sign a token (Windows is fine)

Install Node.js, then from this repo:

```
node tools/musickit-token.mjs path\to\AuthKey_XXXXXXXXXX.p8 KEY_ID TEAM_ID
```

It prints a token valid for 180 days (Apple's maximum).

## 3. Paste it into Halo

Settings → Artwork → *MusicKit developer token*. Set your storefront (`us`, `in`, `gb`, …).
Play something with an animated cover (most new major-label albums have one).

When the token expires, run the script again and paste the new one.
