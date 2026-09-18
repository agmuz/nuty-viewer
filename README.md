# Nuty — Sheet Music Viewer for Trumpet Players

Android app for displaying sheet music from MusicXML/MXL files with **transposition** — designed for trumpet, saxophone, clarinet and other transposing instrument players.

## Features

- Opens `.xml`, `.mxl`, `.musicxml`, `.mei` files from local storage
- Renders sheet music with Verovio (offline, no internet required)
- **Transposition** of the entire score (for Bb trumpet, saxophone, etc.)
- **Zoom** and **row compression/expansion**
- **Playlists** — build setlists for concerts
- **Swipe navigation** between pieces in a playlist
- **Mark as played** (beige tile) — track which pieces you've already performed
- Auto-hide toolbar — sheet music fills the entire screen
- Per-file settings (key, zoom, spacing) — automatically saved

## Installation

1. Download the latest APK from [Releases](https://github.com/agmuz/nuty-viewer/releases)
2. Copy it to your phone (USB cable, Google Drive, email)
3. Open the APK in your phone's file manager
4. Allow installation from unknown sources
5. Install and launch the app

## First Launch

1. The app will ask for a folder with sheet music — tap **Select folder**
2. Choose the folder containing your `.mxl` / `.xml` files (e.g. `Download/Nuty/`)
3. Grant access — Android will ask for permission
4. The app remembers the folder

## Transposition — The Most Important Feature

**For Bb trumpet:** if the sheet music is in C and you play a Bb trumpet, select the key **D** — the notes will be transposed up a whole tone.

### How to transpose

1. Open a piece
2. Tap the screen to show the toolbar
3. Click the key dropdown
4. Select the desired key
5. The notes **transpose automatically**
6. The setting is **saved per file**

### Keys

| Label | Key |
|---|---|
| **ORG** | original (no transposition) |
| **C** | C major |
| **D** | D major |
| **Es** | E-flat major |
| **F** | F major |
| **G** | G major |
| **A** | A major |
| **B** | B major |
| **H** | B natural major |

## Playlists

- Tap **+** in the top bar → build mode
- Tap tiles to add pieces → they turn gold with order numbers
- Enter a name → tap **💾**
- Open a playlist → **swipe left/right** between pieces

## Per-File Settings

Each file has its own:
- **Key** (transposition)
- **Zoom**
- **Row spacing**

Settings are saved automatically and restored when you reopen the piece.

## Requirements

- **Android 7.0+** (API 24+)
- **A folder with files** `.xml`, `.mxl`, `.musicxml`, `.mei`

## Supported Formats

- **MusicXML** (`.xml`, `.musicxml`) — standard music notation interchange format
- **MXL** (`.mxl`) — compressed MusicXML (ZIP)
- **MEI** (`.mei`) — format used by Verovio
- **ABC**, **Humdrum**, **PAE** — other formats supported by Verovio

## Where to Get MXL Files

- **MuseScore** — free notation editor, exports to MusicXML and MXL
- **Finale**, **Sibelius**, **Dorico** — commercial editors, export to MusicXML
- **IMSLP** — public domain sheet music library
- **MuseScore.com** — sheet music catalog, downloadable in MusicXML

## Building from Source

```bash
flutter pub get
flutter build apk --release
