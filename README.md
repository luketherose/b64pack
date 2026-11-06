# b64pack

Comprime file o cartelle (PDF, progetti Java, ...) in uno zip e trasforma lo zip in un file di
testo base64, da incollare per esempio in un file su GitHub. Fa anche il percorso inverso.
Un solo file Python, solo libreria standard, Python 3.8 o successivo (macOS, Linux, Windows).

## Uso

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

Su Windows, o dove il comando non e' installato: `python b64pack.py pack ...`.

## Cosa fa

- Il testo e' base64 puro a righe di 76 caratteri. Spazi, a capo e CRLF aggiunti dall'editor
  di GitHub o da Windows vengono ignorati in decodifica.
- `--split MB` spezza il testo in parti da al massimo MB megabyte, tagliando il flusso base64
  (non ricodificando), quindi le parti concatenate in ordine sono il testo intero. Il nome dice
  quante sono (`part2of3`) e `unpack` segnala quelle mancanti. Utile quando il browser fatica a
  incollare un testo grande: un PDF da 8 MB diventa circa 10.6 MB di testo.
- Nei progetti salta `.git`, `.svn`, `.idea`, `.vscode`, `.gradle`, `node_modules`,
  `__pycache__`, `*.class`, `.DS_Store`, e `target/`, `build/`, `out/` solo se accanto c'e' un
  `pom.xml`, `build.gradle` o `build.xml` (un package Java chiamato `build` resta dentro).
  Stampa sempre cosa ha escluso. `--all` include tutto.
- Un input che e' gia' uno zip viene codificato cosi' com'e'.
- Dopo `pack` rilegge il testo e controlla che ridia lo stesso zip; `unpack` verifica il CRC
  di ogni file dello zip, cosi' un incollaggio troncato o alterato viene segnalato invece di
  produrre file rotti. Entrambi stampano lo sha256 dello zip, per confrontarlo ai due capi.
- Non sovrascrive niente senza `--force`. Con `--force`, `pack` cancella anche le parti di un
  giro precedente con lo stesso nome, cosi' non restano parti vecchie mescolate alle nuove.

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
python3 -m unittest -v tests/test_b64pack.py
```
