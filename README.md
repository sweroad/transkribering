# Transkribering

En menyradsapp för macOS som omvandlar tal till text lokalt på datorn. Håll ned tal-knappen,
prata och släpp – texten skrivs in där markören står, i vilket program som helst.

Standardmodell: [Klang Pianissimo](https://huggingface.co/KlangAI/pianissimo-sv) (svenska),
i MLX-versionen [8-bit](https://huggingface.co/KlangAI/pianissimo-sv-mlx-8bit) (759 MB) som körs på
Apple silicons GPU. Modellen laddas ner en gång och sedan går allt lokalt, utan nätverk.

## Krav

- Mac med Apple silicon (M1 eller senare), macOS 14+
- Command Line Tools (`xcode-select --install`), Xcode behövs inte
- Python 3.10+ (t.ex. `brew install python`)

## Installation

```bash
scripts/setup_backend.sh
```

```bash
scripts/build_app.sh --install
```

```bash
open ~/Applications/Transkribering.app
```

`setup_backend.sh` skapar Python-miljön i `~/Library/Application Support/Transkribering/venv`
(det går också att göra från appen: Inställningar → Modell → *Installera/uppdatera backend*).
Vid första starten laddas modellen ner till `~/Library/Application Support/Transkribering/huggingface`.

### Behörigheter

Vid första starten frågar appen om:

- **Mikrofon** – för inspelningen.
- **Hjälpmedel** (Systeminställningar → Integritet och säkerhet → Hjälpmedel) – för att fånga
  tal-knappen globalt och skriva in texten. Appen börjar lyssna automatiskt när behörigheten är given.

> Appen signeras ad hoc. Efter varje ombyggnad ser macOS den som en ny app, så du behöver ta bort
> och lägga till den igen under Hjälpmedel. Med ett utvecklarcertifikat slipper du det:
> `SIGN_IDENTITY="Apple Development: …" scripts/build_app.sh --install`

## Användning

| | |
|---|---|
| Standard-tal-knapp | **Höger ⌘** – håll ned, prata, släpp |
| Byt tangent | Inställningar → Allmänt → Tangent (en vanlig tangent, t.ex. F13 eller ⌃⌥Mellanslag, eller en ensam modifierare som höger ⌥ eller fn) |
| Läge | *Håll ned för att prata* eller *Tryck för att starta/stoppa* |
| Inmatning | *Klistra in* (snabbast, återställer urklippet) eller *Skriv som tangenttryckningar* |
| Ordlista | Namn och facktermer som ska stavas exakt (Pianissimos *phrase boosting*) |

### Löpande utskrift

Texten skrivs ut medan du pratar: varje gång du gör en kort paus (standard 0,7 s) transkriberas
frasen och skrivs in, ungefär en sekund efter att du slutat prata. Resten skrivs ut när du släpper knappen.

- Varje fras transkriberas tillsammans med de senaste 4 sekunderna ljud som sammanhang, och bara den
  nya texten behålls (med hjälp av modellens tidsstämplar per ord). Korta fraser som "ny rad" blir då
  lika säkra som när allt transkriberas på en gång.
- Skiljetecken i slutet av en fras skrivs ut först när nästa fras kommit, eftersom nästa fras kan
  ändra dem: "…datorn [paus] och det går snabbt" blir en mening, och "hej [paus] utropstecken" blir "Hej!".
- Pauslängd och av/på finns under Inställningar → Allmänt → Löpande utskrift.
- Felsökning utan mikrofon: `Transkribering --simulate-stream ljud.f32` spelar upp en ljudfil
  (rå float32, 16 kHz mono) i realtid och visar vad som skrivs ut och när.

### Röstkommandon

Säg skiljetecken och radbrytningar som ord:

| Säg | Ger |
|---|---|
| ny rad / radbrytning | radbrytning (Enter) |
| nytt stycke / ny paragraf | tom rad |
| punkt, komma, kolon, semikolon | `.` `,` `:` `;` |
| utropstecken, frågetecken | `!` `?` |
| tre punkter | `…` |
| tankstreck, bindestreck, snedstreck | `–` `-` `/` |
| öppna parentes / stäng parentes | `(` `)` |
| citattecken | `”` (öppnar och stänger) |
| snabel-a | `@` |

Exempel: *"hej utropstecken ny rad hur mår du frågetecken"* ger

```
Hej!
Hur mår du?
```

- Modellen sätter också ut skiljetecken på egen hand. Skiljetecken som den har satt runt ett
  kommandoord ("Hej, utropstecken.") tas bort, och mellanslag och versaler rättas.
- Vanliga ord tolkas inte som kommandon när sammanhanget visar att de är vanliga ord:
  "ska **komma** hem", "**komma** ihåg", "en viktig **punkt**", "**punkt** 3", "en **ny rad** i tabellen".
- I adresser blir *punkt* en punkt utan mellanslag: "erik snabel-a knowit punkt se" → `erik@knowit.se`.
- *Ny rad* klistras in som en radbrytning. Med inmatningsmetoden *Skriv som tangenttryckningar*
  skickas i stället en riktig Enter-tryckning (i chattprogram skickar det meddelandet).
- Under Inställningar → Röstkommandon kan du stänga av enskilda kommandon, prova tolkningen och lägga
  till egna, t.ex. `mvh = Med vänliga hälsningar` eller `utrotstecken | utropsteckan = !` för ord som
  modellen ofta stavar fel.

Menyradsikonen visar status: 🎙 redo, röd mikrofon spelar in, vågform transkriberar.
Används en ensam modifierare som tal-knapp, t.ex. höger ⌘, fungerar den fortfarande i vanliga
kortkommandon. Trycker du ⌘C avbryts inspelningen i stället.

## Arkitektur

```
Swift-app (menyrad)                          Python-backend (lokal process)
┌──────────────────────────┐                 ┌───────────────────────────────┐
│ HotkeyMonitor (CGEventTap)│                 │ worker.py  (JSON-rader stdin/ │
│ AudioRecorder (16 kHz)    │  load/transcribe│            stdout)            │
│ TranscriptionEngine ──────┼────────────────►│ engines/                      │
│   └ PythonWorkerEngine    │◄────────────────┤   pianissimo_mlx  (standard)  │
│ TextInserter (⌘V / typ)   │      text       │   mlx_whisper     (exempel)   │
│ SettingsView (SwiftUI)    │                 │   vendor/  (Klangs laddare)   │
└──────────────────────────┘                 └───────────────────────────────┘
```

- `Sources/Transkribering/TranscriptionEngine.swift`: protokollet som appen använder, plus
  `EngineFactory` som väljer implementation per modell.
- `Sources/Transkribering/PythonWorkerEngine.swift`: startar `backend/worker.py`, håller modellen
  i minnet och startar om processen om den kraschar. Ljud skickas som rå float32 via en tillfällig fil.
- `backend/engines/`: en motor per modellfamilj, registrerad efter namn i `engines/__init__.py`.
- `Resources/models.json`: modellkatalogen som visas i inställningarna.

Från modellrepona hämtas bara vikter, konfiguration och tokenizer. Klangs laddarkod
(`pianissimo_mlx.py`, `phrase_boost.py`, CC BY 4.0) är granskad och inbäddad i
`backend/engines/vendor/`, så ingen kod hämtas från nätet när appen körs.

## Byta eller lägga till modell

**Samma modellfamilj** (t.ex. 4-bit, bf16 eller danska): välj den under Inställningar → Modell.

**Egen post i katalogen**: skapa `~/Library/Application Support/Transkribering/models.json`:

```json
{
  "default": "min-modell",
  "models": [
    { "id": "min-modell", "name": "Min modell", "engine": "pianissimo-mlx",
      "repo": "KlangAI/pianissimo-sv-mlx-4bit", "language": "sv",
      "options": { "boost_alpha": 1.5 } }
  ]
}
```

Klicka sedan på *Läs om modellkatalog*. `options` skickas oförändrat till motorn.

**Ny modellfamilj**:

1. Skapa `backend/engines/min_motor.py` med en klass som ärver `Engine` och implementerar
   `load()` och `transcribe(audio, vocabulary)`. `mlx_whisper.py` är ett komplett exempel.
2. Registrera den i `ENGINES` i `backend/engines/__init__.py`.
3. Lägg till eventuella beroenden i `backend/requirements.txt` och kör `scripts/setup_backend.sh`.
4. Lägg till en post med `"engine": "min-motor"` i modellkatalogen.

Exempel: Whisper via MLX finns redan förberett. Avkommentera `mlx-whisper` i
`backend/requirements.txt`, installera om backend och välj *Whisper large-v3-turbo*.

Vill du köra en modell direkt i Swift (t.ex. Core ML) skapar du en klass som följer
`TranscriptionEngine` och returnerar den från `EngineFactory` för det motornamnet.

## Felsökning

- **Inget händer när jag trycker på tangenten**: kontrollera Hjälpmedel i Inställningar → Allmänt.
  Efter ombyggnad: ta bort appen ur listan och lägg till den igen.
- **Modellen laddas inte**: se `~/Library/Application Support/Transkribering/worker.log`.
- **Testa backenden separat**:
  ```bash
  printf '%s\n' '{"id":1,"cmd":"ping"}' | ~/Library/Application\ Support/Transkribering/venv/bin/python backend/worker.py
  ```

## Licens

Modellerna Klang Pianissimo och den inbäddade laddarkoden: CC BY 4.0, © Klang.
