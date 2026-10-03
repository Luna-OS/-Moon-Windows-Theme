"""Erzeugt das Moon-Soundschema (theme/Sounds/*.wav).

Sanfte, glockige "Mondklaenge": Sinus-Glocken mit leisen Obertoenen,
weichem Anschlag, langem Ausklang und etwas Hall. Alles wird hier
synthetisiert, es werden keine fremden Aufnahmen verwendet.

Aufruf:  python tools/generate_sounds.py
Benoetigt: pip install numpy
"""
import wave
from pathlib import Path

import numpy as np

OUT = Path(__file__).resolve().parent.parent / "theme" / "Sounds"
RATE = 44100


def note(name):
    """Notenname wie 'A5' oder 'C#6' -> Frequenz in Hz."""
    names = {"C": -9, "C#": -8, "D": -7, "D#": -6, "E": -5, "F": -4, "F#": -3,
             "G": -2, "G#": -1, "A": 0, "A#": 1, "B": 2}
    pitch, octave = name[:-1], int(name[-1])
    return 440.0 * 2 ** ((names[pitch] + 12 * (octave - 4)) / 12)


def bell(freq, dur, decay=3.0, bright=0.35, attack=0.004):
    """Weiche Glocke: Grundton + leicht verstimmte Obertoene, exponentieller Ausklang."""
    t = np.arange(int(dur * RATE)) / RATE
    partials = [(1.0, 1.0), (2.0, 0.45 * bright), (3.01, 0.22 * bright), (4.2, 0.12 * bright), (0.5, 0.18)]
    sig = np.zeros_like(t)
    for ratio, amp in partials:
        # hoehere Obertoene klingen schneller ab
        sig += amp * np.sin(2 * np.pi * freq * ratio * t) * np.exp(-t * decay * (1 + 0.6 * (ratio - 1)))
    # leichtes Schweben (Chorus) fuer den "mondigen" Klang
    sig += 0.25 * np.sin(2 * np.pi * freq * 1.003 * t) * np.exp(-t * decay)
    env = np.minimum(1.0, t / attack)
    # weich ausblenden statt hart abschneiden (sonst knackt es am Ende jeder Glocke)
    tail = min(len(t), int(0.35 * dur * RATE))
    env[-tail:] *= 0.5 * (1 + np.cos(np.linspace(0, np.pi, tail)))
    return sig * env


def pad(freqs, dur, swell=0.6, release=1.2):
    """Weicher Flaechenklang (fuer An-/Abmelden)."""
    t = np.arange(int(dur * RATE)) / RATE
    sig = np.zeros_like(t)
    for i, f in enumerate(freqs):
        for detune in (0.997, 1.0, 1.003):
            sig += np.sin(2 * np.pi * f * detune * t + i) / (1 + i * 0.4)
    env = np.minimum(1.0, t / swell) * np.clip((dur - t) / release, 0, 1)
    return sig * env


def whoosh(dur, start_hz, end_hz, rng):
    """Gefiltertes Rauschen mit wanderndem Filter (fuer Papierkorb leeren)."""
    n = int(dur * RATE)
    noise = rng.normal(0, 1, n)
    out = np.zeros(n)
    y = 0.0
    freqs = np.geomspace(start_hz, end_hz, n)
    for i in range(n):
        a = np.exp(-2 * np.pi * freqs[i] / RATE)
        y = (1 - a) * noise[i] + a * y
        out[i] = y
    t = np.arange(n) / RATE
    env = np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 1.5
    return out * env * 3


def mix(parts, total):
    """parts: Liste (Startzeit in s, Signal, Lautstaerke)."""
    out = np.zeros(int(total * RATE))
    for start, sig, gain in parts:
        i = int(start * RATE)
        seg = sig[: max(0, len(out) - i)]
        out[i:i + len(seg)] += gain * seg
    return out


def reverb(sig, amount=0.28):
    """Einfacher Hall aus ein paar verzoegerten, gedaempften Kopien (Stereo)."""
    left, right = sig.copy(), sig.copy()
    for delay, gain, side in [(0.031, 0.5, 0), (0.047, 0.45, 1), (0.071, 0.35, 0),
                              (0.097, 0.3, 1), (0.131, 0.22, 0), (0.173, 0.16, 1)]:
        d = int(delay * RATE)
        target = left if side == 0 else right
        target[d:] += amount * gain * sig[:-d]
    return np.stack([left, right], axis=1)


def save(name, stereo, peak=0.55):
    OUT.mkdir(parents=True, exist_ok=True)
    stereo = stereo / (np.max(np.abs(stereo)) + 1e-9) * peak
    # sanftes Ausblenden am Ende, damit nichts knackt
    fade = min(len(stereo), int(0.05 * RATE))
    stereo[-fade:] *= np.linspace(1, 0, fade)[:, None]
    data = (stereo * 32767).astype("<i2")
    with wave.open(str(OUT / name), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(data.tobytes())
    print(f"geschrieben: {name} ({len(stereo) / RATE:.1f} s)")


def main():
    rng = np.random.default_rng(1969)
    B = bell
    N = note

    sounds = {
        # Standard-Signalton / Hinweis
        "moon-default.wav": mix([(0, B(N("E6"), 1.2), 1), (0.09, B(N("B5"), 1.2), 0.8)], 1.4),
        # Benachrichtigung: aufsteigendes Arpeggio
        "moon-notification.wav": mix([(0, B(N("C6"), 1.4), 0.8), (0.11, B(N("E6"), 1.4), 0.8),
                                      (0.22, B(N("G6"), 1.6), 0.9)], 1.9),
        # Information
        "moon-info.wav": mix([(0, B(N("A5"), 1.6, decay=2.5), 1)], 1.7),
        # Warnung: zwei absteigende Toene
        "moon-warning.wav": mix([(0, B(N("D6"), 1.0), 1), (0.16, B(N("A5"), 1.3), 1)], 1.6),
        # Fehler: tiefer Doppelton
        "moon-error.wav": mix([(0, B(N("E5"), 1.0, bright=0.6), 1), (0.14, B(N("C5"), 1.4, bright=0.6), 1)], 1.7),
        # Frage
        "moon-question.wav": mix([(0, B(N("G5"), 1.0), 1), (0.14, B(N("D6"), 1.3), 0.9)], 1.6),
        # Geraet angeschlossen / getrennt / Fehler
        "moon-device-connect.wav": mix([(0, B(N("G5"), 0.9), 0.8), (0.08, B(N("C6"), 0.9), 0.8),
                                        (0.16, B(N("G6"), 1.2), 0.9)], 1.5),
        "moon-device-disconnect.wav": mix([(0, B(N("G6"), 0.9), 0.8), (0.08, B(N("C6"), 0.9), 0.8),
                                           (0.16, B(N("G5"), 1.2), 0.9)], 1.5),
        "moon-device-fail.wav": mix([(0, B(N("C5"), 0.8, bright=0.7), 1), (0.12, B(N("C5"), 1.2, bright=0.7), 1)], 1.4),
        # Benutzerkontensteuerung (UAC): schimmernder Akkord
        "moon-uac.wav": mix([(0, B(N("A5"), 1.6), 0.7), (0.03, B(N("C#6"), 1.6), 0.6),
                             (0.06, B(N("E6"), 1.8), 0.6)], 2.0),
        # Erinnerung (Kalender, Wecker): drei Glocken
        "moon-reminder.wav": mix([(0, B(N("E6"), 0.9), 0.9), (0.28, B(N("E6"), 0.9), 0.9),
                                  (0.56, B(N("A6"), 1.4), 0.9)], 2.1),
        # Neue Nachricht / Mail: kurze Doppelglocke
        "moon-message.wav": mix([(0, B(N("B5"), 0.8), 0.9), (0.08, B(N("E6"), 1.1), 0.9)], 1.3),
        # Akku schwach / kritisch
        "moon-battery-low.wav": mix([(0, B(N("C6"), 1.0), 0.9), (0.2, B(N("A5"), 1.0), 0.9),
                                     (0.4, B(N("F5"), 1.4), 0.9)], 2.0),
        "moon-battery-critical.wav": mix([(0, B(N("A5"), 0.6, bright=0.6), 1), (0.18, B(N("A5"), 0.6, bright=0.6), 1),
                                          (0.36, B(N("F5"), 1.2, bright=0.6), 1)], 1.8),
        # Anmelden / Abmelden: weiche Flaeche + Glocke
        "moon-logon.wav": mix([(0, pad([N("C4"), N("G4"), N("E5")], 3.2), 0.35),
                               (0.5, B(N("G5"), 1.6), 0.5), (0.8, B(N("C6"), 1.8), 0.5), (1.1, B(N("E6"), 2.0), 0.55)], 3.4),
        "moon-logoff.wav": mix([(0, pad([N("C4"), N("G4"), N("D5")], 2.6), 0.35),
                                (0.3, B(N("E6"), 1.5), 0.5), (0.6, B(N("C6"), 1.6), 0.5), (0.9, B(N("G5"), 1.8), 0.5)], 2.8),
        # Papierkorb leeren: sanftes Rauschen
        "moon-recycle.wav": whoosh(0.7, 3000, 400, rng),
    }
    for name, sig in sounds.items():
        save(name, reverb(sig))


if __name__ == "__main__":
    main()
