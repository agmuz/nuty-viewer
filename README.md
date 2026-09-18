# Nuty — przeglądarka nut dla trębaczy

Aplikacja Android do wyświetlania nut z plików MusicXML/MXL z **transpozycją** — dla trębaczy, saksofonistów, klarnecistów i innych instrumentalistów transponujących.

## Funkcje

- Otwieranie plików `.xml`, `.mxl`, `.musicxml`, `.mei` z lokalnego dysku
- Renderowanie nut przez Verovio (offline, bez internetu)
- **Transpozycja** całego zapisu (dla trąbki B, saksofonu itp.)
- **Zoom** i **ściskanie/rozsuwanie wierszy**
- **Playlisty** — tworzenie setlist na koncert
- **Nawigacja swipe** między utworami w playliście
- **Oznaczanie zagranych** utworów (beżowy kafelek)
- Auto-hide pasek — nuty na całym ekranie
- Ustawienia per plik (tonacja, zoom, wiersze) — zapamiętywane

## Instalacja

1. Pobierz najnowszy APK z [Releases](https://github.com/agmuz/nuty-viewer/releases)
2. Skopiuj na telefon (kabel USB, Google Drive, e-mail)
3. Otwórz APK w menedżerze plików telefonu
4. Zezwól na instalację z nieznanych źródeł
5. Zainstaluj i otwórz aplikację

## Pierwsze uruchomienie

1. Apka zapyta o folder z nutami — kliknij **Wybierz folder**
2. Wskaż folder z plikami `.mxl` / `.xml` (np. `Download/Nuty/`)
3. Zezwól na dostęp — Android zapyta o uprawnienia
4. Apka zapamięta folder

## Transpozycja — najważniejsza funkcja

**Dla trąbki B:** jeśli nuty są w C, a Ty grasz na trąbce B, wybierz tonację **D** — nuty zostaną transponowane o cały ton w górę.

### Jak transponować

1. Otwórz utwór
2. Dotknij ekran, żeby pokazać pasek
3. Kliknij dropdown tonacji
4. Wybierz żądaną tonację
5. Nuty **automatycznie się transponują**
6. Ustawienie **zapamiętuje się per plik**

### Tonacje

| Oznaczenie | Tonacja |
|---|---|
| **ORG** | oryginalna (bez transpozycji) |
| **C** | C-dur |
| **D** | D-dur |
| **Es** | Es-dur |
| **F** | F-dur |
| **G** | G-dur |
| **A** | A-dur |
| **B** | B-dur |
| **H** | H-dur |

## Playlisty

- **+** w pasku górnym → tryb budowania
- Klikaj kafelki → złote z numerami
- Wpisz nazwę → **💾**
- Otwórz playlistę → **swipe w lewo/prawo** między utworami

## Ustawienia per plik

Każdy plik ma własne:
- **Tonacja**
- **Zoom**
- **Wiersze**

Zapisują się automatycznie i wracają przy kolejnym otwarciu.

## Wymagania

- **Android 7.0+** (API 24+)
- **Folder z plikami** `.xml`, `.mxl`, `.musicxml`, `.mei`

## Budowanie ze źródeł

```bash
flutter pub get
flutter build apk --release
