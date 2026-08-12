# ArtiGo MVP

Prima versione pubblicabile di ArtiGo, ottimizzata come web app mobile-first.

## Pubblicazione su Vercel

1. Crea un nuovo repository GitHub, ad esempio `artigo-mvp`.
2. Carica tutti i file di questa cartella nella root del repository.
3. In Vercel scegli **Add New > Project**.
4. Importa il repository GitHub appena creato.
5. Framework Preset: **Other**.
6. Build Command: lascia vuoto.
7. Output Directory: lascia vuoto.
8. Premi **Deploy**.

Vercel pubblicherà automaticamente `index.html` come homepage.

## Struttura

- `index.html` - prototipo ArtiGo navigabile
- `vercel.json` - configurazione minima per hosting statico
- `.gitignore` - esclusioni Git standard

## Evoluzione prevista

La prossima versione collegherà autenticazione, database, upload, notifiche e dashboard amministratore a un backend reale. I pagamenti verranno integrati successivamente.
