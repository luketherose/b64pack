# b64pack

Comprime file o cartelle (PDF, progetti Java, ...) in uno zip e trasforma lo zip in un file di
testo base64, da incollare per esempio in un file su GitHub. Fa anche il percorso inverso.

Due versioni con lo stesso formato, intercambiabili: il testo prodotto da una si decodifica
con l'altra.

- `b64pack.py`: Python 3.8 o successivo, solo libreria standard (macOS, Linux, Windows).
- `b64pack.ps1`: PowerShell, scritto per Windows PowerShell 5.1 e PowerShell 7.

## Uso (Python)

```bash
b64pack pack contratto.pdf                 # -> contratto.zip.b64.txt
b64pack pack ~/dev/biblioteca              # -> biblioteca.zip.b64.txt
b64pack pack doc1.pdf doc2.pdf -o consegna # -> consegna.zip.b64.txt
b64pack pack ~/dev/biblioteca --split 1    # -> biblioteca.zip.b64.part1of3.txt, part2of3, ...
b64pack pack contratto.pdf --copy          # copia anche il testo negli appunti (macOS)
```

```bash
b64pack unpack contratto.zip.b64.txt                     # -> contratto.zip
b64pack unpack biblioteca.zip.b64.part1of3.txt -x out    # trova da solo le altre parti ed estrae in out/
```

Dove il comando non e' installato: `python3 b64pack.py pack ...`.

## Uso (PowerShell)

```powershell
.\b64pack.ps1 pack contratto.pdf
.\b64pack.ps1 pack C:\dev\biblioteca -Split 1
.\b64pack.ps1 pack doc1.pdf doc2.pdf -Output consegna
.\b64pack.ps1 pack contratto.pdf -Copy
.\b64pack.ps1 unpack biblioteca.zip.b64.part1of3.txt -Extract out
.\b64pack.ps1 unpack contratto.zip.b64.txt
```

Stesse opzioni della versione Python, con i nomi PowerShell: `-Output` (o `-o`), `-Split`,
`-All`, `-Copy`, `-Extract` (o `-x`), `-Force`. In PowerShell il carattere jolly lo risolve lo
script: `.\b64pack.ps1 unpack *.part1of3.txt` funziona. Guida completa:
`Get-Help .\b64pack.ps1 -Detailed`.

Se Windows rifiuta di eseguire lo script per la execution policy, lancialo cosi' (vale solo per
quel comando, non cambia impostazioni):

```powershell
powershell -ExecutionPolicy Bypass -File .\b64pack.ps1 pack contratto.pdf
```

Se lo script e' stato scaricato da internet, prima `Unblock-File .\b64pack.ps1`. Il file e' solo
ASCII: se lo copi incollandolo in Blocco note, qualunque codifica di salvataggio va bene.

## Cosa fa

- Il testo e' base64 puro a righe di 76 caratteri, a capo LF, senza BOM. In decodifica spazi,
  a capo e CRLF vengono ignorati, e si leggono anche i file UTF-16 (quelli che Windows
  PowerShell 5.1 scrive con `Get-Clipboard > file.txt`).
- `--split MB` / `-Split MB` spezza il testo in parti da al massimo MB megabyte, tagliando il
  flusso base64 (non ricodificando), quindi le parti concatenate in ordine sono il testo intero.
  Il nome dice quante sono (`part2of3`) e `unpack` segnala quelle mancanti. Utile quando il
  browser fatica a incollare un testo grande: un PDF da 8 MB diventa circa 10.6 MB di testo.
- Nei progetti salta `.git`, `.svn`, `.idea`, `.vscode`, `.gradle`, `node_modules`,
  `__pycache__`, `*.class`, `.DS_Store`, e `target/`, `build/`, `out/` solo se accanto c'e' un
  `pom.xml`, `build.gradle` o `build.xml` (un package Java chiamato `build` resta dentro).
  Stampa sempre cosa ha escluso. `--all` / `-All` include tutto.
- Un input che e' gia' uno zip viene codificato cosi' com'e'.
- Dopo `pack` rilegge il testo e controlla che ridia lo stesso zip; `unpack` verifica il CRC
  di ogni file dello zip, cosi' un incollaggio troncato o alterato viene segnalato invece di
  produrre file rotti. Entrambi stampano lo sha256 dello zip, per confrontarlo ai due capi.
  La versione PowerShell calcola il CRC con un piccolo tipo C# caricato da `Add-Type`: se il PC
  lo blocca, avvisa e controlla solo che la decompressione riesca.
- Non sovrascrive niente senza `--force` / `-Force`. Con la forzatura, `pack` cancella anche le
  parti di un giro precedente con lo stesso nome, cosi' non restano parti vecchie mescolate
  alle nuove.

## Decodificare senza lo script

```bash
cat biblioteca.zip.b64*.txt | base64 -d > biblioteca.zip
```

PowerShell (un solo file):

```powershell
[IO.File]::WriteAllBytes("$PWD\contratto.zip", [Convert]::FromBase64String((Get-Content contratto.zip.b64.txt -Raw)))
```

## Attenzione

Base64 non e' cifratura: chiunque legga il file su GitHub ricostruisce lo zip in un comando.
Per materiale di lavoro usa un repository privato.

## Test

```bash
python3 -m unittest -v tests/test_b64pack.py tests/test_b64pack_ps.py
```

`tests/test_b64pack_ps.py` prova la versione PowerShell da sola e incrociata con quella Python
(pack da una, unpack dall'altra); senza `pwsh` nel PATH viene saltato. Collaudata con
PowerShell 7.6 su macOS; con Windows PowerShell 5.1 su Windows non e' ancora stata provata.
